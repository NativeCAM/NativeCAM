#!/bin/zsh
# build-kit.sh: rebuilds the Validation Handbook and its test kit.
#
#   docs/validation/build-kit.sh               projects, programs, images, both PDFs
#   docs/validation/build-kit.sh --no-projects  keep the committed projects as they are
#   docs/validation/build-kit.sh --no-pdf       stop before rendering the PDFs
#
# 1. Builds nativecam-cli (release), or uses $NATIVECAM_CLI.
# 2. Writes the test projects into docs/validation/projects/ (tools/make-projects.py).
# 3. Runs every command the test pages print, into docs/validation/build/out/
#    (G-code, setup sheets, calibration and surfacing programs), and draws each
#    test's heightmap into docs/validation/images/ (tools/run-kit.py). It stops if
#    any project fails to post: nothing in the kit is ever written with --force.
# 4. Builds the handbook's HTML (tools/build-handbook.py) and renders the US Letter
#    and A4 PDFs with macOS's own WebKit (tools/render-pdf.swift).
#
# Needs only the Command Line Tools: swift, python3 and macOS's frameworks.
# It writes files only. It never talks to a machine.
#
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
V=docs/validation
B=$V/build
mkdir -p $B

projects=1; pdf=1
for a in "$@"; do
  case $a in
    --no-projects) projects=0 ;;
    --no-pdf) pdf=0 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

if [[ -n "${NATIVECAM_CLI:-}" ]]; then
  CLI="$NATIVECAM_CLI"
else
  swift build -c release --product nativecam-cli
  CLI="$PWD/.build/release/nativecam-cli"
fi

if (( projects )); then
  python3 $V/tools/make-projects.py "$CLI" "$B/base"
fi
rm -rf $B/out
python3 $V/tools/run-kit.py "$CLI"

python3 $V/tools/build-handbook.py letter $B/handbook-letter.html
python3 $V/tools/build-handbook.py a4 $B/handbook-a4.html

if (( pdf )); then
  swiftc -O -o $B/render-pdf $V/tools/render-pdf.swift
  $B/render-pdf $B/handbook-letter.html $V/NativeCAM-Validation-Handbook.pdf letter
  $B/render-pdf $B/handbook-a4.html $V/NativeCAM-Validation-Handbook-A4.pdf a4
fi
echo "Programs and setup sheets: $B/out"
