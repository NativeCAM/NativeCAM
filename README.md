# NativeCAM

Apple-silicon-native 2.5D CAM for **Avid CNC** routers running Avid's **Mach4** profile. SwiftUI + Metal, no Rosetta, no Electron.

Design or import vectors, set up the material and tools, generate profile / pocket / drill / V-carve toolpaths, watch a material-removal simulation, and export `.tap` G-code in the dialect Avid's own posts produce.

## Build & run

Needs macOS 14+ and the Swift 6 toolchain (the Command Line Tools are enough; Xcode is optional).

```bash
scripts/build-app.sh --open      # builds build/NativeCAM.app (arm64, release) and launches it
scripts/test.sh                  # Swift Testing suite (adds the CLT Testing.framework flags when needed)
```

Developer aid: with the app running, `scripts/capture-window.sh` saves PNGs of its windows exactly as shown on screen (e.g. `scripts/capture-window.sh tag=sim simulate=0.5` or `select=op:0`, `tools=1`) to `~/Library/Caches/NativeCAM/Captures/`.

In the app, **File ▸ New Demo Sign Project** opens a 2.5D sample job, and **File ▸ New Demo Relief Project (3D)** a 3D relief medallion with roughing, finishing and a cut-out.

### Canvas controls (Mac conventions)

| Action | How |
|---|---|
| Select | Click a vector's line (text: click inside a letter); Shift/⌘-click to add or remove |
| Marquee select | Drag on empty canvas in Top view (⌘1) |
| Move | Drag selected vectors, or nudge with arrow keys (Shift = 10×) |
| Orbit | Drag empty canvas in 3D views, or Option-drag anywhere; trackpad rotate spins |
| Pan / zoom | Two-finger scroll or right-drag / pinch or scroll wheel |
| Edit | Cut, Copy, Paste, Duplicate (⌘D), Delete, Select All, Undo/Redo from the Edit menu |
| Context menu | Right-click or Control-click a vector: add toolpaths, duplicate, center on material, views |
| Import | Drop DXF/SVG files on the canvas (or ⌘I); drop a `.tap` to simulate it |

Command-line front end (same engine, no UI):

```bash
swift run -c release nativecam-cli demo demo.nativecam            # write the demo sign project (demo3d: 3D relief, new: empty)
swift run -c release nativecam-cli post demo.nativecam -o demo.tap # toolpaths + checks + G-code
swift run -c release nativecam-cli sim demo.nativecam --png out.png # simulate, report, render the result
swift run -c release nativecam-cli sim some-vcarve-job.tap        # simulate G-code from any CAM program
```

## What's in v0.1

| Area | Details |
|---|---|
| Job setup | Material size and **thickness**, XY zero (corners/centre), Z zero (material top or spoilboard), safe/plunge heights, park position. Display in inches or mm. |
| Machine | Avid PRO4848 / PRO4896 / PRO6060 presets (default: PRO6060, VFD spindle, manual tool change with touch plate) or custom travel. Router vs spindle, RPM range, ATC / M6 / M0 tool changes, dust collector M7/M9, spin-up dwell. |
| Tools | Library with real geometry: flat, ball, bull nose, V-bit, engraving (tip diameter), surfacing, drill. Flute length, shank, stickout, flute count and direction, feeds/speeds, chip-load calculator, live profile drawing. Saved in `~/Library/Application Support/NativeCAM/tools.json`. |
| Design | Rectangle (corner radius), circle, ellipse, polygon, star, and **text from any installed macOS font** (CoreText outlines). Move/rotate/scale. |
| Import: vectors | **DXF** (lines, arcs, circles, polylines with bulges, splines, ellipses, blocks/inserts, `$INSUNITS`, POINTs → drill marks; loose segments chained into closed loops), **SVG** (full path grammar, transforms, viewBox units), **PDF** and PDF-compatible **Illustrator .ai** (nested artwork groups, page rotation, crop box). |
| Import: 3D models | **STL** (binary/ASCII), **OBJ**, **3MF** (incl. Bambu/Prusa multi-part), **USDZ/USD** and **PLY** (via Model I/O). Choose the up axis, flip, width/height, carve depth (or keep true proportions) and how far below the surface the top sits. |
| 3D toolpaths | **3D Roughing**: layered clearing with an end mill, leaving an allowance. **3D Finishing**: raster passes with an exact triangle drop-cutter (ball and flat bits) so steep walls can't be gouged; scallop height shown. Machine inside the model outline or the whole material (relief stands proud). |
| Toolpaths | **Profile** inside/outside/on with climb/conventional, multi-pass, ramp entry, tabs, allowance, holes-before-outside ordering. **Pocket** offset or raster with islands and safe feed links. **Drill** with peck/chip-break/dwell. **V-carve** by maximal inscribed circles with flat-depth cap, optional flat-area clearing tool, multi-pass. Arcs re-fitted (G2/G3, helical too). |
| Checks | Cuts into the spoilboard vs material thickness, depth beyond flute length, toolpath larger than work area, Z clearance, RPM range, feed limit, sideways rapids below the surface. |
| Simulator | Heightmap carved by the true tool shape (flat/ball/bull/V), Metal-rendered carved stock with through-cuts, tool marker, play / pause / scrub / speed, cycle-time estimate, rapid-through-material detection. Also simulates external `.tap`/`.nc` files. |
| Output | Avid Mach4 `.tap` (see below). |

