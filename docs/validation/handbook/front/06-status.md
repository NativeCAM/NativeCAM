---
title: What has been verified
---
# What has been verified

This is where NativeCAM stands at this handbook's build. Every result you report moves a row.

## Controllers

| Controller | Machines | Files | Status |
|---|---|---|---|
| Avid Mach4 | Avid PRO series on Mach4 | `.tap` | **Run on a real machine** (basic 2.5D output). Reference setup for this book |
| Grbl 1.1, grblHAL, FluidNC, Carbide Motion | Many hobby machines | `.nc` | From documentation and firmware source; not yet run |
| LinuxCNC | LinuxCNC and PathPilot machines | `.ngc` | From documentation; not yet run |
| Masso | Masso G3 machines | `.nc` | From documentation; not yet run |
| Centroid CNC12 | Acorn, Oak, Avid EX | `.cnc` | From Avid's EX posts; not yet run |
| Buildbotics | Buildbotics-based machines | `.nc` | From documentation; not yet run |
| ShopBot | ShopBot (OpenSBP) | `.sbp` | From the command reference; not yet run |
| RichAuto DSP | Many full-sheet routers | `.nc` | Conservative (undocumented); not yet run |

## Features

Even on Avid Mach4, these have **not** yet been cut on a real machine: finishing passes on profiles, triangular and hand-placed tabs, chosen start points, rest machining, adaptive clearing, helical boring, inlays, chamfers, flutes, prisms, edge profiles, form and dovetail bits, mouldings, 3D finishing other than raster (waterline, steep and shallow, pencil, constant scallop, spiral, radial), 3D rest finishing, holding tabs on 3D cut-outs, nesting, tiling, every rotary job (indexed, turned by hand, wrapped, rounding, 3D rotary roughing and finishing), restarts, toolpath groups, feeds that follow the load, automatic spindle speed, every calibration program and spoilboard surfacing. Run-time estimates haven't been timed against a real machine either.

## Open questions only a machine can answer

These come up in several tests. Each is answered by a test; write the answer on the sign-off sheet too.

| Question | Answered by |
|---|---|
| Which way does +A turn the blank on your rotary (along X: the top should roll toward −Y)? | VH-ROT-01 |
| Does your controller run `G93` (inverse time) correctly: does `G93 G01 A360 F10` take 6.0 s? | VH-ROT-02 |
| Does your M6 macro raise Z before it moves, and in rotary mode does it zero Z on the axis or on the face? | VH-CTL-01, VH-ROT-03 |
| Does your controller keep constant-velocity blending through a change of feed (the F-change line)? | VH-CAL-01 |
| Do G54 and the A position survive a power cut? | VH-RST-03 |
| How far does the controller's highlighted line run ahead of the tool? | VH-RST-02 |
| Where does the machine home, and where are its soft limits? | VH-SRF-03 |
| Does your M6 macro cope with a file whose first tool is already in the spindle? | VH-GRP-01 |

## Pending changes

Two changes were still open when this book was built. Their tests are marked *After PR #N merges*: run them only on a build that includes the change.

- **PR #205**, profiles cut to a 3D model's exact outline: test **VH-3D-06**.
- **PR #206**, model-following flutes measured from the stock left over the model. It refuses files that would bury the collet nut, so there's nothing to cut. With a build that includes it, Level 0 of **VH-SHP-01** still applies, and `post` should refuse the PR's `flute-reach/leg-flutes-before-finish.nativecam` fixture with an error that the flutes go down "through the stock over the 3D model".
