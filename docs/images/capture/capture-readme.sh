#!/bin/zsh
# Regenerates the README's sign screenshots (app-window.png, sign-toolpaths.png, sign-simulated.png) with the app's
# snapshot mode, from "README Sign.nativecam": the demo sign with "MAKE" for its title and a custom machine, so the
# images show no machine maker's name. The app's own demo and defaults are unchanged.
#   docs/images/capture/capture-readme.sh            (build the app first with scripts/build-app.sh)
set -euo pipefail
cd "$(dirname "$0")/../../.."
OUT="$(mktemp -d)"
build/NativeCAM.app/Contents/MacOS/NativeCAM \
    -NativeCAMSnapshotProject "$PWD/docs/images/capture/README Sign.nativecam" -NativeCAMSnapshotOut "$OUT" \
    | grep "check FAIL" && { echo "a snapshot check failed; see $OUT" >&2; exit 1; }
# The 1600 × 1000 viewport renders, cropped to the README's 1400 × 760 framing (offset 60, 200).
sips -c 760 1400 --cropOffset 200 60 "$OUT/sim-iso.png" --out docs/images/sign-simulated.png >/dev/null
sips -c 760 1400 --cropOffset 200 60 "$OUT/toolpaths-iso.png" --out docs/images/sign-toolpaths.png >/dev/null
# The 1500 × 932 window, scaled to 1440 wide and padded (transparent) to 1440 × 900.
sips -z 895 1440 "$OUT/window.png" --out "$OUT/window-1440.png" >/dev/null
sips -p 900 1440 "$OUT/window-1440.png" --out docs/images/app-window.png >/dev/null
echo "Wrote docs/images/{app-window,sign-toolpaths,sign-simulated}.png (snapshot output in $OUT)"
