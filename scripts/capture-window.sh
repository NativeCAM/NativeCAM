#!/bin/zsh
# Asks the running NativeCAM to save PNGs of its own windows (developer aid), then prints the newest file(s).
#   scripts/capture-window.sh                         capture as-is
#   scripts/capture-window.sh tag=vcarve select=op:0   put the front window in a state first, then capture
#   keys: select=setup|none|op:N|shape:N  simulate=0..1|stop  view=top|front|iso  tools=1  inspector=show|hide
#         optimize=1 (Toolpaths ▸ Optimize Run Order)  views=1 (also write scroll-view frames to views.txt)  tag=name
set -euo pipefail
DIR="$HOME/Library/Caches/NativeCAM/Captures"
PAIRS=""
for kv in "$@"; do PAIRS+="\"${kv%%=*}\": \"${kv#*=}\", "; done
swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(\"com.nativecam.debug.capture\"), object: nil, userInfo: [${PAIRS:-:}], deliverImmediately: true)"
sleep $(( $# > 0 ? 3 : 1 ))
ls -t "$DIR"/*.png 2>/dev/null | head -${COUNT:-2}
