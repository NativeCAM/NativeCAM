---
title: Glossary
---
# Glossary

| Term | Meaning |
|---|---|
| Acceptance program | NativeCAM's controller test: a square, circles in all quadrants, a helix, a dwell and two tool changes, cut 0.5 mm deep |
| Adaptive clearing | Clearing in loops that keep the bit's engagement constant, instead of offset rings |
| Air cut | The same program with every Z raised, run above the material to check the moves |
| Allowance | Material left on a wall or surface for a later pass |
| A axis | The rotary axis, turning about X (or Y) |
| Climb / conventional | Which way the bit's edge meets the wood: climb milling cuts with the feed, conventional against it (for a clockwise, M3, spindle) |
| Clearance tool | A larger bit that clears a pocket or V-carve's open area before the main bit |
| Collet / stickout | The collet holds the bit; the stickout is the length out of it |
| Corner relief | Dogbone (along the corner's bisector) or T-bone (along one side): a notch that lets a square part fit a pocket cut with a round bit |
| Dwell | A pause in the program (`G4`, or `PAUSE` on ShopBot), in seconds or milliseconds by controller |
| Estimate | NativeCAM's run time, from the controller's planner model and the machine's accelerations |
| Extents | The range of X, Y and Z a program moves over |
| Feed / plunge rate | Speed along the cut / speed down into the material |
| Finishing pass | A separate light lap that cuts a profile to size after the roughing |
| `G20` / `G21` | Inch / millimetre units |
| `G54` | The work coordinate system the zero is stored in |
| `G93` / `G94` | Inverse-time feed (each move's F is 1 / its time in minutes) / normal feed per minute |
| Indexed (3+1) | Rotary work cut on fixed faces, the blank turned between them |
| Inlay: P, G, C | Pocket depth, glue gap, surface clearance |
| Lead-in / lead-out | An arc or line onto and off the wall, in the waste |
| Level 0–3 | This book's stages: read-only, air cut, shallow cut, full cut |
| `M0` / `M00` | Program stop: waits for Cycle Start |
| `M3` / `M5` | Spindle on clockwise / off |
| `M6` | Tool change |
| `M30` | Program end |
| Nesting | Placing parts on sheets by their true shapes |
| Pass / pass depth | One layer of a toolpath / how deep each layer goes |
| Peck drilling | Drilling in steps, lifting to clear chips |
| Post (post processor) | The part of NativeCAM that writes one controller's dialect |
| Ramp entry | Descending along the cut instead of plunging straight down |
| Rest machining | A smaller bit cutting only what a larger bit couldn't reach |
| Restart file | The rest of a job from a toolpath, pass or line, for after a stop |
| Rounding | Turning a rotary blank round |
| Setup sheet | The printable page NativeCAM writes with the material, zero, tools and run order |
| Soft limits | The controller's travel limits, set in software |
| Spoilboard | The sacrificial board on the bed that through-cuts go into |
| Tabs | Bridges left on a cut-out to hold the part |
| Tiling | Cutting a board longer than the machine reaches, moving it between files |
| Touch plate | A plate the bit touches to set Z zero |
| Tram | How square the spindle is to the bed |
| Turn speed | How fast the rotary axis can turn (degrees per minute) |
| Wrapped | Rotary work where the design wraps round the blank and A turns while cutting |
| Zero (XY, Z) | The point the program's coordinates are measured from |
