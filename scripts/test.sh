#!/bin/zsh
# Runs the Swift Testing suite. With only the Command Line Tools installed (no Xcode),
# Testing.framework lives outside the default search paths, so point the compiler and linker at it.
# Extra arguments are passed through, e.g. scripts/test.sh --filter PostTests
#
# Tests are compiled with optimization (in their own build folder, .build/tests): the CAM engine's geometry and
# simulation run ~100x slower unoptimized, which turns a few-second suite into minutes. For a debuggable,
# unoptimized run use: NATIVECAM_TEST_DEBUG=1 scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
FLAGS=()
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  FW="$DEV_DIR/Library/Developer/Frameworks"
  # The CLT ship an empty _Testing_Foundation overlay module, so turn cross-import overlays off.
  FLAGS=(-Xswiftc -F"$FW" -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
fi

if [[ -z "${NATIVECAM_TEST_DEBUG:-}" ]]; then
  FLAGS+=(-Xswiftc -O)
  # Keep optimized test builds apart from normal debug builds, unless the caller picked a folder.
  if [[ " $* " != *" --scratch-path "* ]]; then FLAGS+=(--scratch-path .build/tests); fi
fi

exec swift test "${FLAGS[@]}" "$@"
