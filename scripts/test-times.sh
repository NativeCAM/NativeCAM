#!/bin/zsh
# Lists the slowest tests by their own time. It runs the suite one test at a time (scripts/test.sh --no-parallel), so
# each "passed after" time is the test's own work. In a normal, parallel run that time also counts the wait for a free
# thread before and after the test runs, which is most of the run for nearly every test.
#
# Usage: scripts/test-times.sh [count] [swift test arguments], e.g. scripts/test-times.sh 40 --filter Nesting
# Lists the 20 slowest by default. The whole log goes to .build/test-times.log.
set -euo pipefail
cd "$(dirname "$0")/.."

count=20
if [[ $# -gt 0 && "$1" == <-> ]]; then
  count=$1
  shift
fi

mkdir -p .build
log=.build/test-times.log
test_status=0
scripts/test.sh --no-parallel "$@" > "$log" 2>&1 || test_status=$?

# "✔ Test name() passed after 1.234 seconds." or "✘ Test name() failed after …", slowest first.
perl -ne 'print "$2 s\t$1\n" if /^\S+ Test (?!run with )(.+?) (?:passed|failed) after ([0-9.]+) seconds/' "$log" \
  | sort -rn | head -n "$count"
tail -n 1 "$log"
exit $test_status
