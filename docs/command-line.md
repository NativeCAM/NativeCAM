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
swift run -c release nativecam-cli template save sign.nativecam -o "Sign.nativecamtemplate"  # save a project's toolpaths as a template
swift run -c release nativecam-cli template apply "Sign.nativecamtemplate" board.nativecam  # writes "board + Sign.nativecam"
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
| `demo`, `demo3d`, `new` `<out.nativecam>` | Write the demo sign, the 3D relief demo, or an empty project on the default machine |
| `post <project> [-o out] [--air-cut height] [--sheet out.html] [--force]` | Generate toolpaths and the file for the project's machine, run the [export checks](controllers.md#export-checks-air-cuts-and-setup-sheets) and print every issue. When the job's checks or the export checks find an error, it writes nothing and exits with status 1, unless you pass `--force`; warnings don't stop it. A machine that can't stop for a tool change gets one file per tool (`demo 1 of 2 - T5.nc`, …). `--air-cut` raises every Z by the height (in the file's units); `--sheet` writes a setup sheet. |
| `sim <project or file> [--png out.png] [--cell mm] [--heights out.bin]` | Simulate material removal and print stats. Takes a project, or G-code or a ShopBot `.sbp` from any program. `--cell` sets the grid resolution; `--heights` writes the heightmap as binary (header Int32 cols, Int32 rows, Float64 cell, origin x, origin y, then Float32 heights). On a wrapped rotary job the heightmap and PNG are the blank unrolled onto its sheet. |
| `tools <library> [-o out.json]` | Read a Fusion 360, Vectric or NativeCAM tool library, print what came across, and optionally save it as a NativeCAM library |
| `template save <project> -o <out.nativecamtemplate> [--no-setup]` | Save the project's toolpaths, with their tools and settings and (unless `--no-setup`) its job setup, as a [toolpath template](using-nativecam.md#templates). Prints how each toolpath will find its vectors. |
| `template apply <template> <project> [-o out \| --in-place] [--setup] [--tools library.json]` | Add a template's toolpaths to a project, matching its tools to a tool library (the starter library unless `--tools`), and print what each toolpath found. It never writes over the project unless told to: it saves `<project> + <template>.nativecam` beside it (`… 2.nativecam` and so on if that's taken), or the file `-o` names; `--in-place` overwrites the project. `--setup` uses the template's job setup as well. |
| `machine <settings> [--apply project [-o out]]` | Read machine limits from Grbl `$$`, Mach4 `Machine.ini`, LinuxCNC INI, FluidNC YAML or Fusion `.mch`, and optionally apply them to a project ([details](machines.md#importing-controller-settings)) |
| `acceptance [machine.nativecam] [--controller family] [--sender name] [--units inch\|mm] [--tool-change m6\|pause\|atc] [-o out]` | Write the [acceptance test program](controllers.md#trying-a-new-controller-safely) for a controller. Controller names: `grbl`, `grblHAL`, `fluidNC`, `carbideMotion`, `linuxCNC`, `masso`, `centroid`, `buildbotics`, `openSBP`, `richAuto`. |
