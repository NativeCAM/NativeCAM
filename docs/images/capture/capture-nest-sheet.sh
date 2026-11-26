#!/bin/zsh
# Regenerates docs/images/nest-parts-sheet.png (docs/using-nativecam.md, Nesting parts) with the app's snapshot mode:
# the demo shelf parts (nativecam-cli demonest) nested on one sheet with today's default spacing, 300 layouts.
# The sheet names only the bit, never the machine. Build first:
#   scripts/build-app.sh && swift build -c release --product nativecam-cli
#   docs/images/capture/capture-nest-sheet.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."
OUT="$(mktemp -d)"
.build/release/nativecam-cli demonest "$OUT/Shelf.nativecam" >/dev/null
build/NativeCAM.app/Contents/MacOS/NativeCAM \
    -NativeCAMSnapshotProject "$OUT/Shelf.nativecam" -NativeCAMSnapshotOut "$OUT" \
    -NativeCAMSnapshotNest YES -NativeCAMSnapshotNestSheets 1 \
    | grep "check FAIL" && { echo "a snapshot check failed; see $OUT" >&2; exit 1; }
# The sheet renders at 940 × 720, the size the doc uses.
cp "$OUT/nest-sheet.png" docs/images/nest-parts-sheet.png
echo "Wrote docs/images/nest-parts-sheet.png (snapshot output in $OUT)"
