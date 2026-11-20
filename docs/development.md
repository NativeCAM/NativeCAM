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
scripts/          build-app.sh, test.sh, capture-window.sh, make-icon.swift, measure/ (toolpath timing and part comparison)
```

Conventions inside `CAMCore`: all lengths are millimetres, design XY is relative to the material's lower-left corner, and Z = 0 is the material top. Posts convert to the chosen work origin and units. Each controller is described by a `Dialect` (what it accepts and how it reads files); `PostProcessors.post(for:)` picks the post for a project's machine, and `GCodeCheck` reads exported files back against the dialect.

## Tests

Run the test suite (369 tests in 41 suites, using Swift Testing):

```bash
scripts/test.sh
```

The script adds the compiler and linker flags Swift Testing needs when only the Command Line Tools are installed, and builds the tests optimized in their own folder (`.build/tests`), because the geometry and simulation run about 100× slower unoptimized. Extra arguments pass through to `swift test`, for example `scripts/test.sh --filter PostTests`. For a debuggable, unoptimized run, use `NATIVECAM_TEST_DEBUG=1 scripts/test.sh`.

## Golden G-code

The golden-file tests (`GoldenPostTests` for the Avid Mach4 post, and one suite per other controller) compare posted files byte for byte, line endings included, with files in [`Tests/CAMCoreTests/Fixtures/golden/`](../Tests/CAMCoreTests/Fixtures/golden/):

- a hand-written job that reaches every branch of a post, under each machine setting
- the demo jobs end to end
- each controller's acceptance program
- project files saved by an earlier build ([`Fixtures/projects/`](../Tests/CAMCoreTests/Fixtures/projects/)), which must keep loading and posting the same bytes

Every golden file also has to pass the export checks. When a test fails, the new output is saved to `.build/golden-actual/`. If the change is intended, accept it with `NATIVECAM_UPDATE_GOLDENS=1 scripts/test.sh --filter GoldenPostTests` (or the relevant suite) and review `git diff Tests/CAMCoreTests/Fixtures` before committing. Saved project files are never regenerated: add a new one when the format changes.

## Developer aids

For checking UI changes without clicking through the app:

- **Offscreen snapshots.** `build/NativeCAM.app/Contents/MacOS/NativeCAM -NativeCAMSnapshotProject <project.nativecam> -NativeCAMSnapshotOut <dir>` renders the main window, the finished simulation and the toolpaths to PNGs, then quits. On the demo sign it also runs a canvas interaction self-check (select, drag, marquee, nudge, copy/paste, delete). Pass the paths as `-Key value` pairs; plain file arguments would be opened as documents.
- **Window captures.** With the app running, `scripts/capture-window.sh` saves PNGs of its windows exactly as composited on screen to `~/Library/Caches/NativeCAM/Captures/`. Arguments put the front window in a state first, for example `scripts/capture-window.sh tag=sim simulate=0.5`, `select=op:0`, `tools=1`, `machinesetup=avid-pro6060:controller` or `vectricpp=/path/post.pp`; the script lists them all.
- **Icon and logo.** `scripts/make-icon.swift` draws the app icon, the README logo and the GitHub social preview from one piece of artwork: `swift scripts/make-icon.swift <iconset-dir> docs/images`, then `iconutil -c icns <iconset-dir> -o Resources/AppIcon.icns`.

## Measuring toolpath changes

- **Timing.** `scripts/measure/analyze.py job.tap` breaks a posted job down per toolpath (cutting and rapid length, retracts, plunges, segment sizes) and times it at constant velocity and with an acceleration model (15 in/s² by default; pass `--accel 50` to match NativeCAM's own estimate).
- **Part comparison.** Simulate the before and after G-code with the same grid, `nativecam-cli sim job.tap --cell 0.25 --heights out.bin`, then `scripts/measure/compare_parts.py before.bin after.bin --ellipse cx cy rx ry` (or `--rect x0 y0 x1 y1`, in mm) reports how much of the finished part changed.

## Test data from other projects

Copy fixtures only from permissively licensed projects (MIT, BSD, Apache, Boost) and record the source in a `SOURCE.md` beside them. Tests for behaviour found in GPL or LGPL projects should be re-derived, not copied. Never commit vendor tool libraries or Vectric posts: they aren't licensed for redistribution, so tests use fixtures written for them.
