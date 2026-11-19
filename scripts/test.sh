#!/bin/zsh
# Runs the Swift Testing suite. With only the Command Line Tools installed (no Xcode),
# Testing.framework lives outside the default search paths, so point the compiler and linker at it.
# Extra arguments are passed through, e.g. scripts/test.sh --filter PostTests
set -euo pipefail
cd "$(dirname "$0")/.."

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
FLAGS=()
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  FW="$DEV_DIR/Library/Developer/Frameworks"
  # The CLT ship an empty _Testing_Foundation overlay module, so turn cross-import overlays off.
  FLAGS=(-Xswiftc -F"$FW" -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
fi

exec swift test "${FLAGS[@]}" "$@"