## Avid Mach4 G-code dialect

Modelled on Avid's own Vectric post (v3) and Fusion 360 post:

- CRLF line endings, `.tap` extension, parenthesised comments (nested parens become braces)
- Safety line `G00 G94 G20 G17 G90 G40 G49 G80` (or `G21`), then `G91.1` (incremental I/J)
- Tool change: retract, `M05`, `T#M6` (Avid's M6 macro handles the manual change + touch plate); `G43 H#` added for ATC machines; optional `M00` pause mode for setups without an M6 macro
- `M07` dust collector on after each tool change, `S#### M03`, optional `G04 P#` spin-up dwell
- Arcs as `G02/G03 … I J` under 180°; 4 decimals in inches, 3 in mm
- Footer: retract, park, `M05`, `M09`, `M30`

> Always check new output on your machine with an air cut first. Default feeds and speeds are conservative starting points for plywood/hardwood, not recommendations for every bit and material.

## Layout

```
Sources/
  CClipper2/      Vendored Clipper2 2.0.1 (Boost license) + a small C bridge
  CAMCore/        Engine (pure Swift, no UI): geometry, model, importers, toolpaths, simulation, post
  NativeCAM/      SwiftUI app; Viewport/ is the Metal renderer (shaders compiled at runtime)
  nativecam-cli/  Command-line front end
Tests/CAMCoreTests/  Swift Testing suite + fixtures
scripts/          build-app.sh, test.sh
```

All lengths inside CAMCore are millimetres; design XY is relative to the material's lower-left corner and Z = 0 is the material top. The post converts to the chosen work origin and units.

## Third-party code and test data

- **Clipper2** 2.0.1 by Angus Johnson, Boost Software License 1.0 (`Sources/CClipper2/clipper2/LICENSE`). Its `Polygons.txt` / `Lines.txt` regression fixtures run against our bridge.
- Test fixtures from **dxf-parser** (MIT) and **resvg** (MIT/Apache-2.0); see the `SOURCE.md` files under `Tests/CAMCoreTests/Fixtures/`.

## Known limits / next steps

- 3D finishing is a single raster direction per toolpath (add a second at 90° for cross-hatching); no waterline/pencil passes yet.
- V-bit and bull-nose 3D finishing use the height-grid drop-cutter (exact triangle drop is ball and flat only).
- PDF clipping masks and hidden layers aren't applied; EPS isn't supported.
- Selection in the 3D view (click to pick vectors) isn't wired up yet; use the Design list.
- No lead-in/lead-out arcs, dogbones, nesting, or plasma (THC) support yet.
- Canned drill cycles (G81–G83) in imported G-code aren't simulated; NativeCAM's own output expands them.
