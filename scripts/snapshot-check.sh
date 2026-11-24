#!/bin/zsh
# Runs the app's snapshot mode on each project in scripts/snapshot-projects.txt and fails when a run's main-window
# capture (window.png) isn't a real frame, or any other check it logs fails. A blank window.png is easy to miss by eye.
#   scripts/snapshot-check.sh           with build/NativeCAM.app as it is
#   scripts/snapshot-check.sh --build   builds the app first (scripts/build-app.sh)
# Each run's PNGs and log go to .build/snapshot-check/<project>/. The app draws its window on screen for a moment, all
# but a column of points past the screen's right edge, and quits after each run.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--build" ]]; then scripts/build-app.sh; fi
APP=build/NativeCAM.app/Contents/MacOS/NativeCAM
if [[ ! -x "$APP" ]]; then
  echo "No $APP: run scripts/build-app.sh first, or pass --build."
  exit 1
fi
OUT=.build/snapshot-check
rm -rf "$OUT"
mkdir -p "$OUT"
failed=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  project="${line%% -*}"
  flags="${line#"$project"}"
  name="${${project:t}:r}"
  dir="$OUT/$name"
  mkdir -p "$dir"
  # The paths go in as -Key value pairs: a plain file argument would be opened as a document.
  "$APP" -NativeCAMSnapshotProject "$PWD/$project" -NativeCAMSnapshotOut "$PWD/$dir" ${=flags} > "$dir/log.txt" 2>&1 || true
  if [[ -s "$dir/window.png" ]] && grep -q "check PASS: window.png is a real frame" "$dir/log.txt" && ! grep -q "check FAIL" "$dir/log.txt"; then
    echo "PASS  $project"
  else
    echo "FAIL  $project"
    if grep -q "check FAIL" "$dir/log.txt"; then
      grep "check FAIL" "$dir/log.txt" | sed 's/^snapshot: /      /'
    else
      echo "      no window.png, or no window check in $dir/log.txt"
    fi
    failed=1
  fi
done < scripts/snapshot-projects.txt
exit $failed
