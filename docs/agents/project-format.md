# The .nativecam project format

[← Back to AGENTS.md](../../AGENTS.md)

A `.nativecam` file is UTF-8 JSON, written by Swift's `JSONEncoder` with sorted keys. This page describes it as the code on `main` reads it: [`Project.swift`](../../Sources/CAMCore/Model/Project.swift), [`Operation.swift`](../../Sources/CAMCore/Model/Operation.swift), [`Design.swift`](../../Sources/CAMCore/Model/Design.swift), [`Stock.swift`](../../Sources/CAMCore/Model/Stock.swift), [`Machine.swift`](../../Sources/CAMCore/Model/Machine.swift) and [`Tool.swift`](../../Sources/CAMCore/Model/Tool.swift). When this page and the code disagree, the code is right.

- [Start from a file the CLI wrote](#start-from-a-file-the-cli-wrote)
- [Top level](#top-level)
- [Units](#units)
- [Format versions](#format-versions)
- [How Swift encodes it](#how-swift-encodes-it)
- [stock](#stock)
- [machine](#machine)
- [shapes](#shapes)
- [3D models](#3d-models)
- [Layers](#layers)
- [operations](#operations)
- [tool](#tool)
- [Toolpath kinds](#toolpath-kinds)
- [How a toolpath finds its shapes](#how-a-toolpath-finds-its-shapes)
- [A minimal project](#a-minimal-project)
- [When a project won't load](#when-a-project-wont-load)
- [Toolpath templates](#toolpath-templates)

## Start from a file the CLI wrote

Don't write a project from nothing. `nativecam-cli new` writes an empty project with every required key, and `demo`, `demo3d`, `demonest` and `demosheets` write projects with real tools in them. Copy tools from those files, or from [`examples/`](../../examples/) and [`Tests/CAMCoreTests/Fixtures/projects/`](../../Tests/CAMCoreTests/Fixtures/projects/): the fixtures hold at least one saved project for most features, named for the format that brought it in (`chamfer-v19.nativecam`, `rough3d-adaptive-v26.nativecam`). Then check every change with `nativecam-cli post`.

## Top level

| Key | Type | Required | Meaning |
|---|---|---|---|
| `formatVersion` | integer | yes | See [Format versions](#format-versions) |
| `name` | string | yes | The job's name, written into the G-code header |
| `displayUnits` | `"inch"` or `"mm"` | yes | The units the app shows and the CLI prints and takes (`nest`) |
| `notes` | string | yes | Free text |
| `stock` | object | yes | The material: [stock](#stock) |
| `machine` | object | yes | The machine and controller: [machine](#machine) |
| `shapes` | array | yes | The design: [shapes](#shapes) |
| `operations` | array | yes | The toolpaths, in run order: [operations](#operations) |
| `tiling` | object | no | Cutting a job bigger than the bed in tiles; see [`TilingSettings.swift`](../../Sources/CAMCore/Model/TilingSettings.swift) and the `tiled-*` fixtures |
| `additionalSheets` | array of `{"width", "height"}` | no | Sheets after the first on a job nested onto several. Written only when there are some. `nest` writes it for you |
| `layers` | array of strings | no | Layers made by name with no shapes on them yet (`template apply --create-layers` writes them) |
| `toolpathGroups` | array | no | Toolpath groups, in run order: [Toolpath groups and hiding](#toolpath-groups-and-hiding). Written only when there are some |

Toolpaths and G-code are never stored. They're generated from the project every time.

## Units

- **Every length in the file is in millimetres**, whatever `displayUnits` and `machine.outputUnits` say. That includes depths, tool sizes, positions, heights and travel. 1 in = 25.4 mm.
- **Feeds** (`feedRate`, `plungeRate`, `maxFeedRate`, `rapidRateForEstimates`, `rapidRateZ`) are mm/min. **Accelerations** are mm/s². `turnSpeed` is degrees per minute. Spindle speeds are RPM. Dwell is seconds.
- **Angles** are degrees: shape `rotation` counter-clockwise, `rasterAngle` from X, `includedAngle` across the V, `indexAngles` round the rotary axis.
- **Fractions** (`stepoverFraction`, `optimalLoad`, `rampPercent`) are 0–1 of the tool's diameter, or of the ramp's longest length.
- **Design coordinates.** X and Y are mm from the material's lower-left corner, whatever the work origin (`stock.xyOrigin`). The post moves them to the origin. **Depths are positive numbers measured down from the material top**; Z = 0 is the material top and Z = −thickness its bottom.
- `displayUnits` and `outputUnits` change only what's shown and what's written into the G-code. Chip loads in messages are always given in inches, as the charts are.

The demo files show binary rounding (`19.049999999999997` for 0.75 in). That's normal; write round millimetre values or `inches × 25.4`.

## Format versions

`Project.currentFormatVersion` (31 on `main`) is the newest format this build reads. Reading a file:

- a `formatVersion` above it is refused: `This project was saved by a newer version of NativeCAM (format 99).`
- a `formatVersion` at or below it is read. **The number isn't otherwise used on reading.** A file marked `1` that holds an adaptive pocket loads and posts like one marked `13`.

Writing a file, NativeCAM sets `formatVersion` to the *oldest* format that can hold the project: the highest `requiredFormatVersion` of its machine, stock, shapes, toolpaths and their vector rules, tiling and sheets. An older build then refuses a file it would misread (for example, a format-12 build reading an adaptive pocket) rather than cutting it wrong. A flat job on Avid's Mach4 profile with only the older features is still format 1, so old builds keep opening it.

**When you write a file by hand, set `formatVersion` to what its features need** (see the table), or simply to `Project.currentFormatVersion`. A number that's too high is safe: older builds refuse the file. A number that's too low isn't: an older build would open it and drop what it doesn't know. Any CLI command that saves a project (`import`, `rebind`, `save`, `nest`, `template apply`, `machine --apply`, `calibrate fit --apply`) writes the right number; after a hand edit, `nativecam-cli save edited.nativecam -o fixed.nativecam` rewrites it and prints the format before and after. `post` and `sim` never save.

What raises it, from the code:

| Format | Feature |
|---|---|
| 2 | A machine other than Avid's Mach4 profile (a `controller`, a `customPost`) or one with a `rotary` axis |
| 3 | Rotary stock; `indexAngles` on a toolpath |
| 4 | A rotary job whose blank is turned by hand (`manualIndexing`) |
| 5 | A wrapped rotary layout; a `spiral` shape; `rounding` |
| 6 | A V-carve `startDepth` above 0; an inlay plug |
| 7 | A 3D model on a rotary blank; `rotaryFinish` |
| 8 | `chamfer`, `fluting`, `prism` |
| 9 | Tiling that splits the job |
| 10 | 3D finishing other than one raster (waterline, steep and shallow, pencil, cross-hatching) |
| 12 | `rotaryRough` |
| 13 | An adaptive pocket (`"strategy": "adaptive"`) |
| 14 | A whole-board inlay plug (`"boundary": "board"`) |
| 15 | A tapered ball nose, form or dovetail bit |
| 16 | A job nested onto more than one sheet |
| 17 | 3D rest finishing (`"strategy": "rest"`) |
| 18 | `edgeProfile` |
| 19 | A chamfer with an `overcut`, or a chamfer cut with a form bit |
| 20 | A size rule in a `vectorSelection` |
| 21 | Constant scallop, spiral and radial 3D finishing |
| 22 | `moulding` |
| 25 | Flutes that follow a 3D model (`surfaceModelID`) |
| 26 | Adaptive 3D roughing (`"clearing": "adaptive"`) |
| 27 | A `cutDirection` other than the toolpath's default |
| 28 | A profile's `finishPass` |
| 29 | A profile's triangular tabs (`"shape": "triangular"`), tabs placed by hand (`placed`) or `startPoints`, on an inside or outside cut |
| 30 | A flat 3D roughing or finishing that leaves strips under a tabbed cut-out's tabs (saved with `"holdsTabs": true`, below) |
| 31 | A drill's `helix` (Drill ▸ Method ▸ Helical bore) |

The code names no feature for formats 11, 23 or 24. Settings that change nothing for an older build don't raise the format (`fromBottom`, `restFromEarlier`, `flatRaster`, `adjustFeedsForLoad`, `spindleSpeed`, the `layers` list).

**A new feature that an older build would misread bumps `currentFormatVersion` by one** and adds its `requiredFormatVersion` case. It also adds a saved project to `Tests/CAMCoreTests/Fixtures/projects/` that must keep loading and posting the same bytes (see [Verifying output](verification.md#goldens-and-scriptstestsh)). Saved fixtures are never regenerated.

## How Swift encodes it

The file follows Swift's `Codable` rules, which matter when writing it by hand:

- **An enum with associated values** is an object with one key, the case name. An unlabelled value goes under `"_0"`: `{"profile": {"_0": {…}}}`, `{"text": {"_0": {…}}}`, `{"paths": {"_0": [ … ]}}`. Labelled values go under their labels: `{"rectangle": {"width": 100, "height": 50, "cornerRadius": 0}}`.
- **A plain enum** is its raw string: `"climb"`, `"flatEndMill"`, `"lowerLeft"`.
- **Vectors** are `{"x": …, "y": …}` and `{"x": …, "y": …, "z": …}`. **UUIDs** are strings: any valid UUID will do, upper case as Swift writes them.
- **A missing optional key** means nil (the default the tables below give). **A missing required key, or a value of the wrong type or an unknown enum value, refuses the whole file.**
- **An unknown key is ignored without a word.** A misspelt optional key (`"fromBotom"`) is dropped, and the default is used.

## stock

| Key | Required | Meaning (mm) |
|---|---|---|
| `width`, `height`, `thickness` | yes | The material's size along X, along Y, and in Z |
| `materialName` | yes | Free text, written into the G-code header |
| `materialKind` | no (`plywood`) | For the chip-load charts: `plywood`, `hardwood`, `softwood`, `mdf`, `laminatedParticle`, `softPlastic`, `hardPlastic` |
| `xyOrigin` | yes | The work's X0 Y0: `lowerLeft`, `lowerRight`, `upperLeft`, `upperRight`, `center` |
| `zZero` | yes | `materialTop` or `machineBed` (the spoilboard) |
| `clearanceHeight` | yes | Safe Z above the material top (12.7 in `new`) |
| `plungeHeight` | yes | Where rapids down stop and the feed starts (2.54) |
| `homePosition` | yes | Park position `{"x", "y", "z"}`, relative to the origin (0, 0, 25.4) |
| `retractMode` | no (`minimum`) | `minimum` (links low over cleared material) or `full` (always to safe Z) |
| `linkSafeDistance` | no (5.08) | How far links stay above the material under them |
| `rotary` | no | A rotary blank; see below |

**Rotary blank** (`stock.rotary`): `shape` (`cylinder` or `squareBar`), `diameter` (across the faces for a square bar) and `length`, all required. `layout` is optional: absent means faces (indexed), and `"wrapped"` means designs wrap round the blank. `wrapDiameter` is also optional: the diameter a wrapped design is true to size at, the blank's own by default.

With a rotary blank, `width`, `height` and `thickness` must describe its design sheet, or `post` refuses the job with `The material size doesn't match the rotary blank`: `width` = `length`, `height` = `diameter` (or π × wrap diameter, wrapped), and `thickness` = half of `diameter` (or of the wrap diameter, wrapped). The machine needs a `rotary` axis too. See [Machines and posts](machines-and-posts.md#the-rotary-axis) and [Workflows](workflows.md#6-a-rotary-job-indexed-and-wrapped).

## machine

The machine profile is copied into each project, so it posts the same G-code whatever happens to the app's machine library. `new` writes the default, an Avid PRO6060 on Mach4. These keys are required:

| Key | Default in `new` | Meaning |
|---|---|---|
| `model` | `pro6060` | `pro4848`, `pro4896`, `pro6060` or `custom` |
| `travel` | 1558.925 × 1558.925 × 203.2 | Work area `{"x", "y", "z"}` |
| `spindle` | `vfdSpindle` | `vfdSpindle` (S word) or `router` (relay; speed set by hand) |
| `minRPM`, `maxRPM` | 6000, 24000 | The spindle's range |
| `toolChange` | `manualM6` | `manualM6`, `atc` or `manualPause` |
| `dustCollection` | `true` | Write the dust collector on and off |
| `spindleSpinUpDwell` | 0 | Seconds to wait after the spindle starts |
| `rapidRateForEstimates` | 20320 | X/Y rapid speed, mm/min |
| `maxFeedRate` | 10160 | Highest feed to ask for, mm/min (warnings above it) |
| `outputUnits` | `inch` | The G-code's units: `inch` or `mm` |
| `outputArcs` | `true` | Fit `G2`/`G3` arcs |
| `arcFitTolerance` | 0.01 | mm |
| `lineNumbers` | `false` | Write N numbers |

Optional keys: `controller` (`{"family": "grbl", "sender": "gSender", "firmware": "1.1h"}`; absent means Avid's Mach4 profile), `rotary`, `drive`, `accelerationXY`, `accelerationZ`, `rapidRateZ`, `junctionDeviation`, `lookaheadLines`, `toolChangeSeconds`, `roughingSmoothing`, `libraryID`, `libraryRevision`, `provenance` (where each value came from) and `customPost` (an imported Vectric post). See [Machines and posts](machines-and-posts.md).

## shapes

Each shape is placed on the material:

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | UUID; toolpaths refer to shapes by it |
| `name` | yes | Shown in the app and in messages |
| `kind` | yes | The geometry; see below |
| `position` | yes | Where the shape's local origin goes, design mm (the centre for drawn shapes and text) |
| `rotation` | yes | Degrees counter-clockwise about `position` |
| `scale` | yes | Uniform scale (1 = as defined) |
| `layer` | yes | Layer name (`"Default"` in the demos) |
| `keepOutHeight` | no | Marks a clamp or fixture: its height above the material top, mm. Nothing cuts inside it, and links go over it |
| `sheet` | no | On a job nested onto several sheets, which one (from 0; absent = the first) |

Shape kinds, in local coordinates (mm, centred on the origin):

| `kind` | Encoded as |
|---|---|
| Rectangle | `{"rectangle": {"width": w, "height": h, "cornerRadius": r}}` |
| Circle | `{"circle": {"radius": r}}` |
| Ellipse | `{"ellipse": {"radiusX": rx, "radiusY": ry}}` |
| Polygon | `{"polygon": {"sides": n, "radius": r}}` |
| Star | `{"star": {"points": n, "outerRadius": r1, "innerRadius": r2}}` |
| Text | `{"text": {"_0": {"string": "AVID", "fontName": "Helvetica-Bold", "capHeight": 88.9, "letterSpacing": 0}}}`: any macOS font by PostScript or family name; `capHeight` is the height of a capital H |
| Vectors (imported or free-form) | `{"paths": {"_0": [{"isClosed": true, "points": [{"x": …, "y": …}, …]}, …]}}`: polylines, the closing point not repeated |
| 3D model | `{"model": {"_0": {…}}}`: see [3D models](#3d-models) |
| Spiral (wrapped rotary only) | `{"spiral": {"_0": {"starts": 2, "pitch": …, "length": …, "around": …, "leftHanded": false}}}` |

Inside a `paths` shape, loops inside other loops are holes, as in any importer's output. Curves must be flattened to polylines first: a tolerance of 0.01–0.05 mm is what NativeCAM's importers use.

## 3D models

A model is stored in the project, mesh and all:

```json
{"model": {"_0": {
  "mesh": {"id": "…UUID…", "name": "Relief", "positions": "<base64>", "indices": "<base64>"},
  "upAxis": "z", "flipped": false, "depth": 10.16, "topOffset": 0
}}}
```

- `positions` is base64 of little-endian Float32 x, y, z triples in mm. `indices` is base64 of little-endian UInt32 triangles, three per triangle.
- `upAxis` (`x`, `y` or `z`) is the mesh's axis that points up, away from the table. `flipped` turns it upside down.
- `depth` is the carved model's height in Z, mm. `topOffset` is how far below the material top its highest point sits.
- `rotary` is optional: a placement on a rotary blank (format 7).

To add a model without the app's importer, write the mesh yourself. This Python, checked with `post` and `sim`, adds a 60 × 40 mm pyramid 8 mm tall:

```python
import base64, json, struct, uuid
pos = [-30,-20,0, 30,-20,0, 30,20,0, -30,20,0, 0,0,8]          # x, y, z per vertex (mm)
idx = [0,1,4, 1,2,4, 2,3,4, 3,0,4, 0,2,1, 0,3,2]                  # three vertex indices per triangle
mesh = {"id": str(uuid.uuid4()).upper(), "name": "Pyramid",
        "positions": base64.b64encode(struct.pack(f"<{len(pos)}f", *pos)).decode(),
        "indices": base64.b64encode(struct.pack(f"<{len(idx)}I", *idx)).decode()}
shape = {"id": str(uuid.uuid4()).upper(), "name": "Pyramid", "layer": "Default",
         "kind": {"model": {"_0": {"mesh": mesh, "upAxis": "z", "flipped": False, "depth": 8, "topOffset": 0}}},
         "position": {"x": 100, "y": 75}, "rotation": 0, "scale": 1}
```

Reading an STL with your own code is fine for a test. For the human's real files, prefer the app's importer, which also handles units, orientation and repairs.

## Toolpath groups and hiding

A group names a run of consecutive toolpaths in `operations`, one level deep (no groups in groups). The run order is still the array's order.

```json
"toolpathGroups": [
  {"id": "6E0C0000-0000-4000-8000-000000000001", "name": "Clear"},
  {"id": "6E0C0000-0000-4000-8000-000000000002", "name": "Finish", "isCollapsed": true}
],
"operations": [
  {"name": "Pocket plaque", "groupID": "6E0C0000-0000-4000-8000-000000000001", …},
  {"name": "V-carve title", "groupID": "6E0C0000-0000-4000-8000-000000000002", …},
  {"name": "Drill mounting holes", "hidden": true, …},
  {"name": "Cut out sign", …}
]
```

- **Members stay together.** Loading a project pulls each group's members together at its first member's place, keeping their order, clears a `groupID` that names no group, drops groups with no members and lists the groups in run order. So a member written in the wrong place moves: put members next to each other yourself, and check the order `post` prints.
- **No group switch.** A group has no `enabled` of its own: the app's group checkbox sets each member's `enabled`. To leave a group out, set `"enabled": false` on each member.
- **`isCollapsed`** folds the group in the sidebar. Display only.
- **No format change.** `toolpathGroups`, `groupID`, `hidden` and `isCollapsed` change no cut, so they don't raise `formatVersion`, and an older build that drops them cuts the same.
- **Optimize Run Order** reorders only inside each group and inside each stretch of ungrouped toolpaths between groups, and keeps the groups in order. A dependency the wrong way across groups (work inside a part in a group after the part's cut-out, a finish before its roughing, a rest pass before its reference) is a warning that says which group to move.
- **Templates** keep their toolpaths' groups, under the template's own `toolpathGroups`, and applying one makes them again with new ids.
- **Exporting a group:** `nativecam-cli post --group name` (see [Command line](cli.md#part-of-the-job-a-group-or-chosen-toolpaths)).

See `Tests/CAMCoreTests/Fixtures/projects/toolpath-groups-v1.nativecam` and [`Fixtures/toolpath-groups/`](../../Tests/CAMCoreTests/Fixtures/toolpath-groups/).

## Layers

A layer is just the `layer` string on each shape. The app lists the shapes' layers in the order they first appear, then the names in the top-level `layers` list. Imports name layers after the file's own: DXF layers, Inkscape layers or the named groups under an SVG's root, and PDF and Illustrator layers.

## operations

Each operation is one toolpath. They run in array order.

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | UUID |
| `name` | yes | Shown in messages and the G-code comments |
| `enabled` | yes | `false` leaves it out of the G-code, the estimate and the simulation (for a second setup, such as an inlay's plug) |
| `kind` | yes | `{"<kind>": {"_0": {…params…}}}`: see [Toolpath kinds](#toolpath-kinds) |
| `shapeIDs` | yes | The shapes it cuts. **`post` cuts exactly these.** An ID that matches no shape is skipped, and the toolpath warns `No shapes selected.` when none is left |
| `tool` | yes | A full copy of the bit: [tool](#tool) |
| `indexAngles` | no | Rotary jobs on faces: the angles to cut the same shapes at, in order, such as `[0, 90, 180, 270]` |
| `vectorSelection` | no | How the app and `template apply` find its shapes again: [below](#how-a-toolpath-finds-its-shapes) |
| `adjustFeedsForLoad` | no | Profiles and pockets: slow the feed where the bit cuts more (off; see [Feeds that follow the load](../using-nativecam.md#feeds-that-follow-the-load)) |
| `spindleSpeed` | no | `tool` (the tool's RPM, the default) or `automatic` |
| `groupID` | no | The toolpath group it's in (a `toolpathGroups` id); absent = ungrouped. See [below](#toolpath-groups-and-hiding) |
| `hidden` | no | `true` hides it in the app's 3D view. Display only: it's still generated, simulated, checked and exported |

## tool

Every toolpath carries its own copy of its bit, so the project posts the same whatever happens to the app's tool library. Copy one from a demo file rather than writing it.

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | UUID; the starter library's tools have fixed IDs (`4E415449-5645-4341-4D00-00000000000n`) |
| `number` | yes | The T number written in the G-code. **Two different bits must not share a number**: `post` refuses the job |
| `name` | yes | Shown in messages and the G-code |
| `shape` | yes | `flatEndMill`, `ballNose`, `bullNose`, `vBit`, `engraving`, `surfacing`, `drill`, `taperedBallNose`, `form`, `dovetail` |
| `fluteDirection` | yes | `upcut`, `downcut`, `compression`, `straight` |
| `fluteCount` | yes | Flutes, for chip loads |
| `diameter` | yes | Cutting diameter (the widest, for tapered bits) |
| `shankDiameter`, `fluteLength`, `stickout` | yes | Stickout is the length out of the collet, for reach checks |
| `cornerRadius` | yes | Bull nose corner radius (0 otherwise) |
| `includedAngle` | yes | V-bit, engraving and drill-point angle, degrees (90 when unused) |
| `tipDiameter` | yes | A V-bit's or engraving bit's flat tip (0 for a point) |
| `cutting` | yes | `{"spindleRPM", "feedRate", "plungeRate", "stepdown", "stepoverFraction"}` |
| `notes` | yes | Free text |
| `upcutLength` | no | Compression bits: the upcut section's length |
| `form` | no | Form bits: the cutting profile; see `ToolProfile.swift` and `Fixtures/router-bit-feeds/form-bit-library.json` |

## Toolpath kinds

Each kind's parameters go in `kind.<name>._0`. **Required** keys must be present. Optional keys take the default shown when they're absent. Lengths are mm.

Shared parts:

- **`depth`** (profile, pocket): `startDepth` and `cutDepth` required; `passDepth` optional (the tool's `stepdown`); `fromBottom` optional. With `fromBottom`, the cut stops that far above the material's bottom (a negative value goes through, that far into the spoilboard), and `cutDepth` is kept fitted to the thickness when the thickness changes. Set both, as `{"cutDepth": 18.5, "startDepth": 0, "fromBottom": -0.5}` on 18 mm material.
- **`tabs`**: `enabled`, `count` (per closed loop), `width` (along the cut) and `thickness` (left standing), all required. Optional: `shape` (`rectangular`, the default, or `triangular`: ramped over, with a flat top one bit diameter long; flat-bottomed bits only, others cut rectangular) and `placed`, a list of marks (below) that replaces `count`: exactly those tabs, evenly spaced ones not cut at all, and an empty list is no tabs. Either one is format 29.
- **A mark** (`ContourMark`, for `tabs.placed` and a profile's `startPoints`): `{"shapeID": "…", "point": {"x": …, "y": …}}`, the point on or near the shape's drawn outline in the shape's own coordinates (before its `position`, `rotation` and `scale`), mm. It's matched to the outline within max(1 mm, the bit's radius); one further off is kept but left off the cut, with a warning. To place one in the middle of a drawn rectangle's bottom edge, `point` is `{"x": 0, "y": -height/2}`.
- **`entry`**: `kind` (`plunge` or `ramp`) and `rampLength`, both required.
- **`leads`** (optional): `kind` (`arc` or `line`), `radius`, `sweep`, `length`, `angle`, `leadOut` and `overlap`, all required when `leads` is present (defaults in the app: arc, 6.35, 90°, 6.35, 45°, true, 0).
- **`cornerRelief`** (optional): `style` (`dogbone` or `tBone`), `tBoneSide` (`longer`, `shorter`, `alongX`, `alongY`) and `maxCornerAngle` (120) required; `overrides` and `avoidsOtherParts` (true) optional.
- **`direction`** (`CutDirection`): `climb` or `conventional`, assuming a clockwise (M3) spindle.
- **`cutDirection`** (`PassDirection`, optional): `climb`, `conventional` or `both`, on the toolpaths whose passes run in rows or patterns. Leave it out for the toolpath's own default; a value other than the default is format 27.
- **`boundary`** (3D): `model` (inside the model's outline), `vectors` (inside the other closed shapes in `shapeIDs`, plus `boundaryMargin`), or `material`.
- **`holdsTabs`** (on a `rough3D` or `finish3D` operation, beside `kind`): written as `true` when the toolpath leaves strips under the tabs of the tabbed outside profile that cuts its model out (`boundary` `vectors`, the model as deep as the board), which makes the file format 30. It's worked out from the job each time the file is saved and ignored on reading: don't write it by hand, and setting it changes nothing. The tabs are the profile's `tabs`; evenly spaced ones on such a cut-out are spaced from each outline's first point. See [3D toolpaths and tabbed cut-outs](../using-nativecam.md#3d-toolpaths-and-tabbed-cut-outs).

### profile

Cuts along closed or open vectors. `side` (`outside`, `inside`, `on`), `direction`, `depth`, `allowance` (material left on the wall), `tabs` and `entry` are required. `leads`, `cornerRelief`, `finishPass` and `startPoints` are optional. `startPoints` is a list of marks, at most one per drawn loop, where those loops start (the lead still has to fit there; when it doesn't, the entry moves along the loop and `post` notes how far); format 29. Inside and outside cuts only.

`finishPass` (format 28) adds a separate finishing lap per loop: the roughing stops `allowance` (mm) further off the wall, then the finish cuts it, at `depth` `fullDepth` (one lap at the cut depth) or `eachPass` (one at each roughing depth), in its own `direction` (the app's default is `conventional`), at `feedPercent` of the bit's feed (1 = 100%, 0.25–1.5), with an optional `springPass`. All five keys are required inside it: `{"allowance": 0.508, "depth": "fullDepth", "direction": "conventional", "feedPercent": 1, "springPass": false}`. Leave it out for none. `post` refuses the job (an `[error]` starting "Refused:", exit 1, nothing written) when the finish allowance is over half the bit's width, a full-depth finish is deeper than the flutes, or a loop's roughing offset doesn't fit where its finish does; fix the project rather than forcing it. It only applies to `inside` and `outside` profiles, and is skipped on tiled jobs. See `Fixtures/projects/finishing-pass-v28.nativecam` and `Fixtures/finishing-pass/`.

### pocket

Clears the inside of closed vectors, with shapes inside shapes as islands. Required: `strategy` (`offset`, `raster`, `adaptive`), `direction`, `depth`, `allowance`, `rasterAngle` and `entry`. Optional:

| Key | Default | Meaning |
|---|---|---|
| `stepoverFraction` | the tool's | |
| `cornerRelief` | none | |
| `clearanceTool` | none | A larger end mill (a full [tool](#tool)) that clears first; this toolpath's tool then cuts what it couldn't reach |
| `adaptive` | `{"optimalLoad": 0.12}` | Adaptive only: `optimalLoad` (0.03–0.5 of the diameter) required; `minimumLoopRadius` optional (automatic) |
| `restFromEarlier` | false | Rest machining: cut only what earlier pocket toolpaths with larger bits left |

An adaptive pocket's pass depth defaults to the bit's flute length.

### drill

Plunges at the centre of each shape (circles, usually). `depth`, `peckDepth` (0 = one plunge), `fullRetract` and `dwell` (s) are required. `fromBottom` is optional, as in `depth`.

`helix` is optional: without it every hole is plunged at the bit's size (Method ▸ Plunge). With it (Method ▸ Helical bore, format 31), each round hole larger than 1.05 × the bit is bored to its drawn size on a helix, and the rest are plunged with `peckDepth`, `fullRetract` and `dwell`. See [Helical boring](../using-nativecam.md#helical-boring).

| Key | Default | Meaning |
|---|---|---|
| `rampAngle` | 2 | The helix's ramp, degrees, held to 0.5–5. The drop per turn is also never more than the bit's stepdown |
| `direction` | `climb` | `climb` (counter-clockwise, G3) or `conventional` (clockwise, G2) |
| `finishAllowance` | 0 | mm left on the wall for one finishing lap at full depth; 0 = no lap |
| `finishFeedPercent` | 1 | The finishing lap's feed as a share of the bit's feed (0.25–1.5) |

All four keys are required inside `helix`; `{"rampAngle": 2, "direction": "climb", "finishAllowance": 0, "finishFeedPercent": 1}` is the default bore. Rotary jobs refuse it.

### vcarve

V-carves inside closed vectors. Only `sampleSpacing` (0.25) is required.

| Key | Default | Meaning |
|---|---|---|
| `flatDepth` | none (a full V wherever the shape allows) | The deepest cut below `startDepth`; flat areas below it are cleared |
| `passDepth` | none (one pass) | |
| `clearanceTool` | none (the V-bit clears flats itself) | An end mill that clears the flats first |
| `startDepth` | 0 | Carve as if the top were this much lower (format 6 above 0) |
| `flatRaster` | none (rings) | The V-bit clears flats in raster lines: `{"angle": 0, "stepover": …}` (`angle` required) |
| `inlay` | none | One side of an inlay pair; see below |
| `cutDirection` | `climb` (`both` with raster flats) | |

`inlay` holds `role` (`pocket` or `plug`), `pocketDepth` (P), `glueGap` (G), `surfaceClearance` (C), `boundary` (`margin`, `vector`, `board`) and `boundaryMargin`, all required. `boardSize` (`{"x", "y"}`) is optional, for a `board` boundary. The app's defaults are 5.08, 0.508, 1.5875, `margin` and 6.35. Both sides use the same V-bit and the same shapes; the pocket's `flatDepth` is P. See [Workflows](workflows.md#3-an-inlay-pair).

### rough3D

Clears the stock above a 3D model in layers. `shapeIDs` holds the model (and, for a `vectors` boundary, the closed outline). `allowance` and `boundary` are required. Optional: `passDepth` (the tool's stepdown), `stepoverFraction` (the tool's), `boundaryMargin` (tool diameter + 1), `clearing` (`offset`, the default; `raster`; `adaptive`, format 26), `rasterAngle` (0), `adaptive` (as for pockets), `clearingDepth` (adaptive: automatic, twice the diameter within the flute length) and `cutDirection`.

### finish3D

Follows the model's surface. `stepoverFraction`, `rasterAngle`, `allowance` and `boundary` are required.

| Key | Default when absent | Meaning |
|---|---|---|
| `strategy` | `raster` | `raster`, `waterline`, `steepShallow`, `pencil`, `rest`, `constantScallop`, `spiral`, `radial` |
| `smoothLinks` | **false** | Arc links between rows. The app turns it on for new toolpaths; write `true` |
| `crossHatch` | false | A second raster at +90° |
| `boundaryMargin` | tool radius + 0.5 | |
| `steepAngle`, `overlap` | 40°, a quarter of the diameter | Steep and shallow |
| `rest` | defaults | `rest` strategy: `{"tolerance": 0.05, "margin": 0.5, "pencil": false}` (all three required when present), and `references` (the earlier finishing toolpaths' IDs; absent = every earlier, enabled 3D finish on the same model with a larger bit) |
| `scallopHeight` | none | Constant scallop and spiral: spacing from a scallop height |
| `centre` | the boundary's centroid | Spiral and radial |
| `spiralHoldsScallop` | false | |
| `radialStep`, `radialMinSpacing` | automatic | Radial |
| `cutDirection` | the strategy's own | |

### rounding (rotary)

Turns the blank round. It needs no shapes (`shapeIDs` can be `[]`). `method` (`radial`, Around, or `raster`, Along) is required. Optional: `finishedDiameter` (the wrap diameter or the blank's), `passDepth`, `stepoverFraction`, `startX` and `endX` (just inside each end), and `cutDirection` (`both`).

### rotaryRough and rotaryFinish (rotary)

Rough and finish a model laid along the rotary axis, all the way round. `rotaryRough` requires `pattern` (`auto`, `around`, `along`, `offset`), `allowance` (0.508 in the app) and `sampleSpacing` (0.5). `stepdown`, `stepoverFraction`, `startX`, `endX` and `cutDirection` are optional. `rotaryFinish` requires `pattern` (`spiral`, `rings`, `lines`), `stepoverFraction`, `allowance` and `sampleSpacing` (0.25). `startX`, `endX`, `angleStep`, `passDepth`, `layerStepoverFraction` (0.4) and `cutDirection` are optional. See [`examples/Demo Pawn.nativecam`](../../examples/) and `Demo Table Leg.nativecam`.

### chamfer

A V-bit (or form bit) bevel along closed vectors. Required: `side` (`outside`, `inside`, `both`), `edge` (`top` or `bottom`), `width` (3.175 in the app), `startDepth`, `sharpCorners` and `direction`. `passDepth` and `overcut` (format 19) are optional.

### fluting

Grooves along vectors that ramp in and out. Required: `startDepth`, `depth` (3.175), `ramp` (`both`, `start`, `end`, `none`), `rampLength` (25.4) and `rampShape` (`linear`, `smooth`). Optional: `rampPercent`, `passDepth`, `surfaceModelID` (follow a 3D model's surface, format 25) and `cutDirection`. Use a ball nose, bull nose, V-bit, engraving bit or tapered ball nose.

### prism

A raised bevel to a ridge along the middle of a shape, with a V-bit. `startDepth` and `direction` are required; `depth` (a full prism) and `passDepth` are optional.

### edgeProfile

A form bit's profile along the top edge of parts (format 18). Required: `edges` (`outside`, `holes`, `both`), `offset` (0), `passes` (`horizontal`, `vertical`), `passCount` (3), `finish` (0.508), `direction` and `entry` (the app uses a ramp of 50.8). Optional: `depth` (the bit's profile height), `bandWidth`, `passDepth` and `leads`. Leave `leads` out for none; the app adds default leads to new ones.

### moulding

A profile vector swept along rail vectors into a 3D surface (format 22). `shapeIDs` holds the profile and the rails. Required: `profileID` (the profile's shape ID), `side` (`left` or `right` of the rail), `flipped`, `mirrored` and `finish` (a [finish3D](#finish3d) object). `roughing` is optional: `{"tool": {…}, "allowance": …}`, with `passDepth`, `stepoverFraction` and `cutDirection` optional. See `Fixtures/projects/moulding-v22.nativecam`.

## How a toolpath finds its shapes

`vectorSelection` records a rule, so the app's **Recalculate All**, `nativecam-cli template apply`, `import`, `rebind` and `post --rebind` can find a toolpath's shapes again in another design:

```json
"vectorSelection": {"layers": ["Cut Out"]}
"vectorSelection": {"kind": "circles"}
"vectorSelection": {"kind": "circles", "size": {"diameter": {"min": 7.9, "max": 8.1}, "tolerance": 0.05}}
"vectorSelection": {"selection": true}
```

`kind` is `text`, `circles`, `models`, `open`, `closed` or `all`. `size` (format 20) takes `diameter` (circles only), `width` and `height` as `{"min", "max"}` ranges, plus a required `tolerance`. Layer names match without regard to letter case or surrounding spaces. `{"selection": true}` means "the shapes selected when it's applied", which the CLI never has.

**`post` doesn't run the rule.** It cuts `shapeIDs` as they are. After adding shapes to a layer by hand, put their IDs in `shapeIDs` yourself, or apply a template.

## A minimal project

A 100 × 80 mm rounded rectangle cut out of 12 mm plywood, in millimetres. It posts with one info line and exit 0:

```json
{
  "formatVersion": 1,
  "name": "Minimal",
  "displayUnits": "mm",
  "notes": "",
  "stock": {
    "width": 200, "height": 150, "thickness": 12,
    "materialName": "Plywood", "materialKind": "plywood",
    "xyOrigin": "lowerLeft", "zZero": "materialTop",
    "clearanceHeight": 12.7, "plungeHeight": 2.54,
    "homePosition": {"x": 0, "y": 0, "z": 25.4}
  },
  "machine": {
    "model": "pro6060", "travel": {"x": 1558.925, "y": 1558.925, "z": 203.2},
    "spindle": "vfdSpindle", "minRPM": 6000, "maxRPM": 24000, "toolChange": "manualM6",
    "dustCollection": true, "spindleSpinUpDwell": 0,
    "rapidRateForEstimates": 20320, "maxFeedRate": 10160,
    "outputUnits": "mm", "outputArcs": true, "arcFitTolerance": 0.01, "lineNumbers": false
  },
  "shapes": [
    {
      "id": "00000000-0000-4000-8000-000000000001", "name": "Square", "layer": "Default",
      "kind": {"rectangle": {"width": 100, "height": 80, "cornerRadius": 5}},
      "position": {"x": 100, "y": 75}, "rotation": 0, "scale": 1
    }
  ],
  "operations": [
    {
      "id": "00000000-0000-4000-8000-000000000101", "name": "Cut out", "enabled": true,
      "shapeIDs": ["00000000-0000-4000-8000-000000000001"],
      "kind": {"profile": {"_0": {
        "side": "outside", "direction": "climb", "allowance": 0,
        "depth": {"startDepth": 0, "cutDepth": 12.5, "fromBottom": -0.5},
        "tabs": {"enabled": true, "count": 4, "width": 9.525, "thickness": 3.175},
        "entry": {"kind": "ramp", "rampLength": 25.4}
      }}},
      "tool": {
        "id": "4E415449-5645-4341-4D00-000000000001", "number": 1, "name": "1/4\" Upcut End Mill",
        "shape": "flatEndMill", "fluteDirection": "upcut", "fluteCount": 2,
        "diameter": 6.35, "shankDiameter": 6.35, "fluteLength": 25.4, "stickout": 38.1,
        "cornerRadius": 0, "includedAngle": 90, "tipDiameter": 0, "notes": "",
        "cutting": {"spindleRPM": 13000, "feedRate": 5588, "plungeRate": 1270, "stepdown": 4.7625, "stepoverFraction": 0.4}
      }
    }
  ]
}
```

```text
$ nativecam-cli post minimal.nativecam -o minimal.tap
[info] Cut out: Cuts through the material (0.500 mm into the spoilboard).
Generated 1 toolpaths in 0.00s, 76 lines -> minimal.tap
Estimated run time: 0:00:16 (cutting 0:00:15, rapids 0:00:01, tool changes/pauses 0:00:00; distance/feed alone: 0:00:14)
  Cut out: 0:00:15
```

The [workflows](workflows.md) build bigger projects the same way, from `new` and the demos' tools.

## When a project won't load

`Can't read project …: The data couldn’t be read because it is missing.` means a required key is missing. `…isn’t in the correct format.` means a wrong type or an unknown enum value. Neither names the key. To find it:

1. Compare your file's keys with a file the CLI wrote, object by object (`new`, a demo, a fixture with the same toolpath kind).
2. Check enum spellings against the tables on this page. They're case-sensitive (`flatEndMill`, not `FlatEndMill`).
3. Check every associated-value enum has its `"_0"` level: `{"pocket": {"_0": {…}}}`, not `{"pocket": {…}}`.
4. Bisect: remove toolpaths or shapes until it loads.

## Toolpath templates

A `.nativecamtemplate` is JSON too: `type` (always `"NativeCAM toolpath template"`), `formatVersion` (the same numbering, and refused above the current one), `name`, `toolpaths` (operations with empty `shapeIDs` and a `vectorSelection`), and optionally `jobSetup` (material thickness, name and kind, origin, Z zero, clearance, plunge and park heights, retract settings, and the machine's name) and `toolpathGroups` (the groups its toolpaths are in). Make them with `nativecam-cli template save`, and see [`Fixtures/templates/`](../../Tests/CAMCoreTests/Fixtures/templates/) for examples.
