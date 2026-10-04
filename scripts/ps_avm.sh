#!/usr/bin/env bash
# List running AVM encoder/decoder processes (pid, elapsed time, output file).
for p in $(pgrep -x avmenc; pgrep -x avmdec); do
  printf '%s %s ' "$p" "$(ps -o etime= -p "$p" | tr -d ' ')"
  tr '\0' ' ' < "/proc/$p/cmdline" | grep -o -E -- '-o [^ ]+|--limit=[0-9]+|--cpu-used=[0-9]+' | tr '\n' ' '
  echo
done
echo "running: $( (pgrep -x avmenc; pgrep -x avmdec) | wc -l )"
