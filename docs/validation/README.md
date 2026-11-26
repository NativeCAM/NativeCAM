# NativeCAM Validation Handbook

[← Back to the README](../../README.md)

**[Download the handbook (PDF, US Letter)](NativeCAM-Validation-Handbook.pdf)** · [A4 edition](NativeCAM-Validation-Handbook-A4.pdf)

A printable test manual that any NativeCAM user can follow on their own machine and controller, to check that the files NativeCAM writes cut correctly. Each test has an ID (`VH-PRF-01` and so on), the project it cuts, the exact `nativecam-cli` commands that make its program, the setup, step-by-step instructions in four levels (read the file, air cut, shallow cut, full cut), measurable pass criteria with tolerances, what failure looks like, and a results box. Only Avid Mach4 output has run on a real machine so far: results from other controllers are especially welcome ([how to report one](handbook/back/03-reporting.md)).

## What's here

| Path | What it is |
|---|---|
| `NativeCAM-Validation-Handbook.pdf`, `…-A4.pdf` | The built handbook |
| `projects/` | The test projects. Each is built by `tools/make-projects.py` from a project the CLI wrote (`new`, `demo`, `demo3d`, `demosheets`), a saved project from `Tests/CAMCoreTests/Fixtures/`, or an example; `nst-parts-nested.nativecam` is `nst-parts.nativecam` after `nativecam-cli nest` |
| `images/` | The simulated heightmap on each test page (`nativecam-cli sim --png`, greyscale) |
| `handbook/front/`, `handbook/back/` | The front and back matter, in Markdown |
| `handbook/families/` | One page per test family, which the family's tests follow |
| `handbook/tests/` | One file per test: a front matter block (ID, family, levels, stock, bits, projects, the commands it prints) and the page's body |
| `build-kit.sh` | Rebuilds everything below |
| `tools/` | The build scripts: `make-projects.py`, `run-kit.py`, `build-handbook.py` with `handbook.css`, and `render-pdf.swift` |

## Rebuilding

```bash
docs/validation/build-kit.sh                 # projects, programs, images and both PDFs
docs/validation/build-kit.sh --no-projects   # keep projects/ as committed
```

It needs only the Command Line Tools (Swift, Python 3 and macOS's own WebKit and PDFKit), and it writes files only: it never talks to a machine.

1. Builds `nativecam-cli` (or uses `$NATIVECAM_CLI`).
2. Writes `projects/` (`tools/make-projects.py`). IDs are derived from names, so a rebuild writes the same files.
3. Runs every command the test pages print, into `build/out/` (G-code, setup sheets, calibration and surfacing programs), and records what each printed in `build/kit-results.json`. Each test page prints that output, so every warning a project raises is on its page. **It stops if any `post` exits non-zero or prints an `[error]`**: nothing in the kit is written with `--force`.
4. Builds the handbook's HTML and renders both PDFs with `tools/render-pdf.swift` (two passes, so the contents' page numbers are real; running headers carry each page's test IDs).

`build/` isn't committed: the programs depend on the machine and controller you choose, so make your own from the projects (the commands are on each test page) or with the app's **Export**.

## Adding a test

1. Add or derive its project in `tools/make-projects.py`, from CLI output or a fixture, never from hand-written vectors or meshes. Keep it on small stock (12 × 12 in, 300 × 300 mm or less).
2. Add `handbook/tests/NN-XXX-NN.md`, copying an existing test's front matter. `commands` are run exactly as printed; `manual` lines are printed but not run; `images` lists projects to draw.
3. Run `build-kit.sh` and read the page: every warning `post` printed is shown on it.
