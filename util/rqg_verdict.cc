// Fast drop-in replacement for: perl verdict.pl --verdict_config=<cfg> --log=<log>
// Reproduces lib/Verdict.pm calculate_verdict (variant 5) using PCRE2's
// non-backtracking DFA matcher (pcre2_dfa_match) -> linear-time, no catastrophic
// backtracking. Patterns are consumed from util/verdict_dump.pl output (base64),
// i.e. the exact post-eval bytes Perl's m{} compiles, so matching is faithful.
//
// Build: g++ -O2 -std=c++17 -o util/rqg_verdict util/rqg_verdict.cc -lpcre2-8
//
// Single log:  rqg_verdict --dump=D --log=L         (prints say-style verdict line)
// Many logs:   rqg_verdict --dump=D --logs=LISTFILE  (one "<log>\t<line>" per log)

#define _GNU_SOURCE
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

static const char* STATUS_PREFIX = "RESULT: The RQG run ended with status ";
static const size_t SLICE = 100000000; // getFileSlice cap

// ---- base64 decode --------------------------------------------------------
static std::string b64decode(const std::string& in) {
  static int8_t T[256]; static bool init=false;
  if(!init){ for(int i=0;i<256;i++)T[i]=-1;
    const char* a="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for(int i=0;i<64;i++)T[(unsigned char)a[i]]=i; init=true; }
  std::string out; int val=0,bits=-8;
  for(unsigned char c: in){ if(c=='='||T[c]<0) continue; val=(val<<6)+T[c]; bits+=6;
    if(bits>=0){ out.push_back(char((val>>bits)&0xFF)); bits-=8; } }
  return out;
}

// ---- a compiled pattern ---------------------------------------------------
struct Pat { pcre2_code* code=nullptr; std::string info; std::vector<std::string> lits; };

// Extract ALL required literal substrings: maximal runs of plain literal bytes at
// depth 0 (outside any (...) / [...]) that the pattern MUST contain for any match.
// Each run is independently necessary (the pattern is a depth-0 concatenation), so
// requiring every run present is correctness-preserving and mirrors Perl's literal
// prefilter. Returns {} when unreliable (top-level alternation) -> pattern always run.
static bool class_escape(char n){
  return strchr("dDwWsSbBAZzGnrtfvxcpPkgRhHvVeNoQEuUlL0123456789", n)!=nullptr;
}
static std::vector<std::string> required_literals(const std::string& p){
  std::vector<std::string> out; std::string cur; int depth=0; bool poison=false;
  auto flush=[&]{ if(cur.size()>=4) out.push_back(cur); cur.clear(); };
  for(size_t i=0;i<p.size() && !poison;i++){
    char c=p[i];
    if(c=='\\'){
      flush();
      if(i+1<p.size()){ char n=p[i+1];
        if(depth==0 && !class_escape(n)){ // escaped literal byte at depth 0
          char nx=(i+2<p.size())?p[i+2]:0; bool opt=(nx=='*'||nx=='?')||(nx=='{'&&i+3<p.size()&&p[i+3]=='0');
          if(!opt) cur.push_back(n);
        }
        i++; }
      continue;
    }
    if(c=='('){ flush(); depth++; continue; }
    if(c==')'){ flush(); if(depth>0)depth--; continue; }
    if(c=='['){ flush(); depth++; continue; }
    if(c==']'){ flush(); if(depth>0)depth--; continue; }
    if(depth>0) continue;
    if(c=='|'){ poison=true; break; }          // top-level alternation -> unreliable
    if(c=='{'){ flush(); while(i<p.size()&&p[i]!='}')i++; continue; }
    if(strchr(".*+?}^$",c)){ flush(); continue; }
    char nx=(i+1<p.size())?p[i+1]:0;            // optional if next quantifier drops this char
    bool opt=(nx=='*'||nx=='?')||(nx=='{'&&i+2<p.size()&&p[i+2]=='0');
    if(opt){ flush(); continue; }
    cur.push_back(c);
  }
  flush();
  if(poison) return {};
  return out;
}

static pcre2_compile_context* g_cctx=nullptr;
static pcre2_code* compile(const std::string& p){
  if(!g_cctx){ g_cctx=pcre2_compile_context_create(nullptr);
    // Perl passes unknown escapes (e.g. \m, \i) through as the literal char;
    // make PCRE2 do the same so faithful patterns compile.
    pcre2_set_compile_extra_options(g_cctx, PCRE2_EXTRA_BAD_ESCAPE_IS_LITERAL); }
  int err; PCRE2_SIZE eoff;
  pcre2_code* c = pcre2_compile((PCRE2_SPTR)p.data(), p.size(),
                                PCRE2_DOTALL, &err, &eoff, g_cctx);
  if(!c){ PCRE2_UCHAR buf[256]; pcre2_get_error_message(err,buf,sizeof(buf));
    fprintf(stderr,"WARN: compile failed at %zu: %s : %.*s\n",(size_t)eoff,buf,
            (int)std::min(p.size(),(size_t)80),p.data()); return c; }
  pcre2_jit_compile(c, PCRE2_JIT_COMPLETE);
  return c;
}

// Reusable matching scratch.
struct Matcher {
  pcre2_match_data* md;
  pcre2_match_context* mctx;
  pcre2_jit_stack* jstack;
  std::vector<int> ws;
  Matcher(): md(pcre2_match_data_create(8,nullptr)), ws(1<<18) {
    mctx=pcre2_match_context_create(nullptr);
    jstack=pcre2_jit_stack_create(64*1024, 256*1024*1024, nullptr); // up to 256MB JIT stack
    pcre2_jit_stack_assign(mctx, nullptr, jstack);
  }
  ~Matcher(){ pcre2_jit_stack_free(jstack); pcre2_match_context_free(mctx); pcre2_match_data_free(md); }
  // true if pattern matches anywhere in subject. JIT-compiled backtracking match
  // (Perl's algorithm, far faster); fall back to non-backtracking DFA only if the
  // JIT/interpreter bails (e.g. stack limit) so we still terminate.
  bool match(const Pat& pat, const char* s, size_t n){
    // Required-literal prefilter (Perl-style): if any required literal is absent
    // the pattern cannot match, so skip the expensive automaton entirely.
    for(const auto& L : pat.lits) if(!memmem(s,n,L.data(),L.size())) return false;
    int rc = pcre2_match(pat.code,(PCRE2_SPTR)s,n,0,0,md,mctx);
    if(rc>=0) return true;
    if(rc==PCRE2_ERROR_NOMATCH || rc==PCRE2_ERROR_PARTIAL) return false;
    // JIT stack / interpreter limit etc. -> DFA fallback (bounded, no backtracking).
    rc = pcre2_dfa_match(pat.code,(PCRE2_SPTR)s,n,0,0,md,nullptr,ws.data(),ws.size());
    if(rc==PCRE2_ERROR_DFA_WSSIZE){ ws.resize(ws.size()*4);
      rc=pcre2_dfa_match(pat.code,(PCRE2_SPTR)s,n,0,0,md,nullptr,ws.data(),ws.size()); }
    return rc>=0;
  }
};

// ---- config ---------------------------------------------------------------
struct Config {
  std::vector<Pat> bl_status, wl_status;   // status regexes
  std::vector<Pat> bl_pat, wl_pat, in_pat; // content regexes (+info)
};

static void add(std::vector<Pat>& v, const std::string& info, const std::string& pat){
  Pat p; p.info=info; p.code=compile(pat); p.lits=required_literals(pat);
  if(p.code) v.push_back(std::move(p));
}

static Config load(const char* dumpfile){
  Config cfg; FILE* f=fopen(dumpfile,"r"); if(!f){perror("dump");exit(2);}
  char* line=nullptr; size_t cap=0; ssize_t len;
  while((len=getline(&line,&cap,f))>0){
    while(len>0 && (line[len-1]=='\n'||line[len-1]=='\r')) line[--len]=0;
    std::string s(line,len);
    auto sp=s.find(' '); if(sp==std::string::npos) continue;
    std::string code=s.substr(0,sp); std::string rest=s.substr(sp+1);
    if(code=="bs"){ add(cfg.bl_status,"",b64decode(rest)); }
    else if(code=="ws"){ add(cfg.wl_status,"",b64decode(rest)); }
    else {
      auto sp2=rest.find(' '); std::string i=b64decode(rest.substr(0,sp2));
      std::string p=b64decode(rest.substr(sp2+1));
      if(code=="bp") add(cfg.bl_pat,i,p);
      else if(code=="wp") add(cfg.wl_pat,i,p);
      else if(code=="ip") add(cfg.in_pat,i,p);
    }
  }
  free(line); fclose(f); return cfg;
}

// ---- getFileSlice: last SLICE bytes ---------------------------------------
static bool read_slice(const char* path, std::string& out){
  int fd=open(path,O_RDONLY); if(fd<0) return false;
  struct stat st; if(fstat(fd,&st)){close(fd);return false;}
  size_t sz=st.st_size, n=sz; off_t off=0;
  if(sz>SLICE){ off=(off_t)(sz-SLICE); n=SLICE; }
  out.resize(n);
  if(off) lseek(fd,off,SEEK_SET);
  size_t got=0; while(got<n){ ssize_t r=read(fd,&out[got],n-got); if(r<=0) break; got+=r; }
  out.resize(got); close(fd); return true;
}

// ---- status extraction (mirrors Auxiliary::status_matching setup) ---------
static bool in_class(unsigned char c){
  return (c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||
         c=='_'||c=='/'||c=='.'||c=='-'||c=='<'||c=='>';
}
// returns prefix occurrence count; sets status_read to token after first prefix.
static int extract_status(const std::string& c, std::string& status_read, bool& tok_ok){
  size_t plen=strlen(STATUS_PREFIX); int count=0; size_t first=std::string::npos;
  for(size_t pos=c.find(STATUS_PREFIX); pos!=std::string::npos;
      pos=c.find(STATUS_PREFIX,pos+plen)){ if(count==0)first=pos; count++; }
  status_read.clear(); tok_ok=false;
  if(count>=1){ size_t i=first+plen; std::string t;
    while(i<c.size() && in_class((unsigned char)c[i])) t.push_back(c[i++]);
    if(!t.empty()){ status_read=t; tok_ok=true; } }
  return count;
}

// match a status pattern list against status_read; STATUS_ANY_ERROR special.
enum MState { M_YES, M_NO, M_EMPTY, M_UNKNOWN };
static MState status_match(Matcher& m, const std::vector<Pat>& list,
                           const std::string& orig_patterns, bool prefix_found,
                           const std::string& status_read,
                           const std::vector<std::string>& raw){
  if(!prefix_found) return M_UNKNOWN;
  if(list.empty() && raw.empty()) return M_EMPTY;
  bool any=false; bool got=false;
  for(size_t k=0;k<raw.size();k++){
    got=true;
    if(raw[k]=="STATUS_ANY_ERROR"){
      if(status_read.find("STATUS_OK")==std::string::npos) any=true;
    } else {
      if(m.match(list[k], status_read.data(), status_read.size())) any=true;
    }
  }
  if(!got) return M_EMPTY;
  return any? M_YES : M_NO;
}

// content_matching2: returns state + joined infos of matches (list order).
static MState content_match(Matcher& m, const std::vector<Pat>& list,
                            const char* s, size_t n, std::string& infos){
  infos.clear(); if(list.empty()) return M_EMPTY;
  bool any=false; bool first=true;
  for(const auto& p: list){
    if(m.match(p,s,n)){ any=true; if(!first)infos+="--"; infos+=p.info; first=false; }
  }
  return any? M_YES : M_NO;
}

// ---- verdict ---------------------------------------------------------------
struct Verdict { std::string v, info; bool ok=true; };

static Verdict calc(Matcher& m, const Config& cfg,
                    const std::vector<std::string>& bl_raw,
                    const std::vector<std::string>& wl_raw,
                    const std::string& content){
  Verdict R;
  if(content.empty()){ R.v=""; R.info=""; return R; }
  if(content.find("BATCH: Stop the run")!=std::string::npos){ R.v="ignore_stopped"; R.info="stopped"; return R; }

  std::string status_read; bool tok_ok;
  int pc = extract_status(content, status_read, tok_ok);
  if(pc>1){ R.ok=false; return R; }              // perl: internal error, no verdict
  if(pc==1 && !tok_ok){ R.ok=false; return R; }  // perl: internal error
  bool prefix_found = (pc==1);

  int maybe_match=1, maybe_interest=1, bl_match=0, ok_match=0;
  std::string f_info = prefix_found ? status_read : std::string();
  const char* s=content.data(); size_t n=content.size();

  // STATUS_OK
  if(prefix_found && status_read.find("STATUS_OK")!=std::string::npos) ok_match=1;

  // blacklist statuses
  MState st = status_match(m, cfg.bl_status, "", prefix_found, status_read, bl_raw);
  if(st==M_YES){ maybe_match=0; maybe_interest=0; bl_match=1; }

  // blacklist patterns
  std::string infos;
  MState bp = content_match(m, cfg.bl_pat, s, n, infos);
  if(bp==M_YES){ f_info += "--"+infos; maybe_match=0; maybe_interest=0; bl_match=1; }

  // whitelist statuses
  MState ws = status_match(m, cfg.wl_status, "", prefix_found, status_read, wl_raw);
  if(bl_match==0 && ws!=M_YES) maybe_match=0;

  // whitelist patterns
  MState wp = content_match(m, cfg.wl_pat, s, n, infos);
  if(wp==M_YES) f_info += "--"+infos;
  if(bl_match==0 && maybe_match==1){ if(wp!=M_YES) maybe_match=0; }

  // interest patterns
  MState ip = content_match(m, cfg.in_pat, s, n, infos);
  if(ip==M_YES) f_info += "--"+infos;

  if(maybe_match) R.v="replay";
  else if(maybe_interest) R.v="interest";
  else if(bl_match) R.v="ignore_unwanted";
  else if(ok_match) R.v="ignore_status_ok";
  else R.v="ignore";
  R.info=f_info; return R;
}

int main(int argc, char** argv){
  const char* dump=nullptr; const char* log=nullptr; const char* logs=nullptr;
  for(int i=1;i<argc;i++){ std::string a=argv[i];
    if(a.rfind("--dump=",0)==0) dump=argv[i]+7;
    else if(a.rfind("--log=",0)==0) log=argv[i]+6;
    else if(a.rfind("--logs=",0)==0) logs=argv[i]+7; }
  if(!dump||(!log&&!logs)){ fprintf(stderr,"usage: --dump=D (--log=L|--logs=LIST)\n"); return 2; }

  Config cfg=load(dump);
  // raw status strings (for STATUS_ANY_ERROR / literal compare), parallel to lists.
  std::vector<std::string> bl_raw, wl_raw;
  { FILE* f=fopen(dump,"r"); char* line=nullptr; size_t cap=0; ssize_t len;
    while((len=getline(&line,&cap,f))>0){ while(len>0&&(line[len-1]=='\n'||line[len-1]=='\r'))line[--len]=0;
      std::string s(line,len); auto sp=s.find(' '); if(sp==std::string::npos)continue;
      std::string c=s.substr(0,sp), r=s.substr(sp+1);
      if(c=="bs") bl_raw.push_back(b64decode(r)); else if(c=="ws") wl_raw.push_back(b64decode(r)); }
    free(line); fclose(f); }

  Matcher m;
  auto run=[&](const char* path, FILE* out, bool prefix_path){
    std::string content;
    if(!read_slice(path,content)){ fprintf(stderr,"ERROR: cannot read %s\n",path); return; }
    Verdict R=calc(m,cfg,bl_raw,wl_raw,content);
    if(!R.ok){ if(prefix_path) fprintf(out,"%s\t<no-verdict>\n",path);
               else fprintf(stderr,"INTERNAL: no verdict for %s\n",path); return; }
    if(prefix_path) fprintf(out,"%s\tVerdict: %s, Extra_info: %s\n",path,R.v.c_str(),R.info.c_str());
    else fprintf(out,"# rqg_verdict Verdict: %s, Extra_info: %s\n",R.v.c_str(),R.info.c_str());
  };

  if(log){ run(log,stdout,false); }
  else { FILE* f=fopen(logs,"r"); if(!f){perror("logs");return 2;}
    char* line=nullptr; size_t cap=0; ssize_t len;
    while((len=getline(&line,&cap,f))>0){ while(len>0&&(line[len-1]=='\n'||line[len-1]=='\r'))line[--len]=0;
      if(len>0) run(line,stdout,true); }
    free(line); fclose(f); }
  return 0;
}
