# Machines and posts

[← Back to AGENTS.md](../../AGENTS.md)

What an agent needs to know to pick a controller and set up a machine in a project. The pages for people, [Machines](../machines.md) and [Controllers and G-code](../controllers.md), say more about each one. The code is in [`Machine.swift`](../../Sources/CAMCore/Model/Machine.swift), [`Controller.swift`](../../Sources/CAMCore/Model/Controller.swift), [`Dialect.swift`](../../Sources/CAMCore/Post/Dialect.swift) and [`PostProcessor.swift`](../../Sources/CAMCore/Post/PostProcessor.swift).

- [The default: Avid PRO6060 on Mach4](#the-default-avid-pro6060-on-mach4)
- [Controllers and their posts](#controllers-and-their-posts)
- [Choosing a controller](#choosing-a-controller)
- [Units](#units)
- [Tool-change modes](#tool-change-modes)
- [Motion settings and estimates](#motion-settings-and-estimates)
- [The rotary axis](#the-rotary-axis)
- [The machine catalogue and library](#the-machine-catalogue-and-library)

## The default: Avid PRO6060 on Mach4

`nativecam-cli new` and every demo use `MachineProfile.avidPRO6060`. It's the one setup whose output has been run on a real machine:

| Setting | Value |
|---|---|
| Model | `pro6060`: 61.375 × 61.375 × 8 in of travel (1558.925 × 1558.925 × 203.2 mm), from Avid's published specs |
| Controller | none in the file, which means Avid's Mach4 profile (`.tap`, CRLF) |
| Spindle | `vfdSpindle`, 6000–24000 RPM (S word through the VFD) |
| Tool change | `manualM6`: `T#M6`, which Avid's M6 macro handles with the touch plate |
| Dust collection | on: `M07` after each tool change, `M09` at the end |
| G-code units | inches (`G20`) |
| Arcs | on, 0.01 mm fitting tolerance |
| Rapid for estimates | 800 in/min X/Y; Z rapid 400 in/min unless set |
| Max feed | 400 in/min (feeds above it are warned about) |
| Acceleration | 50 in/s² X/Y and 25 in/s² Z unless set: what Avid owners report Mach4 ships with, not measured |

The post follows Avid's own Vectric (v3) and Fusion 360 posts. Its header is `G00 G94 G20 G17 G90 G40 G49 G80`, then `G91.1` and `G64`. Tool changes retract, stop the spindle and call `T#M6`. The footer retracts, parks, then `M05 M09 M30`. See [Avid Mach4](../controllers.md#avid-mach4) for a sample.

## Controllers and their posts

Set `machine.controller.family` in the project. Leave `controller` out for Avid's Mach4 profile.

| `family` | Writes | File | Status |
|---|---|---|---|
| (none) | Avid Mach4 | `.tap`, CRLF | **Run on a real machine** |
| `grbl`, `grblHAL`, `fluidNC`, `carbideMotion` | Grbl 1.1 and relatives: strict parser, 79-character lines (126 on FluidNC), `M8` dust, no `G43` or canned cycles | `.nc`, LF | From documentation and firmware source |
| `linuxCNC` | `G64 P` blending, `T# M6` then `G43 H#`, strict checks | `.ngc` | From documentation |
| `masso` | `T# M06`, `G4 P` in milliseconds | `.nc` | From documentation |
| `centroid` | Centroid CNC12, as on Acorn, Oak and Avid EX: `T# M6` then `G43 H#` | `.cnc`, CRLF | From Avid's EX posts |
| `buildbotics` | `T# M6`, which pauses by default | `.nc` | From documentation |
| `openSBP` | ShopBot part files, not G-code | `.sbp` | From ShopBot's references and vendor posts |
| `richAuto` | Millimetres only, no comments, arcs as lines, one file per tool | `.nc` | Conservative: its handling is undocumented |
| `mach3`, `uccnc`, `planetCNC`, `winCNC` | **No post.** `post` and `acceptance` exit 1: `NativeCAM can't write G-code for … yet` | | Possible only with the human's own Vectric post (`customPost`) |

Every post's output is read back by the export checks against that controller's rules. Only Avid Mach4 output has been run on a machine. Treat the rest as unverified, and tell the human that the [acceptance test](../controllers.md#trying-a-new-controller-safely) and an air cut come first. The acceptance programs are in the goldens (`Fixtures/golden/acceptance-*.tap`).

## Choosing a controller

Choose from what the human tells you, never from a guess at what their machine "probably" runs:

1. **Ask which controller and which program sends the files.** Avid PRO machines run Mach4 or, on the newer EX controller, Centroid CNC12. Grbl machines (Shapeoko, X-Carve, LongMill and many more) need the sender too, since it decides whether `M6` can stop for a tool change.
2. **Set it in the project:**

   ```json
   "controller": {"family": "grbl", "sender": "gSender"},
   "model": "custom",
   "travel": {"x": 800, "y": 800, "z": 100}
   ```

   Set `model` to `custom` for anything but an Avid PRO, with the machine's own `travel`. The `pro4848`, `pro4896` and `pro6060` models only fill in Avid's travel; the controller is what decides the post.
3. **Take real limits from the controller's settings** when the human can give you the file (`$$`, `Machine.ini`, a LinuxCNC INI, FluidNC `config.yaml`, a Fusion `.mch`): `nativecam-cli machine <file> --apply job.nativecam -o job-machine.nativecam`. The values are recorded with their source in `provenance`.
4. **Write the acceptance test** for that controller (`nativecam-cli acceptance job-machine.nativecam`) for the human to run before any real job.

The app's setup assistant (**Settings ▸ Machine ▸ Set Up a Machine…**) and its catalogue of 37 routers do the same with a GUI. It has no CLI. A machine saved in the human's library lives in `~/Library/Application Support/NativeCAM/machines.json`. **Read it only if the human asks you to; never edit it.**

## Units

- **The file is always millimetres** (see [Project format](project-format.md#units)).
- **`machine.outputUnits`** (`inch` or `mm`) is what the G-code is written in. It must match what the controller runs in: the export check reports a file that switches units against the machine, or that a controller doesn't accept. RichAuto takes millimetres only.
- **`displayUnits`** is only what the app shows and what the CLI prints and takes for `nest`.
- CLI lengths for `post --air-cut` and `calibrate` are in the G-code's units.

## Tool-change modes

`machine.toolChange`:

| Mode | Writes | Use when |
|---|---|---|
| `manualM6` | `T#M6`, and on Avid's Mach4 profile its macro moves to the change position, prompts and re-zeroes with the touch plate | The controller has an M6 macro or pauses on M6 |
| `atc` | `T#M6`, then `G43 H#` where the controller needs it (LinuxCNC, Centroid) | A real automatic tool changer |
| `manualPause` | Stops the spindle and pauses with `M0` for the operator to change the bit and re-zero | Controllers or senders without an M6 that stops |

On Grbl-family controllers, `M6` is written only where something stops for it: Carbide Motion, an ATC, or gSender or CNCjs named as the `sender`. Otherwise **each tool gets its own file**, `post` says so as an `[info]`, and the files are named `… 1 of 2 - T5.nc`. Choosing `manualPause` keeps one file, for senders that handle `M0`. See [Grbl family](../controllers.md#grbl-family).

Each tool change counts `toolChangeSeconds` in the estimate: 60 s by default, 15 s with an ATC.

## Motion settings and estimates

These change the run-time estimate and the simulation's pace, not the G-code: `drive`, `accelerationXY`, `accelerationZ` (mm/s²), `rapidRateZ` (mm/min), `junctionDeviation` (mm), `lookaheadLines`, `toolChangeSeconds` and `roughingSmoothing` (how far roughing may round corners, 0.25 mm by default; this one does change roughing toolpaths). Each controller brings its own planner model: Mach4's 20-line look-ahead with rapids in exact stop, or Grbl's 16 blocks with a 0.01 mm junction deviation.

Real values come from the controller's settings (`machine`) or the timing suite (`calibrate timing`, then `calibrate fit --apply` on the human's measured times). Never type in values nobody measured. A value's source is in `provenance` (`vendor`, `controllerSettings`, `measured`, `estimated`, `user`).

## The rotary axis

A rotary job needs a rotary axis on the machine and a rotary blank in the stock (see [Project format](project-format.md#stock)). `machine.rotary`:

| Key | Required | Meaning |
|---|---|---|
| `letter` | yes | `A`, `B` or `C`. Avid's rotary is `A` either way it's mounted |
| `alignment` | yes | `x` (the axis runs along X: chuck on the left, the usual mounting) or `y` (along Y, Avid's front-mounted option) |
| `reversed` | yes | `true` when a positive move turns the other way from the right-hand rule about the axis. **It's measured by jogging the machine, never assumed.** Wrong, it mirrors anything wrapped round the blank |
| `centerHeight` | no | The chuck centre's height above the spoilboard, mm. Without it the Z-travel check can't run, and `post` says so |
| `manualIndexing` | no | `true` when the blank is turned by hand: each A move becomes an `M0` pause (format 4) |
| `turnSpeed` | no | Degrees per minute on a rapid turn; until set, estimates assume 90° a second and `post` warns where it slows the cut |

Setting a rotary axis makes the project format 2 at least, and rotary stock makes it 3.

**What each controller can do**, from [Known limits](../known-limits.md):

| | Indexed (faces at angles) | Wrapped (`G93` inverse time) | Along Y |
|---|---|---|---|
| Avid Mach4 | `G00 A` at safe Z | yes; Mach4's `G93` not yet tested on a machine | yes |
| LinuxCNC, grblHAL | yes | yes | yes |
| Centroid, Buildbotics | yes | no | by hand |
| Grbl, FluidNC, Carbide Motion, Masso | turned by hand only (`manualIndexing`, an `M0` per turn) | no | by hand |
| ShopBot, RichAuto | no | no | no |

Rounding needs a driven axis. 3D rotary roughing and finishing need a driven axis with `G93`, or a documented rotary feed rule.

**Rules for an agent on rotary jobs:**

- Don't set `reversed`, `centerHeight` or `turnSpeed` from a guess. Ask the human, or leave them unset and pass on `post`'s notes.
- **Which way Avid's rotary turns for +A hasn't been confirmed on a machine**, along X or along Y. Pass on `post`'s note to jog the axis positive before the first wrapped cut, word for word.
- On faces, the blank is cut at each angle in `indexAngles`, turning at safe Z. Make `clearanceHeight` clear a square bar's corners: at least (√2 − 1) × the radius plus the link safe distance.
- The rotary check (`calibrate rotary`) times the turn speed and `G93`. The human runs it, with no stock in the chuck.

## The machine catalogue and library

The app ships a catalogue of 37 routers from 20 makers ([`MachineCatalogueData.swift`](../../Sources/CAMCore/Model/MachineCatalogueData.swift)), each with its controllers, travel, spindle and speeds, every value with a source. The CLI has no command to list or pick from it. To use an entry headlessly, read its values from that file and write them into the project's `machine` by hand, keeping `model: "custom"` and the right `controller`. The machine is copied into each project, so a project posts the same G-code whatever happens to the catalogue or the human's library.

A Vectric post the human imported (`customPost`) writes the G-code in place of NativeCAM's post. Never write or share one yourself: Vectric posts aren't licensed for redistribution, and the repository never holds them.
