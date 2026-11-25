# Command line

[← Back to the README](../README.md)

`nativecam-cli` runs the same engine without the UI. It's handy for scripting, CI, and checking G-code from other programs.

```bash
swift run -c release nativecam-cli demo demo.nativecam              # write the demo sign (demo3d: 3D relief, new: empty project)
swift run -c release nativecam-cli post demo.nativecam -o demo.tap  # generate toolpaths, run checks, write G-code
swift run -c release nativecam-cli post demo.nativecam --air-cut 1 --sheet demo.html  # air cut 1" up, plus a setup sheet
swift run -c release nativecam-cli sim demo.nativecam --png out.png # simulate, report, render the result as a heightmap
swift run -c release nativecam-cli sim other-cam-job.tap            # simulate G-code from any CAM program
swift run -c release nativecam-cli tools vendor.vtdb -o tools.json  # convert a Fusion 360 or Vectric tool library
swift run -c release nativecam-cli machine Machine.ini --apply job.nativecam  # read controller limits into a project
swift run -c release nativecam-cli acceptance --controller grbl --units mm    # write the acceptance test for a controller
swift run -c release nativecam-cli calibrate timing shop.nativecam          # write the timing suite, its recording sheet and times file
swift run -c release nativecam-cli calibrate fit calibration-timing-times.csv shop.nativecam --apply  # fit the times into the machine
swift run -c release nativecam-cli template save sign.nativecam -o "Sign.nativecamtemplate"  # save a project's toolpaths as a template
swift run -c release nativecam-cli template apply "Sign.nativecamtemplate" board.nativecam  # writes "board + Sign.nativecam"
swift run -c release nativecam-cli template apply "Sign.nativecamtemplate" board.nativecam --create-layers  # make the layers the board lacks
```

```text
$ nativecam-cli post demo.nativecam -o demo.tap
[info] Drill mounting holes: Cuts through the material (0.0200 in into the spoilboard).
[info] Cut out sign: Cuts through the material (0.0200 in into the spoilboard).
Generated 4 toolpaths in 0.01s, 893 lines -> demo.tap
Estimated run time: 0:06:54 (cutting 0:05:30, rapids 0:00:24, tool changes/pauses 0:01:00; distance/feed alone: 0:06:26)
  V-carve title: 0:01:26
  Pocket plaque: 0:02:18
  Drill mounting holes: 0:00:19
  Cut out sign: 0:01:48
```

## Commands

