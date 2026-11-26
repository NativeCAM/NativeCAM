---
title: About this handbook
---
# About this handbook

## Purpose

NativeCAM writes program files (G-code, or OpenSBP for ShopBot) for hobby and prosumer CNC routers. Its own checks read every file back before it's saved, and its test suite compares its output, byte for byte, with known-good files. None of that proves that **your** machine, running **your** controller, cuts what NativeCAM meant. Only a real cut does.

This handbook gathers every real-machine test the project needs into one place, so that any user can:

- check that NativeCAM's files run correctly on their own machine and controller before trusting them with good material;
- find out which features work in their setup, and which don't yet;
- report what they found in a form the developers can act on.

## Scope

It covers every controller NativeCAM writes for (Avid Mach4, the Grbl family, LinuxCNC, Masso, Centroid CNC12, Buildbotics, ShopBot and RichAuto) and every kind of toolpath it makes: profiles, pockets, drilling, corner reliefs, V-carving and inlays, chamfers and edge profiles, 3D roughing and finishing, nesting and tiling, rotary work, restarts, calibration programs and spoilboard surfacing.

It doesn't cover the design side (drawing, importing), the app's windows, or how to build your machine. It assumes you can already run a program on your machine safely: zero it, change a bit, and stop it.

> **Status today.** Only the **Avid Mach4** profile's output has run on a real machine, and only its basic toolpaths. Nearly every test in this book is marked *Not yet run on a real machine*. Your results are what change that.

## How to use it

1. Read **Safety first** and **What you need**. Get the materials and bits on the shopping list.
2. Prepare the machine as **Preparing the machine** describes.
3. Run the **controller test** for your controller first (the *Controller and post* family). Nothing else is worth cutting until it passes.
4. Run the **basics** (read-back, air cut, setup sheet).
5. Then pick the families you use. Within a test, always work up the levels in order: **0** read the file, **1** air cut, **2** shallow cut in foam or MDF, **3** full cut. Stop at the first level that fails.
6. Write what you measured in the test's **Results** box, and copy the outcome to the **Results log** at the back.
7. Report failures (and passes, especially on controllers other than Avid Mach4) as **Reporting a result** describes.

Every test has an ID such as `VH-PRF-01`, shown in the page header. Quote it in reports.

## The test kit

The kit lives in the NativeCAM repository, under `docs/validation/`:

| Path | What it is |
|---|---|
| `NativeCAM-Validation-Handbook.pdf` | This book (US Letter); `…-A4.pdf` is the A4 edition |
| `projects/` | The test projects (`.nativecam`), one or more per test |
| `handbook/` | The book's source, in Markdown |
| `build-kit.sh` | Rebuilds every program, setup sheet, image and both PDFs |
| `images/` | The simulated heightmaps printed on the test pages |

The programs themselves aren't in the repository, since they depend on your machine and controller. Make them yourself, in either of two ways:

- **In the app.** Open the project, choose your machine under **Material & Machine** (the projects are set up for the default Avid PRO6060 on Mach4), check the material size, and choose **File ▸ Export G-code** (**⌘E**). **File ▸ Export Air Cut…** (**⌥⌘E**) and **File ▸ Export Setup Sheet…** make the air cut and the setup sheet.
- **On the command line.** Each test prints the exact `nativecam-cli` commands, run from the repository folder. Build the CLI once with `swift build -c release --product nativecam-cli` and put `.build/release` on your `PATH`, or write the full path. The commands use the project's own machine (the Avid PRO6060 on Mach4); for another machine, change it in the app first and save a copy, or, for the controller tests, use `--controller`.

`docs/validation/build-kit.sh` runs every command in this book and rebuilds the PDFs. The output printed on each test page comes from that run.

## Units

The projects are in inches unless their name ends in `-mm`. Where size matters, a test gives both. A program's units are those of the machine's **G-code units** setting, not the project's display units: check the header of every file (Level 0 does).
