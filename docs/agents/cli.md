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
- [import](#import)
- [rebind](#rebind)
- [save](#save)
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
- **Options** are read by name from anywhere after the command (`-o out.tap` or `--air-cut 1`). An option given without its value is ignored, and so is an unknown option, so check spelling: `--airc-cut 1` cuts at full depth without a word. `import`, `rebind` and `save` are stricter: they refuse an unknown option or one missing its value.
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
nativecam-cli post <project.nativecam> [-o out.tap] [--air-cut height] [--sheet out.html] [--rebind] [--force]
```

With a `--restart-*` flag it writes a restart file instead: see [Restart files](#restart-files). With `--group` or `--toolpaths` it writes a file for part of the job: see [Part of the job](#part-of-the-job-a-group-or-chosen-toolpaths).

Generates the toolpaths, runs the job's checks, posts the file for the project's machine, reads the file back with the export checks (`GCodeCheck`: against the controller, the toolpaths and the machine), prints every issue and, unless there's an error, writes the file.

| Argument | Default | Meaning |
|---|---|---|
| `<project>` | required | The project to post |
| `-o out` | the project's path | Where to write. Only the stem is used: the extension is always the controller's (`.tap` for Avid Mach4, `.nc`, `.ngc`, `.cnc` or `.sbp`), so `-o job.gcode` writes `job.tap` on Mach4 |
| `--air-cut h` | off | Raises every Z, safe height and park height by `h`, in the G-code's units, with X and Y unchanged. The file is named `<stem> (air cut).<ext>`, with `-o` too (a stem already ending in ` (air cut)` doesn't get it twice). `h` must be above zero, or it exits 1 |
| `--rebind` | off | First has every toolpath that finds its vectors by layer or kind (`vectorSelection`) look again, as Recalculate All does, and prints what changed (lines starting `Rebind:`). Only in memory: the project file isn't saved. Without it, `post` cuts exactly the `shapeIDs` the file lists |
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

**File.** `<stem> (restart at toolpath n pass p)<the full file's suffix>.<ext>`, for example `sign (restart at toolpath 2 pass 2).tap`. An exact restart adds where it resumes, `<stem> (restart at toolpath n pass p, exact line L)…` (pass 1 shows as `pass 1` here, though a snapped restart of pass 1 is just `(restart at toolpath n)`) (`move M`, the toolpath's move from 1, when you gave a toolpath and pass rather than a line), so it never overwrites the snapped restart of the same pass.

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

### Part of the job: a group or chosen toolpaths

```text
nativecam-cli post <project.nativecam> --group name [--full-retract] [--air-cut height] [--sheet out.html] [-o out.tap] [--force]
nativecam-cli post <project.nativecam> --toolpaths 1,3,Name [same options]
```

Writes a file for part of the job, as **Export Group…** and **Export Selected Toolpaths…** do in the app: a toolpath group (`toolpathGroups` in the project, see [Project format](project-format.md#toolpath-groups-and-hiding)), or toolpaths named by their number in the run order (from 1, `project.operations`), their id or their exact name, separated by commas.

The file is the full job cut down, never the toolpaths generated on their own. Later toolpaths are generated against what the earlier ones cut, so the file's moves, links included, are exactly the full file's for those toolpaths. That means it **assumes the included toolpaths that run before its last one were already cut**: a link can rapid down to just above a floor an earlier pocket cleared, and a rest pass cuts only what the earlier one left. Its header and its checks name each such toolpath.

| Argument | Default | Meaning |
|---|---|---|
| `--group name` | none | The group, by name or id. Exits 1 when no group or more than one has the name, listing the groups |
| `--toolpaths list` | none | Toolpaths by number, id or name. Not with `--group` |
| `--full-retract` | off | Generates the whole job again with every link going up to safe Z (`retractMode` `full`) for this file only, then cuts that down, so no link relies on the earlier toolpaths' cuts. The project isn't changed |
| `--air-cut h` | off | An air cut of the part, as for `post`: the file is `<stem> (air cut).<ext>` (`Sign - Finish (air cut).tap`, or `part (air cut).tap` with `-o part.tap`) and its first line is the `AIR CUT` comment, above the part's header |
| `--sheet out.html` | none | The part's own setup sheet: its toolpaths, the tool to load first, and what it assumes was cut |
| `-o out` | `<project> - <group>` | The stem to write. With `--toolpaths`, the default is `<project> - <toolpath name>` for one toolpath and `<project> - selected` for more |

**Air cuts and real cuts never share a name.** Every `post` path (the whole job, part of it, a restart) exits 1 and writes nothing, not even the setup sheet, when an air cut would replace a file that has no `AIR CUT` line at the top (it may be the real cut), or when a real cut's name says "air cut". Move the old file or pick another `-o`; don't delete the human's files to get past it.

Toolpaths that aren't included in the output (`"enabled": false`) are left out with an info line. Hidden ones (`"hidden": true`) are included: hiding is display only. A tile or sheet with none of the part's toolpaths gets no file. On a tiled job the registration holes stay only when the part starts at the job's first toolpath.

**Stdout.** The header lines, indented, then the job's issues and the part's checks (`[warning] Part of the job: …`), then:

```text
Part of the job: <n> toolpaths, <lines> lines -> <file>[, <file>…]
Estimated run time of the part: H:MM:SS
```

**Exit status.** 1 for no such group or toolpath, a part with nothing to cut (every toolpath of it turned off), a calibration program, or an error in the job's checks or the file's, as for `post`. Warnings, including the "assumes these were already cut" one, don't stop it.

**Example.** `Tests/CAMCoreTests/Fixtures/projects/toolpath-groups-v1.nativecam`, the demo sign in groups "Clear" and "Finish":

```text
$ nativecam-cli post "Grouped sign.nativecam" --group Finish
[info] Drill mounting holes: Cuts through the material (0.0200 in into the spoilboard).
[info] Cut out sign: Cuts through the material (0.0200 in into the spoilboard).
  PART OF Grouped sign: group “Finish”
  Cuts 2 V-carve title (T5)
  Assumes already cut: 1 Pocket plaque (T1)
  Links stay low over cleared material: cut those first
[warning] Part of the job: This file assumes these were already cut: 1 Pocket plaque (T1). Its links stay low over the material they clear, so cut them first, or export it retracting fully between cuts.
Part of the job: 1 toolpath, 463 lines -> Grouped sign - Finish.tap
Estimated run time of the part: 0:01:28
```

The file opens with its own tool change (`T5M6`), as every NativeCAM file does. **Hand over the warning with the file:** the human must cut the earlier toolpaths first, or ask for `--full-retract`. Never pass `--full-retract` to hide the warning without saying so; it changes every link in the file.

## sim

```text
nativecam-cli sim <project.nativecam | file.tap|.nc|.gcode|.ngc|.cnc|.txt|.sbp> [--png out.png] [--cell mm] [--heights out.bin] [--no-arcs] [--rebind]
```

Simulates material removal on a heightmap and prints what it found.

| Argument | Default | Meaning |
|---|---|---|
| `<input>` | required | A project, or a G-code or ShopBot file from any program. The extension decides which: anything other than those listed is read as a project |
| `--png out.png` | none | Writes the heightmap as a PNG. On a wrapped rotary job it's the blank unrolled |
| `--cell mm` | automatic | The grid's cell size in millimetres. Smaller is finer and slower |
| `--heights out.bin` | none | Writes the heightmap as little-endian binary: Int32 columns, Int32 rows, Float64 cell size, Float64 origin x, Float64 origin y, then columns × rows Float32 heights (mm, Z = 0 at the material top) |
| `--no-arcs` | off | Projects only: posts without arc fitting (`outputArcs` off) before simulating |
| `--rebind` | off | Projects only: rebinds in memory first, as `post --rebind` does, and prints what changed. A G-code file with it is refused |

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

## surface

```text
nativecam-cli surface [project.nativecam] [--area bed|WxH] [--inset x] [--bit n] [--stepover 50] [--depth d] [--passes n]
    [--along x|y] [--one-way] [--overshoot x] [--clamp-overshoot] [--clearance z] [--board t]
    [--controller c] [--sender s] [--units inch|mm] [-o file] [--no-air-cut]
```

Writes a spoilboard surfacing program for the project's machine, or for the default Avid PRO6060 on Mach4 without a project, plus an air-cut copy raised 1 in (25 mm). It's the counterpart of **File ▸ Surface Spoilboard…** ([Surfacing the spoilboard](../using-nativecam.md#surfacing-the-spoilboard)). **The human runs it, air cut first.** The project only lends its machine and tools and isn't changed. `--controller`, `--sender` and `--units` work as for [`acceptance`](#acceptance). Lengths are in the G-code's units.

| Option | Default | Rules |
|---|---|---|
| `--area` | `bed`: the travel less `--inset` (1/4 in or 6 mm) on each side | `WxH` is a board. Every move keeps `--inset` clear of the travel's limits: a board, or its lines with their overshoot, that would come nearer is refused |
| `--bit n` | the starter surfacing bit, T8 (1-1/4") | a surfacing bit or flat end mill from the project's toolpaths or the starter library. Its feed and RPM are used; a feed above the machine's highest is refused |
| `--stepover` | 50 (percent of the bit) | 10 to 90; a warning above 80 |
| `--depth` | 0.02 in or 0.5 mm per pass | at most min(flute length, 1/8 in or 3 mm); a warning above 1/16 in or 1.5 mm |
| `--passes` | 1 | 1 to 20; the total no deeper than the flutes, a warning above 1/8 in |
| `--along` | `x` | lines along X or Y |
| `--one-way` | zig-zag | every line climb, with a retract between: for reading tram |
| `--overshoot` | the bit's radius + 1/8 in (3 mm) | none on the whole bed: its lines stop on the area's edges. `--clamp-overshoot` shortens a board's to keep the margin, with a warning, instead of refusing |
| `--clearance` | 0.5 in or 12 mm | every rapid stays at or above it |
| `--board t` | none | the spoilboard's thickness: refused when less than 1/2 in (12 mm) would be left |

The program's first line is `(Z ZERO: TOP OF THE SPOILBOARD {touch plate on the board})`. XY zero is the area's front-left corner (for the whole bed, the inset in from the front-left limits of travel). The spindle dwells at least 3 s before the first contact, whatever the machine's spin-up dwell. A custom board plunges in free air past its edge; the whole bed ramps in over at least twice the bit's diameter. The file is checked with the same read-back as `post`, plus its own: every cut at exactly −k × the depth, the lowest point at the total depth, no rapid below the clearance, the program's whole extent at least the inset inside the travel (by span on a board; by position on the whole bed, zeroed the inset in from the front-left limits). Both files must pass, or nothing is written.

```text
$ nativecam-cli surface
Avid Mach4 spoilboard surfacing -> surface-spoilboard-61x61in.tap
Air cut (Z raised 1 in) -> surface-spoilboard-61x61in-air.tap
  60.875 × 60.875 in, 99 lines along X 0.621 in apart, both ways (zig-zag), 1 x 0.02 in = 0.02 in deep
  1-1/4" Surfacing Bit: 150 in/min, 12000 RPM; overshoot 0 in, entry: ramp of 2.5 in
  Z ZERO: TOP OF THE SPOILBOARD (touch plate on the board)
  XY ZERO: the front-left corner of the area, 0.25 in in from the front-left limits of travel: …
Estimated run time: 0:40:53
$ nativecam-cli surface --area 60x24
Not written: With the 0.75 in overshoot at each end, the lines run 61.5 in in X, more than the 60.875 in of travel left with 0.25 in kept clear of each limit. Shorten the overshoot to 0.437 in or make the area smaller.
$ nativecam-cli surface --area 12x12 --one-way --stepover 90 --depth 0.01
[warning] A stepover of 90% is above 80%: fine for reading tram, but it can leave ridges.
Avid Mach4 spoilboard surfacing -> surface-spoilboard-12x12in.tap
…
```

Warnings print as `[warning] …` and the file is still written: report them with it. The human must clear the bed (every clamp off, every screw head below the cut), zero Z on the board's top and run the air cut first, watching both far corners for a soft-limit stop. Where the PRO6060 homes and where its soft limits sit hasn't been checked, and no surfacing program has run on a real machine yet: say so when you hand the files over.

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
Wrote applied.nativecam (format 1)
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
| `--spacing x` | twice the cut-out bit's diameter plus 1/8 in (3 mm in a metric job), so a neighbour's cut never reaches a part's tabs | The gap between parts, in the project's display units. It isn't saved in the project |
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
Nested 19 of 19 parts in 0.3 s (200 layouts tried), spacing 0.6250 in, edge margin 0.6250 in
On 2 sheets: sheet 1 8 parts, sheet 2 11 parts
In other parts' holes: Bracket 3 in Frame 2, Coaster 1 in Frame 1, Coaster 2 in Frame 2, Coaster 3 in Frame 1, Coaster 4 in Frame 1
Parts fill 57% of the 44.5181 in of the last sheet they use (61% of all the sheets' area)
Wrote nested.nativecam
$ nativecam-cli nest demosheets.nativecam --evaluations 100 --sheets 1 --no-holes -o one.nativecam
Nested 6 of 19 parts in 0.1 s (100 layouts tried), spacing 0.6250 in, edge margin 0.6250 in
Parts fill 75% of the 47.3746 in of the sheet they use (74% of the sheet)
  Didn't fit, stays where it is: Tray
  …
  Didn't fit, moved beside the sheet: Shelf 1
  13 parts didn't fit on 1 sheet; pass --sheets 2 to use another sheet
Wrote one.nativecam
```

Parts that don't fit still exit 0, so read the `Nested x of y` line. Posting a job nested onto several sheets writes one file per sheet.

## import

```text
nativecam-cli import <project.nativecam> <file>… (-o out.nativecam | --in-place) [--units in|mm] [--layer name]
    [--keep-coords | --center | --at x,y] [--sheet n] [--depth d] [--up z|y]
```

Adds vector files (`.dxf`, `.svg`, `.pdf`, `.ai`) and 3D models (`.stl`, `.obj`, `.3mf`, `.ply`, `.usdz`, `.usd`, `.usda`, `.usdc`) to a project, as **File ▸ Import** does, through the same code: one shape per layer (named `<file> – <layer>` when the file has more than one), DXF points as a separate `… points` shape of 1 mm circles for a Drill toolpath, and each model centred, scaled down to 90% of the material if it's larger, and carved no deeper than the material less 0.02 in (on a rotary blank, laid along the axis). Then every toolpath that finds its vectors by layer or kind (`vectorSelection`) picks them up. Toolpaths whose vectors were chosen by hand are never touched. Several files are imported in the order given.

| Argument | Default | Meaning |
|---|---|---|
| `<project>` | required | The project to add to |
| `<file>…` | at least one | The files to import |
| `-o out` / `--in-place` | **one is required** | Where to write: `-o` a new file, or `--in-place` to overwrite the project. Both together, neither, or `-o` naming the project itself are refused |
| `--units in\|mm` | none | The unit of a file that carries none: a DXF without `$INSUNITS`, STL, OBJ or PLY. **A DXF without `$INSUNITS` is refused without it.** A mesh without it is read in millimetres. A file that states its unit keeps it, with a warning if `--units` says otherwise. SVG and PDF always use their own units (an SVG without physical units is read at 96 px per inch, with a warning) |
| `--layer name` | the file's layers | Puts every imported vector shape (not 3D models) on this layer, for a toolpath or template that finds its vectors there |
| `--keep-coords` | the default | Keep the file's coordinates. **A drawing that doesn't then lie on the material is refused**, with its extent and the material's |
| `--center` | off | Centre each drawing on the material, as the app does with one that doesn't fit |
| `--at x,y` | off | Put each drawing's bounding-box lower-left corner at x,y, in the project's display units |
| `--sheet n` | 1 | On a job nested onto several sheets, the sheet the shapes go on and are placed against |
| `--depth d` | in proportion to the model's size | A model's carved depth, in display units. Deeper than the material less 0.02 in is refused |
| `--up z\|y` | the importer's guess (Z for STL and 3MF, Y for OBJ, PLY and USD) | A model's up axis |

Only one of `--keep-coords`, `--center` and `--at` may be given. They place drawings; models are always centred. Nothing is written until every file has been imported, so a refusal (exit 1) leaves no file behind: an unreadable or unsupported file, a file with no usable vectors, a unitless DXF without `--units`, a drawing off the material, a `--depth` too deep, an unknown option.

For each file it prints the unit it read the file in and why (`as the file says`, `from --units`, or `assumed`), the importer's notes as `[warning]` lines (units guessed, paths left open, duplicates removed, entities skipped), each shape added with its layer, size, extent and paths (`… open` when some paths aren't closed: a profile or pocket needs closed ones), and how it was placed. **A drawing under 1% of the material's size, or larger than the material, warns**: that's usually the wrong unit, and the warning names the other one. Then it prints every toolpath whose vectors changed, the toolpaths kept as chosen by hand, and the file written with its format.

```text
$ nativecam-cli import target.nativecam cli-two-layers-inch.dxf cli-points.dxf -o two.nativecam
cli-two-layers-inch.dxf: inches, as the file says
  Added “cli-two-layers-inch – Profile” on layer “Profile”: 6.0000 × 4.0000 in from (2.0000, 2.0000) to (8.0000, 6.0000), 1 closed path
  Added “cli-two-layers-inch – Pocket” on layer “Pocket”: 2.0000 × 2.0000 in from (4.0000, 3.0000) to (6.0000, 5.0000), 1 closed path
  Kept the file's coordinates
cli-points.dxf: inches, as the file says
  Added “cli-points points” on layer “Holes”: 4.0394 × 2.0394 in from (2.9803, 2.9803) to (7.0197, 5.0197), 4 closed paths
  Kept the file's coordinates
Toolpaths whose vectors changed:
  Pocket (Layer “Pocket”): 0 → 1 vector (1 added)
  Drill holes (Layer “Holes”): 0 → 1 vector (1 added)
  Cut out part (Layer “Profile”): 0 → 1 vector (1 added)
Kept as chosen by hand: Hand-picked V-carve (1 vector)
Wrote two.nativecam (format 1)
$ nativecam-cli import target.nativecam cli-no-units.dxf -o x.nativecam
Not written: cli-no-units.dxf has no $INSUNITS in its header, so its unit is unknown. Pass --units in or --units mm to say what it was drawn in.
$ nativecam-cli import target.nativecam cli-off-material.dxf -o x.nativecam
cli-off-material.dxf: inches, as the file says
  Added “cli-off-material” on layer “Profile”: 4.0000 × 3.0000 in from (30.0000, 30.0000) to (34.0000, 33.0000), 1 closed path
Not written: cli-off-material.dxf doesn't fit on the material in the file's coordinates. The drawing runs from (30.0000, 30.0000) to (34.0000, 33.0000) in; the material is 24.0000 × 18.0000 in from (0, 0). Pass --center to centre it on the material, or --at x,y to put its lower-left corner there.
```

These files are the test fixtures in `Tests/CAMCoreTests/Fixtures/import`, imported into `projects/cli-import-target.nativecam`; their full output is in `Fixtures/golden/cli-*.txt`. A toolpath whose rule finds nothing still has no vectors (`0 → 0` isn't printed: nothing changed), and `post` then warns about it, so check each toolpath you expected to pick up the import is in the list.

## rebind

```text
nativecam-cli rebind <project.nativecam> (-o out.nativecam | --in-place)
```

Recalculate All's vector binding: every toolpath that finds its vectors by layer or kind looks again, and gets exactly what its rule finds now. Use it after editing the JSON (moving shapes to another layer, adding or removing shapes). It prints each toolpath whose vectors changed, with how many were added and removed, says when a toolpath is left with none, and names the toolpaths kept as chosen by hand (no `vectorSelection`, or `selection`), which it never changes. With nothing to change it says `No changes` and **still writes the output**, so a script can rely on the file being there. `-o` or `--in-place` is required, as for `import`.

```text
$ nativecam-cli rebind cli-unbound.nativecam -o bound.nativecam
Toolpaths whose vectors changed:
  Pocket (Layer “Pocket”): 0 → 1 vector (1 added)
  Drill holes (Layer “Holes”): 0 → 1 vector (1 added)
  Cut out part (Layer “Profile”): 1 → 1 vector (1 added, 1 removed)
Kept as chosen by hand: Hand-picked V-carve (1 vector)
Wrote bound.nativecam (format 1)
$ nativecam-cli rebind bound.nativecam -o again.nativecam
No changes: every toolpath that finds its vectors by layer or kind already has them.
Kept as chosen by hand: Hand-picked V-carve (1 vector)
Wrote again.nativecam (format 1)
```

`post --rebind` and `sim --rebind` do the same in memory, without saving.

## save

```text
nativecam-cli save <project.nativecam> (-o out.nativecam | --in-place) [--rebind]
```

Reads the project and writes it again, so `formatVersion` is the oldest format that can hold it (see [Project format](project-format.md#format-versions)), keys are sorted, and depths are fitted to the material as on any load. Use it after a hand edit. It prints the format the file said and the one written. `--rebind` rebinds first, as `rebind` does. `-o` or `--in-place` is required.

```text
$ nativecam-cli save cli-hand-edited-v1.nativecam -o saved.nativecam
Format 1 → 28
Wrote saved.nativecam (format 28)
$ nativecam-cli save saved.nativecam --in-place
Format 28, unchanged
Wrote saved.nativecam (format 28)
```

None of `import`, `rebind` and `save` writes G-code, sends anything to a machine or takes `--force`.

## What the CLI can't do

- **Edit a project.** There are no `set` or `add` commands. Edit the JSON (see [Project format](project-format.md)), then `rebind` and `save` it. Toolpaths are added by JSON or `template apply`.
- **Map several of a file's layers onto others.** `import --layer` puts every vector shape on one layer; to keep a file's layers apart, import it as it is and match the toolpaths' rules to its layer names.
- **Send a file to a machine.** Nothing in NativeCAM does, by design. `post` and `sim` never write the project; `post` is the only command that writes a program for the job.