| Command | What it does |
|---|---|
| `demo`, `demo3d`, `demonest`, `demosheets`, `new` `<out.nativecam>` | Write the demo sign, the 3D relief demo, the shelf parts demo (for nesting), the shelf, frames and coasters demo (for nesting onto more sheets and into holes), or an empty project on the default machine |
| `post <project> [-o out] [--air-cut height] [--sheet out.html] [--force]` | Generate toolpaths and the file for the project's machine, run the [export checks](controllers.md#export-checks-air-cuts-and-setup-sheets) and print every issue. When the job's checks or the export checks find an error (a program larger than the machine's travel in X, Y or Z, say, or a cut deeper than the bit sticks out), it writes nothing and exits with status 1, unless you pass `--force`, which writes the file and still prints every error; warnings don't stop it. A machine that can't stop for a tool change gets one file per tool (`demo 1 of 2 - T5.nc`, …). `--air-cut` raises every Z by the height (in the file's units); `--sheet` writes a setup sheet. |
| `sim <project or file> [--png out.png] [--cell mm] [--heights out.bin]` | Simulate material removal and print stats. Takes a project, or G-code or a ShopBot `.sbp` from any program. `--cell` sets the grid resolution; `--heights` writes the heightmap as binary (header Int32 cols, Int32 rows, Float64 cell, origin x, origin y, then Float32 heights). On a wrapped rotary job the heightmap and PNG are the blank unrolled onto its sheet. |
| `tools <library> [-o out.json]` | Read a Fusion 360, Vectric or NativeCAM tool library, print what came across, and optionally save it as a NativeCAM library |
| `template save <project> -o <out.nativecamtemplate> [--no-setup]` | Save the project's toolpaths, with their tools and settings and (unless `--no-setup`) its job setup, as a [toolpath template](using-nativecam.md#templates). Prints how each toolpath will find its vectors. |
| `template apply <template> <project> [-o out \| --in-place] [--setup] [--tools library.json] [--create-layers \| --skip-missing]` | Add a template's toolpaths to a project, matching its tools to a tool library (the starter library unless `--tools`), and print what each toolpath found, with any size rule it uses. When the template's toolpaths find their vectors on layers the project doesn't have, it stops and names them unless told what to do: `--create-layers` makes them, empty, so vectors can be put on them later (it prints the layers it made), and `--skip-missing` leaves out each toolpath whose layers are all missing (it prints how many). Pass one, not both. It never writes over the project unless told to: it saves `<project> + <template>.nativecam` beside it (`… 2.nativecam` and so on if that's taken), or the file `-o` names; `--in-place` overwrites the project. `--setup` uses the template's job setup as well. |
| `nest <project> [-o out \| --in-place] [--spacing x] [--margin x] [--turns none\|90\|N] [--grain] [--seconds s] [--seed n] [--evaluations n] [--sheets n] [--sheet-size WxH] [--no-holes] [--svg preview.svg]` | [Nest](using-nativecam.md#nesting-parts) every part on the sheet as **Toolpaths ▸ Nest Parts…** does, and print how much of the sheet the parts use, which went in other parts' holes and what didn't fit. Parts that don't fit go on more sheets, up to 10 as Nest Parts in the app allows to start with (or as many as the project has, if more); `--sheets` sets the limit, and when parts are left over at the limit it says how many and suggests one more. Sheets after the first are sized `--sheet-size` (in the project's units, e.g. `48x96`); `--no-holes` keeps parts out of other parts' holes. Lengths are in the project's units; spacing defaults to the cut-out bit's diameter plus 1/8 in (3 mm in a metric job) and the margin to the spacing. `--turns` takes `none`, `90` (the default) or a number of evenly spaced turns; `--grain` keeps parts along the grain. The search runs for `--seconds` (5 by default), or for exactly `--evaluations` layouts, which with the same `--seed` always gives the same layout. `--svg` draws the layout. It saves `<project> nested.nativecam` beside the project unless `-o` names the file or `--in-place` overwrites it. |
| `machine <settings> [--apply project [-o out]]` | Read machine limits from Grbl `$$`, Mach4 `Machine.ini`, LinuxCNC INI, FluidNC YAML or Fusion `.mch`, and optionally apply them to a project ([details](machines.md#importing-controller-settings)) |
| `calibrate timing\|rotary\|ladder [project] [--controller family] [--sender name] [--units inch\|mm] [-o stem]` | Write a [calibration program](using-nativecam.md#calibrating-your-machine) for the project's machine (Avid's PRO6060 without a project): `stem.tap` (or the controller's extension), its recording sheet `stem.html` and, for the timing suite and the rotary check, the times file `stem-times.csv`. The stem defaults to `calibration-timing` and so on. `timing` takes `--window WxH` (24x24 in, or 600x600 mm, by default) and `--air height` (1 in or 25 mm, never below 25 mm). `ladder` takes `--tool n` (from the project's toolpaths or the starter library; T1 by default), `--material` (`plywood`, `hardwood`, `softwood`, `mdf`, `laminatedParticle`, `softPlastic`, `hardPlastic`; the project's by default), `--depth d`, `--rungs n` (7) and `--step-rpm`. Lengths are in the file's units. A program that can't be made (a window bigger than the machine, a rotary check on a controller that can't drive A) is refused with the reason and exit status 1. |
| `calibrate fit <times.csv> [more-times.csv] [project] [--apply] [-o out]` | Fit the project's machine (Avid's PRO6060 without one) to the times written in the times files. It prints each value before and after, every section's error before and after, and the F-change and G93 verdicts. Times that can't be fitted are refused with the reason and exit status 1. `--apply` writes the fitted values, marked as measured, into the project's machine, in place unless `-o` names another file. |
| `surface [project] [--area bed\|WxH] [--inset x] [--bit n] [--stepover %] [--depth d] [--passes n] [--along x\|y] [--one-way] [--overshoot x] [--clamp-overshoot] [--clearance z] [--board t] [--controller family] [--units inch\|mm] [-o file] [--no-air-cut]` | Write a [spoilboard surfacing program](using-nativecam.md#surfacing-the-spoilboard) for the project's machine (Avid's PRO6060 without a project), and an air-cut copy `file-air.tap` unless `--no-air-cut`. The whole bed by default, or a `WxH` board; the starter surfacing bit unless `--bit` names a tool in the project or the starter library. Lengths are in the file's units, the stepover in percent. The file is named like `surface-spoilboard-61x61in.tap` unless `-o`. A refusal (too deep, past the travel, a thin board, a stepover above 90%, no post, a feed above the machine's highest) or a failed check exits 1 and writes nothing. |
| `acceptance [machine.nativecam] [--controller family] [--sender name] [--units inch\|mm] [--tool-change m6\|pause\|atc] [-o out]` | Write the [acceptance test program](controllers.md#trying-a-new-controller-safely) for a controller. Controller names: `grbl`, `grblHAL`, `fluidNC`, `carbideMotion`, `linuxCNC`, `masso`, `centroid`, `buildbotics`, `openSBP`, `richAuto`. |
