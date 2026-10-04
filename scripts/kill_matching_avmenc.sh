#!/usr/bin/env bash
# Kill avmenc processes whose command line contains the given substring.
# Usage: kill_matching_avmenc.sh <substring>
pat=${1:?substring required}
for p in $(pgrep -x avmenc); do
  if tr '\0' ' ' < "/proc/$p/cmdline" | grep -q -- "$pat"; then
    kill "$p" && echo "killed $p"
  fi
done
