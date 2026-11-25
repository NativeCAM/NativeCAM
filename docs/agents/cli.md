# Command line for agents

[← Back to AGENTS.md](../../AGENTS.md)

`nativecam-cli` is the engine without the UI, in [`Sources/nativecam-cli/main.swift`](../../Sources/nativecam-cli/main.swift). This page lists every command with its arguments, defaults, outputs and exit status. The examples were run on the projects `demo` writes; output that changes from run to run (timestamps, how long generation took) will differ.

- [Building and running it](#building-and-running-it)
- [General behaviour](#general-behaviour)
- [demo, demo3d, demonest, demosheets, new](#demo-demo3d-demonest-demosheets-new)
- [post](#post)
- [sim](#sim)
- [acceptance](#acceptance)
- [calibrate timing, rotary, ladder](#calibrate-timing-rotary-ladder)
- [calibrate fit](#calibrate-fit)
- [machine](#machine)
- [tools](#tools)
- [template save](#template-save)
- [template apply](#template-apply)
- [nest](#nest)
- [What the CLI can't do](#what-the-cli-cant-do)

## Building and running it

```bash
swift build -c release --product nativecam-cli   # about a minute from clean; release matters, debug is far slower
.build/release/nativecam-cli post job.nativecam -o job.tap
```

`swift run -c release nativecam-cli …` works too, but it checks the build each time. In scripts, build once and call `.build/release/nativecam-cli`. The examples below write it as `nativecam-cli`.

## General behaviour

- **Exit status.** 0 on success. 1 when the command refuses or fails, with the reason on **stderr**: bad arguments, a file it can't read or write, a project from a newer format, `post` finding an error, a calibration program that can't be made. Issues and results go to **stdout**.
- **No arguments** prints a short usage line and exits 0. It lists only some commands; this page lists them all. An unknown command prints `unknown command <name>` and exits 1.
- **Options** are read by name from anywhere after the command (`-o out.tap` or `--air-cut 1`). An option given without its value is ignored, and so is an unknown option, so check spelling: `--airc-cut 1` cuts at full depth without a word.
- **Lengths on the command line** are in the units the command names: the G-code's units (`post --air-cut`, `calibrate`) or the project's display units (`nest`). Lengths inside project files are always millimetres (see [Project format](project-format.md#units)).
- **Issue lines** look like `[severity] <toolpath>: <message>` for the job's checks, and `[severity] G-code: <message>` for the export checks on the file. The severities are `info`, `warning` and `error`. See [Verifying output](verification.md#reading-posts-checks).
- **Reading a project** fails with `Can't read project <path>: <reason>` and exit 1. The reason comes from Swift's JSON decoder and doesn't name the field ("The data couldn’t be read because it is missing."), so compare your file's keys with a file the CLI wrote. See [Project format](project-format.md#when-a-project-wont-load).

## demo, demo3d, demonest, demosheets, new

```text
nativecam-cli demo|demo3d|demonest|demosheets|new <out.nativecam>
```

Writes a project, overwriting `<out.nativecam>` if it exists, prints `Wrote <out>` and exits 0. Without a path it prints the usage to stderr and exits 1.

| Command | Project |
|---|---|
| `demo` | The demo sign: 24 × 18 × 0.75 in Baltic birch, the text "AVID" V-carved, a plaque pocketed, four holes drilled and the sign cut out with tabs |
| `demo3d` | The 3D relief medallion: a mesh roughed (`rough3D`), finished with a ball nose (`finish3D`) and cut out |
| `demonest` | Shelf parts on the `Parts` layer, for [nesting](#nest) |
| `demosheets` | Shelf parts, frames and coasters: more than one sheet's worth, with parts that fit in other parts' holes |
| `new` | An empty project on the default machine (Avid PRO6060, Mach4, inches), with the default 24 × 18 × 0.75 in plywood |

They're the safe starting point for a project of your own: every required key is present and the tools are real ones from the starter library.

```text
$ nativecam-cli demo sign.nativecam
Wrote sign.nativecam
```

The rotary demos (the pawn and the table leg) aren't CLI commands. They're in [`examples/`](../../examples/) with the G-code they post.

## post

```text
nativecam-cli post <project.nativecam> [-o out.tap] [--air-cut height] [--sheet out.html] [--force]
```

With a `--restart-*` flag it writes a restart file instead: see [Restart files](#restart-files).

Generates the toolpaths, runs the job's checks, posts the file for the project's machine, reads the file back with the export checks (`GCodeCheck`: against the controller, the toolpaths and the machine), prints every issue and, unless there's an error, writes the file.

| Argument | Default | Meaning |
|---|---|---|
| `<project>` | required | The project to post |
| `-o out` | the project's path | Where to write. Only the stem is used: the extension is always the controller's (`.tap` for Avid Mach4, `.nc`, `.ngc`, `.cnc` or `.sbp`), so `-o job.gcode` writes `job.tap` on Mach4 |
| `--air-cut h` | off | Raises every Z, safe height and park height by `h`, in the G-code's units, with X and Y unchanged. The file is named `<stem> (air cut).<ext>`. `h` must be above zero, or it exits 1 |
| `--sheet out.html` | none | Also writes the printable setup sheet (see [Workflows](workflows.md#8-read-the-setup-sheet-and-run-time-estimate)). It's written before the error check, so it's written even when the G-code isn't |
| `--force` | off | Writes the file in spite of errors. **An agent never passes it** (see [AGENTS.md](../../AGENTS.md#hard-safety-rules)) |

**Files.** Usually one: `<stem>.<ext>`. More when the job needs them, named after the stem:

- One per tool when the controller can't stop for a tool change (Grbl without a sender that pauses, RichAuto, ShopBot without a tool changer): `<stem> 1 of 2 - T5.nc`, `<stem> 2 of 2 - T1.nc`
- One per sheet on a job nested onto several: `<stem> - sheet 1 of 2.tap`
- One per tile on a tiled job

**Stdout.** The job's issues, then the export checks' issues, then `Setup sheet -> <path>` when asked, then a summary line and the run-time estimate:

```text
Generated <n> toolpaths in <s>s, <lines> lines -> <file>[, <file>…]
Estimated run time: H:MM:SS (cutting …, rapids …, tool changes/pauses …; distance/feed alone: …)
  <toolpath name>: H:MM:SS
```

There's one line per toolpath. On an indexed rotary job, each angle is its own toolpath (`Mortise @ 90°`).

**Exit status.** 0 when the file was written. 1 when the project can't be read, the machine has no post (`NativeCAM can't write G-code for Mach3 yet…`), or the job's checks or the export checks found an **error**. It then writes no G-code and ends with:

```text
Not written: the job has 1 error. Fix the errors above, or pass --force to write it anyway.
```

Errors include a program larger than the machine's travel in X, Y or Z (`[error] G-code: The program moves 78.0541 in in X, retracts and park included, 16.6791 in more than the machine's 61.3750 in of X travel.`) and a 2.5D cut deeper than the bit's stickout. With `--force`, `post` prints the same errors, then `Writing it anyway (--force): …`, writes the file and exits 0; only the human may ask for that. Warnings and infos never stop it.

**Example.** The demo sign on the default machine:

```text
$ nativecam-cli post sign.nativecam -o sign.tap
[info] Drill mounting holes: Cuts through the material (0.0200 in into the spoilboard).
[info] Cut out sign: Cuts through the material (0.0200 in into the spoilboard).
Generated 4 toolpaths in 0.01s, 893 lines -> sign.tap
Estimated run time: 0:06:54 (cutting 0:05:30, rapids 0:00:24, tool changes/pauses 0:01:00; distance/feed alone: 0:06:26)
  V-carve title: 0:01:26
  Pocket plaque: 0:02:18
  Drill mounting holes: 0:00:19
  Cut out sign: 0:01:48
```

The same project with the machine set to Grbl in millimetres (`"controller": {"family": "grbl"}`, `"model": "custom"`, `"outputUnits": "mm"`), so each tool gets its own file:

```text
$ nativecam-cli post grbl.nativecam
[info] Drill mounting holes: Cuts through the material (0.0200 in into the spoilboard).
[info] Cut out sign: Cuts through the material (0.0200 in into the spoilboard).
[info] Grbl can't stop for a tool change here, so this job is saved as 2 files, one per tool. Change the bit and re-zero Z before running each. (If the program that sends your files pauses on M6, name it under Machine ▸ Sends files with.)
Generated 4 toolpaths in 0.01s, 896 lines -> grbl 1 of 2 - T5.nc, grbl 2 of 2 - T1.nc
…
```

An error, here two tools given the same number, refuses the file:

```text
$ nativecam-cli post relief.nativecam -o relief.tap
Not written: the job has 1 error. Fix the errors above, or pass --force to write it anyway.
[error] Rest finish: Uses T7 for 1/8" Ball Nose, but “Finish relief” just before it uses T7 for 1/4" Ball Nose. No tool change is written between them, so this would cut with the 1/4" Ball Nose. Give each bit its own tool number.
$ echo $?
1
```

The `Not written` line goes to stderr, so in a terminal it can show before the issues, which go to stdout.

A project with no toolpaths posts a short, valid program with `Generated 0 toolpaths` and exits 0, so check the count.


### Restart files

```text
nativecam-cli post <project.nativecam> --restart-toolpath n [--restart-pass p] [--restart-exact] [--restart-no-stop]
                   [--restart-file n] [--restart-from running.tap] [--air-cut height] [-o out.tap] [--force]
nativecam-cli post <project.nativecam> --restart-line N [same options]
```

Writes a restart: the rest of the job from part way through, for after a broken bit, a power cut or an E-stop. Any `--restart-*` flag switches `post` to this mode. See [Restarting a job partway through](../using-nativecam.md#restarting-a-job-partway-through) for what the file does.

| Argument | Default | Meaning |
|---|---|---|
| `--restart-toolpath n` | required without `--restart-line` | The toolpath, from 1, in the file's run order: its toolpaths that cut anything, as the Avid header's `Toolpaths:` list numbers them |
| `--restart-pass p` | the toolpath's start | Pass `p`, from 1. A pass begins where the tool lifts to the plunge height or above |
| `--restart-line N` | none | The cutting move on line `N` of the full file, from 1 as a text editor counts, or the next one after it. Replaces `--restart-toolpath` |
| `--restart-exact` | off | Restart at the move itself with a feed straight down at the plunge rate, rather than at the start of its pass. Refused when the feed down would cut material |
| `--restart-no-stop` | off | Leave out the stop (`M00`) over the restart point |
| `--restart-file n` | 1 | On a tiled, multi-sheet or split-per-tool job, which file was running, from 1 |
| `--restart-from file` | none | The file that was running. Its `Created` stamp goes in the header, and it's an **error** if this project no longer writes the same program |
| `--air-cut h` | off | An air cut of the restart |
| `--sheet` | | Not allowed with a restart. Post the full job for its setup sheet |

**File.** `<stem> (restart at toolpath n pass p)<the full file's suffix>.<ext>`, for example `sign (restart at toolpath 2 pass 2).tap`.

**Stdout.** The restart's header lines, indented, then the checks, then:

```text
Restart: <n> toolpaths, <lines> lines -> <file>
Estimated run time of the restart: H:MM:SS
```

**Exit status.** 1 with `Restart refused: …` for:

- a point past the end;
- a calibration program;
- a rotary job on an imported Vectric post;
- an exact plunge into material;
- an approach the simulation shows rapiding through material.

`--force` doesn't override a refusal. 1 with `Not written: …` when the restart's own checks or the export checks find an error, as for a normal `post`. A spin-up dwell of 0 s is a warning. The file's first spin-up keeps the machine's setting; the stop above the restart point dwells at least 3 s whatever it is.

**An agent may write a restart file. Running it is the human's,** as for every file (see [AGENTS.md](../../AGENTS.md#hard-safety-rules)). Hand it over with its header, every warning, and the line the human said the controller showed. Never guess the line or the pass: ask the human where the job stopped.

## sim

```text
nativecam-cli sim <project.nativecam | file.tap|.nc|.gcode|.ngc|.cnc|.txt|.sbp> [--png out.png] [--cell mm] [--heights out.bin] [--no-arcs]
```

Simulates material removal on a heightmap and prints what it found.

| Argument | Default | Meaning |
|---|---|---|
| `<input>` | required | A project, or a G-code or ShopBot file from any program. The extension decides which: anything other than those listed is read as a project |
| `--png out.png` | none | Writes the heightmap as a PNG. On a wrapped rotary job it's the blank unrolled |
| `--cell mm` | automatic | The grid's cell size in millimetres. Smaller is finer and slower |
| `--heights out.bin` | none | Writes the heightmap as little-endian binary: Int32 columns, Int32 rows, Float64 cell size, Float64 origin x, Float64 origin y, then columns × rows Float32 heights (mm, Z = 0 at the material top) |
| `--no-arcs` | off | Projects only: posts without arc fitting (`outputArcs` off) before simulating |

**A project** is generated as `post` would generate it, and played at its run-time estimate's pace. **A G-code file** is read with the default project's settings: the 24 × 18 × 0.75 in sheet, the Avid Mach4 dialect, and the starter library's tools by number (an unknown number gets T1). A job on other material is simulated on the wrong block. Its job time is the simulator's own timing of the moves, without the estimate's planner model. Tapping and boring cycles are read as Avid Mach4 runs them. Words it can't read come out as `[warning]` lines.

**Stdout**, on a flat job:

```text
$ nativecam-cli sim sign.nativecam --png sign.png --heights sign.bin
Simulated 850 steps on a 1826x1370 grid (0.33 mm cells) in 0.02s
Removed 410.7 cm³ of material; job time 0:06:54
Wrote sign.bin
Wrote sign.png
```

On a rotary job, each face is reported on its own (their removals overlap, so they aren't added up):

```text
$ nativecam-cli sim indexed.nativecam
Simulated 136 steps on a 1524x254 grid (0.20 mm cells) in 0.00s
Rotary blank, job time 0:00:37:
  Face at 0°: removed 4.8 cm³ below the face
  Face at 90°: removed 4.8 cm³ below the face
  Face at 180°: removed 4.8 cm³ below the face
  Face at 270°: removed 4.8 cm³ below the face
$ nativecam-cli sim wrapped.nativecam
Simulated 591 steps on a 1271x798 grid (0.20 mm cells) in 0.88s
Rotary blank, job time 0:00:25:
  Wrapped toolpaths: removed 2.0 cm³ all the way round (heights and PNG show the sheet unrolled)
```

When a rapid move cuts material it adds `[error] <n> rapid move(s) cut through material`, but **the exit status stays 0**. Search stdout for `[error]`. A file it can't read exits 1 (`Can't read <path>`, or `G-code error: …`). The 3D rotary demos take tens of seconds.

## acceptance

```text
nativecam-cli acceptance [machine.nativecam] [--controller family] [--sender name] [--units inch|mm] [--tool-change m6|pause|atc] [-o stem]
```

Writes the acceptance test program for a controller: a square, circles from 1 to 50 mm radius in all four quadrants, a helix, a 3-second dwell and two tool changes, in scrap 0.5 mm deep. **The human runs it,** in check mode where the controller has one, then as an air cut, then in scrap. See [Trying a new controller safely](../controllers.md#trying-a-new-controller-safely).

| Argument | Default | Meaning |
|---|---|---|
| `machine.nativecam` | the default machine (Avid PRO6060, Mach4, inches) | Use this project's machine. Only the machine is read |
| `--controller f` | the machine's | `mach4`, `grbl`, `grblHAL`, `fluidNC`, `carbideMotion`, `linuxCNC`, `masso`, `centroid`, `buildbotics`, `openSBP`, `richAuto` (and `mach3`, `uccnc`, `planetCNC`, `winCNC`, which have no post, so it exits 1). It also sets the machine model to Custom |
| `--sender s` | none | The program that sends files to a Grbl-family controller, such as `gSender`. It decides whether `M6` can stop for a tool change |
| `--units u` | the machine's | `mm`; **any other value means inches** |
| `--tool-change t` | the machine's | `m6`, `pause` (M0) or `atc`; other values are ignored |
| `-o stem` | `acceptance-<dialect id>` | The output stem; the extension is the controller's |

It prints the export checks' issues and `<post name> acceptance test -> <file>` for each file. A post that writes one file per tool writes three: `acceptance-grbl 1 of 3 - T1.nc`, `… 2 of 3 - T2.nc` and `… 3 of 3 - T1.nc`. It exits 1 only when the controller has no post. Check-error lines don't change the exit status, so read them.

```text
$ nativecam-cli acceptance
Avid CNC Mach4 acceptance test -> acceptance-avid-mach4.tap
$ nativecam-cli acceptance --controller grbl --sender gSender --units mm -o grbl-test
[warning] G-code: Line 14: Whether M6 stops for the tool change depends on the program sending the file. Make sure yours pauses on M6. (2 more lines like this.)
Grbl via gSender acceptance test -> grbl-test.nc
```

## calibrate timing, rotary, ladder

```text
nativecam-cli calibrate timing|rotary|ladder [project.nativecam] [--controller c] [--sender s] [--units inch|mm] [-o stem]
    timing: [--window WxH] [--air height]
    ladder: [--tool n] [--material kind] [--depth d] [--rungs n] [--step-rpm]
```

Writes a calibration program for the project's machine, or for the default Avid PRO6060 on Mach4 without a project. **The human runs it on the machine and times it.** The project is the first argument ending in `.nativecam`. `--controller`, `--sender` and `--units` work as for [`acceptance`](#acceptance). Lengths are in the G-code's units.

| Program | What it does | Files |
|---|---|---|
| `timing` | The timing suite: lines, squares, arcs, segments, a zig-zag, rapids, a helix and an F-change line, each run for about 40 s in the air. `--window WxH` is the area it moves over (24x24 in or 600x600 mm by default; bigger than the travel is refused). `--air h` is the height above the material (1 in or 25 mm, never below 25 mm) | `stem.<ext>`, the recording sheet `stem.html`, the times file `stem-times.csv` |
| `rotary` | The rotary check: a turn in inverse time (`G93`) and rapid turns of 360° and 720° | as for `timing` |
| `ladder` | A chip-load ladder: rungs cut at rising feeds, for judging the chip by ear and eye. `--tool n` comes from the project's toolpaths or the starter library (T1 by default). `--material` is `plywood`, `hardwood`, `softwood`, `mdf`, `laminatedParticle`, `softPlastic` or `hardPlastic` (the project's, or `hardwood`). It also takes `--depth d`, `--rungs n` (7) and `--step-rpm` | `stem.<ext>` and `stem.html` (no times file) |

The stem defaults to `calibration-timing`, `calibration-rotary` and `calibration-ladder`. A program that can't be made, or that fails its own checks, is refused with `Not written: <reason>` and exit 1.

```text
$ nativecam-cli calibrate timing
Avid Mach4 timing suite -> calibration-timing.tap
Recording sheet -> calibration-timing.html
Times file -> calibration-timing-times.csv
  line-1  Line at 100 in/min: 2x, about 57.7 s
  …
  fchange-alternating  F-change line, two feeds: 3x, about 51.0 s
Moves take about 0:17:13, plus the stops
$ nativecam-cli calibrate ladder --material plywood --rungs 5
Avid Mach4 chip-load ladder -> calibration-ladder.tap
Recording sheet -> calibration-ladder.html
  Rung 1: 93.6 in/min at 13000 RPM, 0.0036 in/tooth, below the chart
  …
  Rung 5: 327.6 in/min at 13000 RPM, 0.0126 in/tooth, above the chart
Moves take about 0:00:16
$ nativecam-cli calibrate timing --window 100x100
Not written: The 100 × 100 in window is bigger than the machine's 61.375 × 61.375 in of travel. Make it smaller in Calibration Programs (or with --window).
```

The times file is CSV. `#` lines are comments, then `program`, `controller`, `units` and the program's settings, then a `section,count,name,estimate_s,measured_s` table. The human fills in `measured_s`.

## calibrate fit

```text
nativecam-cli calibrate fit <times.csv> [more-times.csv …] [project.nativecam] [--apply] [-o out.nativecam]
```

Fits the machine's X/Y acceleration, Z acceleration, Z rapid rate, corner tolerance and (from the rotary check) turn speed to the measured times. It prints each value before and after, each section's error before and after, and the F-change and `G93` verdicts. Without a project it fits the default Avid PRO6060.

- A times file with no `measured_s` filled in is refused: `Not fitted: No times have been entered yet.`, exit 1.
- Without `--apply` it changes nothing and says `Nothing changed: add --apply to write these values into the project's machine.`
- `--apply` writes the fitted values, each marked `measured` in the machine's `provenance`, into the project **in place** unless `-o` names another file. It needs a project.

**An agent never fills in `measured_s` and never applies a fit of times nobody measured** (see [AGENTS.md](../../AGENTS.md#hard-safety-rules)). Only a times file the human returned after timing the program on the machine may be fitted, and even then pass `-o`:

```text
$ nativecam-cli calibrate fit calibration-timing-times.csv shop.nativecam --apply -o shop-fitted.nativecam
Fitted Timing suite times for PRO6060 (5 × 5 ft), Avid Mach4:
  X/Y acceleration: 50.0 in/s² -> …
  …
Applied x/y acceleration, z acceleration, z rapid rate, corner tolerance (junction deviation) to shop-fitted.nativecam
```

## machine

```text
nativecam-cli machine <settings file> [--apply project.nativecam [-o out.nativecam]]
```

Reads machine limits from a controller's own settings and prints each value with where it came from. The file can be a Grbl or grblHAL `$$` dump, Mach4's `Machine.ini`, a LinuxCNC INI, a FluidNC `config.yaml` or a Fusion 360 `.mch`. The format is worked out from the contents. `--apply` writes every value it found (and the controller family, which also sets the model to Custom) into the project's machine, **in place** unless `-o` names another file. Values for a rotary axis the project's machine doesn't have are skipped, with a note.

```text
$ nativecam-cli machine grbl-settings.txt
Grbl $$ settings
  Controller: Grbl
  X travel: 31.496 in  ($130 X max travel (mm))
  Y travel: 31.496 in  ($131 Y max travel (mm))
  Z travel: 3.937 in  ($132 Z max travel (mm))
  Rapid X/Y: 197 in/min  (the lower of $110 and $111 max rate (mm/min))
  Rapid Z: 59 in/min  ($112 Z max rate (mm/min))
  Max cutting feed: 197 in/min  (the lower of $110 and $111 max rate (mm/min), which caps cutting feeds too)
  Acceleration X/Y: 19.7 in/s²  (the lower of $120 and $121 acceleration (mm/s²))
  Acceleration Z: 7.9 in/s²  ($122 Z acceleration (mm/s²))
  Corner tolerance: 0.000 in  ($11 junction deviation (mm))
  Max RPM: 24000 RPM  ($30 max spindle speed)
  Note: Soft limits are off ($20=0), so Grbl won't stop a move past the travel. NativeCAM's export check still compares the job with the travel.
$ nativecam-cli machine grbl-settings.txt --apply shop.nativecam -o shop-grbl.nativecam
…
Applied to shop-grbl.nativecam
```

Values print in the project's display units with `--apply`, otherwise in the file's units. A file it can't read exits 1 (`Can't read <path>: <reason>`). The settings must come from the human's own controller: don't write a `$$` dump or `Machine.ini` from guesses.

## tools

```text
nativecam-cli tools <library.tools | .vtdb | .json> [-o out.json]
```

Reads a Fusion 360 (`.tools`), Vectric (`.vtdb`) or NativeCAM (`.json`) tool library and prints what came across: the count by shape, what was skipped and why, and which values were estimated. `-o` saves it as a NativeCAM library (`{"tools": [...]}`), numbered T1, T2, … in order, for `template apply --tools`. A file it can't read exits 1.

```text
$ nativecam-cli tools Tests/CAMCoreTests/Fixtures/router-bit-feeds/form-bit-library.json -o lib.json
NativeCAM tool library: 4 tools, 0 skipped
  Dovetail: 1
  End Mill: 1
  Form: 2
  estimated: cutting length for 0, feed rate for 0, some value for 0
Wrote 4 tools to lib.json
```

The tools a project uses are copied into each toolpath (`operations[].tool`), so a library is only needed for `template apply`.

## template save

```text
nativecam-cli template save <project.nativecam> -o <out.nativecamtemplate> [--no-setup]
```

Saves the project's toolpaths, with their tools and settings and (unless `--no-setup`) its job setup, as a toolpath template. The template's name is the file's name. It prints how each toolpath will find its vectors. A toolpath with no `vectorSelection` gets one worked out from its shapes: `Text`, `Circles` and so on, or `Selected vectors` when there's no rule that fits. `-o` is required.

```text
$ nativecam-cli template save sign.nativecam -o Sign.nativecamtemplate
Saved 4 toolpaths to Sign.nativecamtemplate (format 1)
  V-carve title: Text
  Pocket plaque: Selected vectors
  Drill mounting holes: Circles
  Cut out sign: Selected vectors
```

A `Selected vectors` toolpath finds nothing when the CLI applies the template, because the CLI has no selection. Give such toolpaths a layer rule before saving (see [Project format](project-format.md#how-a-toolpath-finds-its-shapes)).

## template apply

```text
nativecam-cli template apply <template.nativecamtemplate> <project.nativecam> [-o out.nativecam | --in-place]
    [--setup] [--tools library.json] [--create-layers | --skip-missing]
```

Adds a template's toolpaths to a project and binds each one to the shapes its rule finds. It matches each tool to a library (the starter library unless `--tools`) and prints what each toolpath found.

| Argument | Default | Meaning |
|---|---|---|
| `-o out` | `<project> + <template>.nativecam` beside the project, then `… 2.nativecam` and so on if that's taken | Where to write |
| `--in-place` | off | Overwrite the project. Not with `-o` |
| `--setup` | off | Also use the template's job setup (material thickness, origin, heights; never the material's width and height or a rotary blank) |
| `--tools lib.json` | the starter library | The library its tools are matched against (shape, flute direction, diameter, angle, tip and corner radius; not numbers or names) |
| `--create-layers` | off | Make the layers the template's rules need and the design lacks, empty |
| `--skip-missing` | off | Leave out each toolpath whose layers are all missing. Not with `--create-layers` |

When the design lacks a layer the template needs and neither flag is given, it writes nothing and exits 1, naming the layers. Bad flag combinations are refused before anything is read.

```text
$ nativecam-cli template apply sign-layers-v1.nativecamtemplate board.nativecam -o x.nativecam
The design has no layers “V-Carve”, “Pocket”, “Holes”, “Cut Out”, which the template's toolpaths find their vectors on. Pass --create-layers to make them (empty, so vectors can be put on them later) or --skip-missing to leave out those toolpaths.
$ nativecam-cli template apply Sign.nativecamtemplate sign.nativecam -o applied.nativecam
  V-carve title: Text: 1 vector
  Pocket plaque: Selected vectors: 0 vectors, added empty
  Drill mounting holes: Circles: 4 vectors
  Cut out sign: Selected vectors: 0 vectors, added empty
  T5 60° V-Bit 1/2": in the library
  T1 1/4" Upcut End Mill: in the library
Material 0.7500 in; 2 toolpaths found no vectors
Wrote applied.nativecam
```

Without `-o` the `Wrote` line prints the absolute path. Toolpaths that found no vectors are still added. `post` then warns about each one (`No vectors on layer “Pocket”…`) and cuts nothing for it, so read the `found no vectors` count.

## nest

```text
nativecam-cli nest <project.nativecam> [-o out.nativecam | --in-place] [--spacing x] [--margin x] [--turns none|90|N]
    [--grain] [--seconds s] [--seed n] [--evaluations n] [--sheets n] [--sheet-size WxH] [--no-holes] [--svg preview.svg]
```

Nests every part onto the sheet, as **Toolpaths ▸ Nest Parts…** does, and writes the project with the parts moved. A part is a closed shape (with its holes and what's cut inside it) that a toolpath cuts out. Shapes made only of open vectors, or cutting across the material, stay where they are. See [Nesting parts](../using-nativecam.md#nesting-parts).

| Argument | Default | Meaning |
|---|---|---|
| `-o out` / `--in-place` | `<project> nested.nativecam` beside it | Where to write; pass one, not both |
| `--spacing x` | the cut-out bit's diameter plus 1/8 in (3 mm in a metric job) | The gap between parts, in the project's display units |
| `--margin x` | the spacing | The gap to the sheet's edges |
| `--turns` | `90` | `none`, `90`, or a number of evenly spaced turns (1–72) |
| `--grain` | off | Keep parts along the grain |
| `--seconds s` | 5 | How long to search |
| `--evaluations n` | none | Try exactly `n` layouts instead of searching for a time. With the same `--seed`, it gives the same layout every time. **Use it in scripts and tests** |
| `--seed n` | 1 | The search's random seed |
| `--sheets n` | 10, or the job's sheet count if more | Most sheets to use. When parts are left over it suggests `--sheets n+1` |
| `--sheet-size WxH` | the job's | The size of every sheet after the first, in display units, such as `48x96` |
| `--no-holes` | off | Keep parts out of other parts' holes |
| `--svg file` | none | Draws the layout, the sheets side by side |

Rotary jobs, and jobs with nothing to nest, are refused with exit 1.

```text
$ nativecam-cli nest demosheets.nativecam --evaluations 200 --seed 1 -o nested.nativecam
Nested 19 of 19 parts in 0.2 s (200 layouts tried), spacing 0.3750 in, edge margin 0.3750 in
On 2 sheets: sheet 1 11 parts, sheet 2 8 parts
In other parts' holes: Bracket 1 in Frame 1, Bracket 2 in Frame 1, Bracket 3 in Frame 2, Bracket 4 in Frame 2, Coaster 2 in Frame 2, Coaster 5 in Frame 2, Coaster 6 in Frame 1
Parts fill 59% of the 42.5102 in of the last sheet they use (61% of all the sheets' area)
Wrote nested.nativecam
$ nativecam-cli nest demosheets.nativecam --evaluations 100 --sheets 1 --no-holes -o one.nativecam
Nested 13 of 19 parts in 0.1 s (100 layouts tried), spacing 0.3750 in, edge margin 0.3750 in
Parts fill 74% of the 47.3772 in of the sheet they use (73% of the sheet)
  Didn't fit, stays where it is: Tray
  …
  Didn't fit, moved beside the sheet: Side 2
  6 parts didn't fit on 1 sheet; pass --sheets 2 to use another sheet
Wrote one.nativecam
```

Parts that don't fit still exit 0, so read the `Nested x of y` line. Posting a job nested onto several sheets writes one file per sheet.

## What the CLI can't do

- **Import vectors or 3D models.** There's no `import` command. See [Workflows](workflows.md#1-import-vectors-and-cut-a-profile-pocket-and-drill-job).
- **Re-run a toolpath's layer or kind rule** (Recalculate All), except through `template apply`. `post` cuts each toolpath's `shapeIDs` as listed.
- **Edit a project.** There are no `set` or `add` commands. Edit the JSON (see [Project format](project-format.md)).
- **Rewrite `formatVersion`.** Commands that save a project (`nest`, `template apply`, `machine --apply`, `calibrate fit --apply`) write the version the project needs; `post` and `sim` never write the project.
- **Send a file to a machine.** Nothing in NativeCAM does, by design.

[#152](https://github.com/NativeCAM/NativeCAM/issues/152) proposes `import`, rebind and re-save commands.
