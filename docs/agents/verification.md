# Verifying output

[← Back to AGENTS.md](../../AGENTS.md)

How an agent checks its output before handing it to a human. None of these checks replaces the human's own: the acceptance test, an air cut and watching the first real cut are theirs (see [AGENTS.md](../../AGENTS.md#hard-safety-rules)).

- [What "safety" means here](#what-safety-means-here)
- [Reading post's checks](#reading-posts-checks)
- [The simulator](#the-simulator)
- [Estimates](#estimates)
- [Goldens and scripts/test.sh](#goldens-and-scriptstestsh)
- [Snapshot mode for UI screenshots](#snapshot-mode-for-ui-screenshots)
- [A checklist before hand-over](#a-checklist-before-hand-over)

## What "safety" means here

In NativeCAM, safety means three things, in this order:

1. **No crash.** The machine must not hit anything: a clamp or fixture (keep-outs), the rotary's chuck or tailstock, the end of its travel. A rapid must never move sideways through material.
2. **No gouge.** The bit must not cut the finished part or go deeper than asked: an inside corner, a lead into a neighbouring part, a 3D finish below the model, a wrapped design mirrored round the blank.
3. **No wrong G-code.** The controller must read the file as meant: the right units, a tool change that really stops, a dwell in the unit the controller reads, arcs within its tolerance, `G93` feeds where needed, every move on the line the toolpath asked for.

A test or check that guards one of these is never loosened to make a job or a test pass. A change that would alter posted G-code is checked against the goldens (below). In the repository's issues, bugs of these kinds carry the `safety` label and are fixed first.

## Reading post's checks

`nativecam-cli post` runs two sets of checks and prints them as `[severity] …` lines:

| Lines | Come from | What they check |
|---|---|---|
| `[severity] <toolpath>: …` | The job's checks (`CAMEngine`) | Each toolpath against the material, the machine and the tools: depth into the spoilboard, depth against the bit's cutting length, toolpaths off the material, the work area, keep-outs, tool-number clashes, chip loads against the charts, rapids below the surface, rotary-blank limits, inlay fit, empty toolpaths |
| `[severity] G-code: …` | The export checks (`GCodeCheck`), reading the posted file back | **Against the controller:** units before moving, line length, accepted codes, arcs, dwells, spindle on before cutting, a lift after each tool change, A moves, `G93` rules. **Against the toolpaths:** every cutting move, arc, feed, dwell, tool, spindle speed and rotary angle. **Against the machine:** the whole program's extent, park included, against the travel |

What each severity means, and what to do:

| Severity | `post` | What the agent does |
|---|---|---|
| `error` | Writes no G-code, exits 1 | Fix the project. If you can't, report it. **Never `--force`** |
| `warning` | Writes the file | Read it, fix it when the fix is clear (a feed the chip-load check suggests, a design too big for the board), and report any you leave |
| `info` | Writes the file | Pass on the ones that ask the human to do something (measure the rotary's centre height, jog the rotary to check its direction, change the bit between files) |

**Errors about the machine and the bit** ([#151](https://github.com/NativeCAM/NativeCAM/issues/151)). `post` refuses these and exits 1; in the app, Export lists them and asks "Export Anyway?":

- `The program moves … in X, retracts and park included, … more than the machine's … of X travel.` (or Y). The program can't fit on the machine, wherever the work is zeroed. Make it smaller, nest or tile it, or check the machine's travel.
- `The program spans … in Z; with … of tool sticking out that's … more than the machine's … of Z travel.` The lowest move is out of reach of the highest with that bit. Check the Z travel, the park and safe heights, and the stickout.
- `Depth … is more than … sticks out of the collet (…), so the collet nut would hit the stock.` On a 2.5D toolpath. Cut shallower, or ask the human to let the bit out further and set its stickout.

**Warnings that should stop a hand-over until the human has seen them**, because the file is written anyway:

- `Toolpath extends beyond the material edges.` Often a part off the material: nest it, or move it.
- `Cuts … into the spoilboard (material is … thick).` A depth or thickness is wrong.
- `Depth … exceeds the cutting length of …, so the shank rubs below the flutes.` The bit can't cut that deep without its shank rubbing.
- `No vectors on layer …` / `No shapes selected.` A toolpath that cuts nothing.
- On a rotary job, the direction note (`jog the rotary axis positive…`). Wrapped work comes out mirrored if the direction is wrong.

Grep for them: `post … | grep -E '^\[(error|warning)\]'`. An empty result, a 0 exit status and the expected toolpath count in the `Generated n toolpaths` line are the minimum before a hand-over.

For what each check covers, see [Export checks](../controllers.md#export-checks-air-cuts-and-setup-sheets). The checks run the same way in the app's **Checks** panel and on **Export**.

## The simulator

`nativecam-cli sim` carves a heightmap with each bit's true shape (see [Command line](cli.md#sim)):

- **Rapids through material.** `[error] n rapid move(s) cut through material` is a crash waiting to happen. `sim` still exits 0, so grep its stdout for `[error]`.
- **Removed volume.** `Removed 82.8 cm³ of material`. Compare it with what the design should remove (a pocket's area × depth, say). A figure near zero means the toolpaths cut nothing. On a rotary job, each face's removal is reported on its own.
- **The picture.** `--png` writes the heightmap, shaded, and darker where deeper. Look at it: holes where holes should be, nothing cut where nothing should be, letters the right way round.
- **Before and after.** To measure how much a change alters the part, simulate both G-code files on the same grid and compare the heightmaps:

  ```bash
  nativecam-cli sim before.tap --cell 0.25 --heights before.bin
  nativecam-cli sim after.tap --cell 0.25 --heights after.bin
  scripts/measure/compare_parts.py before.bin after.bin --rect 0 0 300 200   # mm; or --ellipse cx cy rx ry
  ```

  `scripts/measure/analyze.py job.tap` breaks a posted file down per toolpath (cutting and rapid length, retracts, plunges) with its own timing.

`sim` on a **G-code file** uses the default 24 × 18 × 0.75 in block and the starter tools by number, so it's only a rough check for another program's file. `sim` on a **project** simulates what `post` would write, and is the one to trust.

The simulator sees each bit from below: it can't show an undercut (a dovetail's, or a back bore's), and a wrapped wall shows very slightly radial. See [Known limits](../known-limits.md).

## Estimates

`post` prints the run-time estimate; `sim` on a project ends at the same job time. It times the posted moves with the controller's look-ahead planner, the machine's accelerations and corner tolerance, tool changes (`toolChangeSeconds`; 60 s manual, 15 s ATC) and, on a rotary job, each turn of the blank. See [Run-time estimates](../machines.md#run-time-estimates).

Report it as an estimate. The accelerations are class defaults (50 in/s² X/Y on the Avid profile) until the human runs the timing suite and the fit is applied, and no estimate has yet been timed against a real machine. `distance/feed alone` is the naive figure, for comparison only.

## Goldens and scripts/test.sh

When a task changes engine or post code, the test suite is the check:

```bash
scripts/test.sh                                  # the whole suite, optimised, in .build/tests
scripts/test.sh --filter GoldenPostTests         # one suite; the filter matches the type name
NATIVECAM_TEST_DEBUG=1 scripts/test.sh            # unoptimised, for a debugger
```

Use `scripts/test.sh`, not plain `swift test`. It adds the flags Swift Testing needs with only the Command Line Tools, and builds optimised, since the geometry and simulation are far slower unoptimised. GitHub Actions runs the same script, plus `swift build` for the app and the CLI, on every pull request.

**Golden G-code.** `GoldenPostTests` and one suite per controller compare posted files **byte for byte**, line endings included, with [`Tests/CAMCoreTests/Fixtures/golden/`](../../Tests/CAMCoreTests/Fixtures/golden/): a job reaching every branch of a post, the demos, each controller's acceptance program, and the saved projects in [`Fixtures/projects/`](../../Tests/CAMCoreTests/Fixtures/projects/). Every golden must also pass the export checks.

- A mismatch writes the new output to `.build/golden-actual/` (and CI keeps it as a `golden-actual` download).
- Only when the change is **meant** to alter the G-code, accept it with `NATIVECAM_UPDATE_GOLDENS=1 scripts/test.sh --filter <Suite>`, then read `git diff Tests/CAMCoreTests/Fixtures` line by line and say in the PR what changed and why. Never update goldens to make an unexplained difference go away.
- Saved projects in `Fixtures/projects/` are **never regenerated**. When the format changes, add a new one named for its format (`feature-vNN.nativecam`).
- New features add their own fixtures as new files: goldens, a saved project and, where it applies, import fixtures. The `*CatalogTests` suites post each catalogued fixture and check it.

`CommandLineTests` covers the CLI. Don't add a test count to any doc.

## Snapshot mode for UI screenshots

The app has a snapshot mode that renders the main window and more to PNGs, logs its checks, then quits. It's for screenshots in PRs and tutorials, and for checking UI changes without clicking through the app. It needs a logged-in Mac session with a screen: the window goes on screen for a moment, all but one column of points past the right edge. It doesn't run in CI.

```bash
scripts/build-app.sh                                                        # builds build/NativeCAM.app
build/NativeCAM.app/Contents/MacOS/NativeCAM \
  -NativeCAMSnapshotProject "$PWD/examples/Demo Sign.nativecam" \
  -NativeCAMSnapshotOut "$PWD/.build/snap" 2> .build/snap.log
grep -E 'check (PASS|FAIL)' .build/snap.log
```

**Never pass a plain file path to the app.** `NativeCAM job.nativecam` opens the file as a document in a window that waits for a person. Every path goes in as a `-Key value` pair, which AppKit reads as user defaults, not documents. Use absolute paths.

| Flag | What it does |
|---|---|
| `-NativeCAMSnapshotProject <path>` | The project (required) |
| `-NativeCAMSnapshotOut <dir>` | Where the PNGs go (required; made if missing) |
| `-NativeCAMSnapshotImport <file.dxf\|.svg\|.pdf>` | Imports vectors first, as **File ▸ Import** does, and logs each shape's layer. The project file isn't changed |
| `-NativeCAMSnapshotTemplate <template>` | Applies a template first, and draws the Apply Template sheet |
| `-NativeCAMSnapshotTemplateSetup YES` | …with its job setup |
| `-NativeCAMSnapshotTemplateMissing create\|skip` | …and what to do about missing layers |
| `-NativeCAMTemplatesFolder <dir>` | Where the Apply Template menu looks |
| `-NativeCAMSnapshotNest YES` | Nests every part first (300 layouts), checks the layout, draws `nest-sheet.png`, `nest-before.png`, `nest-after.png` (and `nest-after-sheet-2.png`…) |
| `-NativeCAMSnapshotNestLayouts n`, `-NativeCAMSnapshotNestSheets n` | …with `n` layouts, on up to `n` sheets |
| `-NativeCAMSnapshotInlay YES` | Makes an inlay pair from every closed vector first, draws the dialog (`inlay-sheet-*.png`) and the plug's inspector (`inspector-inlay-mismatch.png`) |
| `-NativeCAMSnapshotInlayBoundary margin\|vector\|board`, `-NativeCAMSnapshotInlayRaster YES` | …with that plug boundary, and raster flat clearing |
| `-NativeCAMSnapshotCalibration YES` | Saves the calibration programs to `calibration/` in the output folder and draws the sheet's tabs (`calibration-programs.png`, `calibration-fit.png`) |
| `-NativeCAMSnapshotSurfacing YES` | Builds and saves File ▸ Surface Spoilboard…'s programs (the whole bed, a 24 × 36 in board along Y one way) to `surfacing/` in the output folder, logs their checks, and draws the sheet (`surfacing-sheet.png`, `surfacing-sheet-custom.png`) and a refusal (`surfacing-sheet-refused.png`) |

**What it writes:** `window.png` (the whole window as the window server composites it, Metal viewport included), `sim-iso.png` and `sim-top.png` (the finished simulation), `toolpaths-iso.png`, `inspector-*.png` (Job Setup, each toolpath's inspector, the machine setup step), `tool-T*.png` (each bit's editor), `setup-sheet.html`, and, where they apply, `sim-turning.png`, `sim-tile-2.png`, `tiles-top.png`, `corners-op-*.png` and `rest-op-*.png`. The full list is in [Development](../development.md#developer-aids).

**What it logs** on stderr, each line starting `snapshot: `: the job's issues (`job info: …`, `job warning: …`), the export checks (`export check: 0 job errors, 0 G-code errors`), and self-checks as `check PASS: …` or `check FAIL: …`. **`check PASS: window.png is a real frame`** means the capture isn't blank. Without it, don't use the PNGs.

**`scripts/snapshot-check.sh`** runs snapshot mode on every project in [`scripts/snapshot-projects.txt`](../../scripts/snapshot-projects.txt), each line a project and its flags. It fails when a run's `window.png` isn't a real frame or any check fails. `--build` builds the app first. Output goes to `.build/snapshot-check/<project>/`. Run it before relying on snapshot screenshots in a PR or tutorial:

```text
$ scripts/snapshot-check.sh
PASS  examples/Demo Sign.nativecam
PASS  examples/Demo Pawn.nativecam
…
PASS  Tests/CAMCoreTests/Fixtures/projects/cut-direction-v27.nativecam
```

`scripts/capture-window.sh` is different: it captures the windows of an app that's already running, for a session a person is driving. Snapshot mode is the agent's way in.

## A checklist before hand-over

- [ ] `post` exited 0, without `--force`
- [ ] `Generated n toolpaths` is the count expected, and every toolpath has a time
- [ ] no `[error]` lines; every `[warning]` read, fixed or reported
- [ ] `sim` printed no `[error]`, and its removed volume is plausible
- [ ] the heightmap PNG (or snapshot) looks like the design
- [ ] units: `outputUnits` is what the human's controller runs in (the file's header says `G20` or `G21`)
- [ ] tools: every bit has its own number, and the setup sheet's load order matches what the human has
- [ ] for rotary jobs: the direction note and the centre-height note passed on
- [ ] for any controller other than Avid Mach4: said that its output hasn't been run on a real machine
- [ ] if code changed: `scripts/test.sh` passes, and any golden diff is explained
