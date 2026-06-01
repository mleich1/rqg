#!/bin/bash
# Read-only fast equivalent of util/SUMMARY.sh: same stdout (header + sorted result
# table), but uses the C++ matcher util/rqg_verdict instead of per-log perl verdict.pl.
# It does NOT delete any run (SUMMARY.sh removes 'ignore' runs; this one leaves them).
# Existing files (incl. SUMMARY.sh) are not modified.
LANG=C
RQG_DIR=$(pwd)

WRK_DIR=$1
if [ -z "$WRK_DIR" ]; then WRK_DIR=$(realpath last_result_dir 2>/dev/null); fi
if [ ! -d "$WRK_DIR" ]; then echo "The directory '$WRK_DIR' does not exist."; exit 1; fi

LOGS=$(ls -d "$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9]/rqg.log "$WRK_DIR"/[A-Za-z]*/rqg.log 2>/dev/null)
if [ -z "$LOGS" ]; then echo "The directory '$WRK_DIR' does not contain logs of finished RQG runs."; exit 0; fi

BIN="$RQG_DIR/util/rqg_verdict"
if [ ! -x "$BIN" ]; then g++ -O2 -std=c++17 -o "$BIN" "$RQG_DIR/util/rqg_verdict.cc" -lpcre2-8 || exit 1; fi

# 1. Consistency check + (re)generate Verdict_tmp.cfg, exactly as SUMMARY.sh does.
perl "$RQG_DIR/verdict.pl" --batch_config=verdict_general.cfg --workdir="$RQG_DIR" >/dev/null

DUMP=$(mktemp); LL=$(mktemp); VOUT=$(mktemp); CH=$(mktemp -d)
trap 'rm -rf "$DUMP" "$LL" "$VOUT" "$VOUT.keep" "$CH"' EXIT
perl "$RQG_DIR/util/verdict_dump.pl" "$RQG_DIR/Verdict_tmp.cfg" > "$DUMP"

# 2. Verdicts for all logs, parallel across cores (each process loads config once).
echo "$LOGS" > "$LL"
split -n "l/$(nproc)" "$LL" "$CH/c." 2>/dev/null || split -n l/8 "$LL" "$CH/c."
ls "$CH"/c.* | xargs -P "$(nproc)" -I {} "$BIN" --dump="$DUMP" --logs={} > "$VOUT" 2>/dev/null
# VOUT lines: <log>\tVerdict: <v>, Extra_info: <info>

# 3. Header (matches SUMMARY.sh; the 'deleted' line is replaced to stay truthful).
if [ "$(ls -d "$WRK_DIR"/RQG_Simplifier.cfg 2>/dev/null | wc -l)" -gt 0 ]; then
  echo "The directory '$WRK_DIR' contains a Simplifier run"
  echo "== It is or was a test battery with decreasing complexity."
fi
echo '--------------------------------------------------------------------------------'
cat "$WRK_DIR"/SourceInfo.txt 2>/dev/null
echo '--------------------------------------------------------------------------------'
echo "INFO: Read-only (SUMMARY_fast.sh): RQG runs of no interest were NOT deleted."

# 4. Drop 'ignore*' runs, then format + du per kept run in parallel; sorted like SUMMARY.sh.
awk -F'\t' 'BEGIN{OFS="\t"} {
  line=$2;
  if (line ~ /^Verdict: /) {
    v=line; sub(/^Verdict: /,"",v); sub(/,.*/,"",v);
    if (v ~ /^ignore/) next;
    info=line; sub(/^.*, Extra_info: /,"",info);
  } else { info=""; }
  print $1, info
}' "$VOUT" > "$VOUT.keep"

emit_line() {
  local rec="$1"
  local log info dir arch sz
  log=$(printf '%s' "$rec" | cut -f1)
  info=$(printf '%s' "$rec" | cut -f2-)
  dir=$(dirname "$log")
  arch="$dir/archive.tar.xz"
  if [ -e "$arch" ]; then
    sz=$(du -sk "$dir" 2>/dev/null | cut -f1)
    printf '%s        %s    %s %s KB\n' "$info" "$log" "$arch" "$sz"
  else
    printf '%s        %s    <Archive deleted>\n' "$info" "$log"
  fi
}
export -f emit_line
xargs -d '\n' -a "$VOUT.keep" -P "$(nproc)" -I {} bash -c 'emit_line "$@"' _ {} | sort
