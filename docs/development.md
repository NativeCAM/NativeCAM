# Development

[← Back to the README](../README.md)

- [Project layout](#project-layout)
- [Tests](#tests)
- [Golden G-code](#golden-g-code)
- [Developer aids](#developer-aids)
- [Measuring toolpath changes](#measuring-toolpath-changes)
- [Test data from other projects](#test-data-from-other-projects)

## Project layout

```text
Sources/
  CAMCore/        The engine, pure Swift with no UI: geometry, model, importers, toolpaths, simulation, posts
  CClipper2/      Vendored Clipper2 2.0.1 (polygon offsetting) behind a small C bridge
  NativeCAM/      The SwiftUI app; Viewport/ is the Metal renderer (shaders compiled at runtime)
  nativecam-cli/  Command-line front end
Tests/CAMCoreTests/  Swift Testing suite and fixtures
examples/         Demo projects and the G-code they produce
docs/             These pages and the README images
scripts/          build-app.sh, test.sh, test-times.sh, capture-window.sh, snapshot-check.sh, make-icon.swift, measure/ (toolpath timing and part comparison)
```

Conventions inside `CAMCore`: all lengths are millimetres, design XY is relative to the material's lower-left corner, and Z = 0 is the material top. Posts convert to the chosen work origin and units. Each controller is described by a `Dialect` (what it accepts and how it reads files); `PostProcessors.post(for:)` picks the post for a project's machine, and `GCodeCheck` reads exported files back against the dialect.

## Tests

Run the test suite (Swift Testing):

```bash
scripts/test.sh
```

The script adds the compiler and linker flags Swift Testing needs when only the Command Line Tools are installed, and builds the tests optimized in their own folder (`.build/tests`), because the geometry and simulation run about 100× slower unoptimized. Extra arguments pass through to `swift test`, for example `scripts/test.sh --filter PostTests`. For a debuggable, unoptimized run, use `NATIVECAM_TEST_DEBUG=1 scripts/test.sh`.

The tests run in parallel, and the time printed for each one (`passed after … seconds`) runs from its `started` line to when its end is recorded. That includes the wait for a free thread before and after the test runs. While the long 3D and rotary tests hold every thread, that wait is most of the run, so nearly every test shows about the whole run's time. On GitHub's runners the log can also sit for minutes after a quick test's `started` line. To time one test, run it on its own by suite and name: `scripts/test.sh --filter NestingEngineTests/aPartFitsOnlyWhenItMayTurn`. The filter matches the suite's type name, not the file's, so `NestingTests/…` matches nothing. To find the slow ones, `scripts/test-times.sh` runs the suite one test at a time, so each time is the test's own, and lists the 20 slowest. It takes a count and `swift test` arguments, for example `scripts/test-times.sh 40 --filter Nesting`, and writes the whole log to `.build/test-times.log`.

GitHub Actions runs the same script, then `swift build` for the app and the command-line tool, on every pull request and every push to `main` ([`.github/workflows/tests.yml`](../.github/workflows/tests.yml)). It uses GitHub's Apple-silicon macOS 26 image with Xcode 26. When a golden file differs, the run keeps the new output as a `golden-actual` download on the run's page.

## Golden G-code

The golden-file tests (`GoldenPostTests` for the Avid Mach4 post, and one suite per other controller) compare posted files byte for byte, line endings included, with files in [`Tests/CAMCoreTests/Fixtures/golden/`](../Tests/CAMCoreTests/Fixtures/golden/):

- a hand-written job that reaches every branch of a post, under each machine setting
- the demo jobs end to end
- each controller's acceptance program
- project files saved by an earlier build ([`Fixtures/projects/`](../Tests/CAMCoreTests/Fixtures/projects/)), which must keep loading and posting the same bytes

Every golden file also has to pass the export checks. When a test fails, the new output is saved to `.build/golden-actual/`. If the change is intended, accept it with `NATIVECAM_UPDATE_GOLDENS=1 scripts/test.sh --filter GoldenPostTests` (or the relevant suite) and review `git diff Tests/CAMCoreTests/Fixtures` before committing. Saved project files are never regenerated: add a new one when the format changes.

## Developer aids

For checking UI changes without clicking through the app:

- **Offscreen snapshots.** `build/NativeCAM.app/Contents/MacOS/NativeCAM -NativeCAMSnapshotProject <project.nativecam> -NativeCAMSnapshotOut <dir>` renders the main window (`window.png`, as the window server composites it, so the Metal viewport and the sidebar's and inspector's materials are drawn: the window goes on screen for a moment, all but one column of points past the screen's right edge, and is captured again until the frame passes a check that its sidebar and inspector have drawn, logged as `check PASS: window.png is a real frame`), the finished simulation and the toolpaths to PNGs (and, for a rotary job, the blank half way through its first turn; for each toolpath with corner reliefs, the top view with it selected, so its corner marks show, `corners-op-*.png`; for each rest toolpath, the same with its rest areas shaded, `rest-op-*.png`), then quits. It also draws Job Setup, each toolpath's inspector and the machine setup assistant's setup step at full height (`inspector-*.png`), the Tool Library's editor for each bit the toolpaths use (`tool-T*.png`), and logs the job's checks, why each corner drawn in orange is flagged, and the export checks as **Export** would show them. On the demo sign it also runs a canvas interaction self-check (select, drag, marquee, nudge, copy/paste, delete). With `-NativeCAMSnapshotNest YES` it first nests every part as **Toolpaths ▸ Nest Parts…** does (a fixed 300 layouts, or `-NativeCAMSnapshotNestLayouts n`; up to the sheets last set, or `-NativeCAMSnapshotNestSheets n`), checks the layout with the parts' exact outlines and runs the sheet's live search, draws the sheet (`nest-sheet.png`) and the toolpaths from above before and after (`nest-before.png`, `nest-after.png`, and `nest-after-sheet-2.png` and so on for each further sheet, checking each sheet's file stays in the machine's travel), then snapshots the nested project. With `-NativeCAMSnapshotInlay YES` it first makes an inlay pair from every closed vector as **Add Toolpath ▸ Inlay…** does (`-NativeCAMSnapshotInlayBoundary margin|vector|board` picks the plug's boundary, `-NativeCAMSnapshotInlayRaster YES` has the V-bit clear the flats in raster lines), draws the dialog for each boundary (`inlay-sheet-*.png`) and the plug's inspector offering to update its pocket (`inspector-inlay-mismatch.png`), and logs each flat end mill's time on each side, the pair and its checks. With `-NativeCAMSnapshotCalibration YES` it saves the calibration programs for the project's machine as **File ▸ Calibration Programs…** does (to `calibration/` in the output folder), logs their checks, draws the sheet's Programs tab (`calibration-programs.png`), then fits times made up from slower settings and draws the Enter Times tab with the result (`calibration-fit.png`). Pass the paths as `-Key value` pairs; plain file arguments would be opened as documents.
- **Snapshot check.** `scripts/snapshot-check.sh` (`--build` builds the app first) runs snapshot mode on each project in `scripts/snapshot-projects.txt` (the demos, the JOY inlay fixture and the format-18 edge-profile project, with the flags each line gives) and fails when a run's `window.png` isn't a real frame or any check it logs fails. The PNGs and logs go to `.build/snapshot-check/`. Run it before relying on snapshot screenshots in a PR or tutorial; it isn't part of CI, which has no screen to draw on.
- **Window captures.** With the app running, `scripts/capture-window.sh` saves PNGs of its windows exactly as composited on screen to `~/Library/Caches/NativeCAM/Captures/`. Arguments put the front window in a state first, for example `scripts/capture-window.sh tag=sim simulate=0.5`, `select=op:0`, `tools=1`, `machinesetup=avid-pro6060:controller` or `vectricpp=/path/post.pp`; the script lists them all.
- **Icon and logo.** `scripts/make-icon.swift` draws the app icon, the README logo and the GitHub social preview from one piece of artwork: `swift scripts/make-icon.swift <iconset-dir> docs/images`, then `iconutil -c icns <iconset-dir> -o Resources/AppIcon.icns`.

## Measuring toolpath changes

- **Timing.** `scripts/measure/analyze.py job.tap` breaks a posted job down per toolpath (cutting and rapid length, retracts, plunges, segment sizes) and times it at constant velocity and with an acceleration model (15 in/s² by default; pass `--accel 50` to match NativeCAM's own estimate).
- **Drop-cutter speed.** `NATIVECAM_BENCH=1 scripts/test.sh --filter DropCutterBenchmark` times the demo relief's 3D finish (with its ball nose and with V-bits and a bull nose), the demo pawn's 3D rotary finish and both whole jobs, and writes the figures to `.build/dropcutter-bench.txt`. It's off in normal runs.
- **Nesting speed.** `NATIVECAM_BENCH=1 scripts/test.sh --filter NestingBenchmark` nests 52 parts (four sets of the shelf demo's, lettering, a star and an ellipse) on a 96" × 48" sheet and times the first layout and 2 s and 5 s searches, writing the figures to `.build/nesting-bench.txt`. It's off in normal runs.
- **Part comparison.** Simulate the before and after G-code with the same grid, `nativecam-cli sim job.tap --cell 0.25 --heights out.bin`, then `scripts/measure/compare_parts.py before.bin after.bin --ellipse cx cy rx ry` (or `--rect x0 y0 x1 y1`, in mm) reports how much of the finished part changed.

## Test data from other projects

Copy fixtures only from permissively licensed projects (MIT, BSD, Apache, Boost) and record the source in a `SOURCE.md` beside them. Tests for behaviour found in GPL or LGPL projects should be re-derived, not copied. Never commit vendor tool libraries or Vectric posts: they aren't licensed for redistribution, so tests use fixtures written for them.
