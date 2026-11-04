#!/bin/sh
# Runs every headless test suite. Exit code is non-zero if any fails.
cd "$(dirname "$0")/.." || exit 1
status=0
for t in tools/host_test.lua tools/tests/*.lua; do
  out=$(lua5.4 "$t" 2>&1) || status=1
  printf '%-24s %s\n' "$t" "$(printf '%s\n' "$out" | tail -1)"
done
exit $status
