#!/bin/bash
# Validate util/rqg_verdict (C++/PCRE2-DFA) against perl verdict.pl over a result dir.
# Usage: util/validate_verdict.sh [WRK_DIR]
LANG=C
RQG_DIR=$(pwd)
WRK_DIR=${1:-$(realpath last_result_dir)}
DUMP=/tmp/vdump.txt
CFG="$RQG_DIR/Verdict_tmp.cfg"

perl "$RQG_DIR/util/verdict_dump.pl" "$CFG" > "$DUMP" 2>/dev/null

LOGS=/tmp/loglist.txt
ls -d "$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9]/rqg.log "$WRK_DIR"/[A-Za-z]*/rqg.log 2>/dev/null > "$LOGS"
N=$(wc -l < "$LOGS")
echo "Validating $N logs in $WRK_DIR"

# Reference: perl, in parallel. Emit "<log>\tVerdict: V, Extra_info: I"
ref() {
  local L="$1"
  local line
  line=$(perl "$RQG_DIR/verdict.pl" --verdict_config="$CFG" --log="$L" 2>&1 \
         | grep -E ' Verdict: ' | sed -e 's/^.* \(Verdict: \)/\1/')
  if [ -z "$line" ]; then line="<no-verdict>"; fi
  printf '%s\t%s\n' "$L" "$line"
}
export -f ref; export RQG_DIR CFG
echo "Running perl reference (parallel)..."
time xargs -P "$(nproc)" -I{} bash -c 'ref "$@"' _ {} < "$LOGS" | sort > /tmp/ref.tsv

# C++: one process, batch.
echo "Running C++ rqg_verdict (single process)..."
time ./util/rqg_verdict --dump="$DUMP" --logs="$LOGS" 2>/tmp/cpp.err | sort > /tmp/cpp.tsv

# Compare
echo "=== diff summary ==="
join -t$'\t' /tmp/ref.tsv /tmp/cpp.tsv > /tmp/joined.tsv
TOTAL=$(wc -l < /tmp/joined.tsv)
MISMATCH=$(awk -F'\t' '$2!=$3' /tmp/joined.tsv | tee /tmp/mismatch.tsv | wc -l)
echo "compared:  $TOTAL"
echo "mismatches: $MISMATCH"
if [ "$MISMATCH" -gt 0 ]; then
  echo "--- first 20 mismatches (log / perl / cpp) ---"
  head -20 /tmp/mismatch.tsv | awk -F'\t' '{print $1"\n  perl: "$2"\n  cpp : "$3}'
fi
# logs present in one set but not the other
comm -3 <(cut -f1 /tmp/ref.tsv) <(cut -f1 /tmp/cpp.tsv) | head
