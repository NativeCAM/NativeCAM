---
title: Reporting a result
---
# Reporting a result

Every result helps: a pass on a controller other than Avid Mach4 is as valuable as a failure, since it's what moves a controller or a feature from "not yet run" to tested.

## Where

Open an issue on the NativeCAM repository on GitHub: **github.com/NativeCAM/NativeCAM/issues**. One issue per test that failed; one issue can list several passes.

## What to include

- **The test ID** (for example `VH-PRF-01`) and the level that failed, in the title: "VH-PRF-01 Level 3: outside square 0.012 in oversize on Grbl 1.1h".
- **The file you ran**, attached (the `.tap`, `.nc`, `.sbp` …), and the project if you changed it.
- **`post`'s output**, or the app's Checks, word for word.
- **Your setup:** machine, controller and version, sender, units, how tools change, NativeCAM build. The sign-off sheet's first table has it all.
- **What happened**, and the line number the controller showed, if it stopped.
- **Measurements**: the test's pass-criteria table, filled in.
- **Photos**: the part with the calipers on it, the controller's screen, the setup.

## Safety findings

If a program crashed into something, cut into the finished part, cut deeper than asked, or ran wrong G-code (wrong units, a missing tool change, a dwell in the wrong unit, a rapid through material), say so in the title with the word **safety**. These are fixed before anything else.

> **Warning.** Don't run the file again to "see if it happens twice". Keep the file and your notes exactly as they were.

## Privacy

Leave out anything personal from the files and photos you attach: names in file paths, serial numbers, your address. The G-code header holds the project's name and the machine's model, nothing else.
