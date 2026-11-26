---
title: Preparing the machine
---
# Preparing the machine

Measurements in this book are only as good as the machine they're cut on. A test that fails on an out-of-square machine says nothing about NativeCAM. Check these first, and write down what you found on the sign-off sheet.

## Squaring

Cut or draw a large square (or use the acceptance test's 40 mm square, scaled up if you like) and measure both diagonals. They should agree within 0.010 in (0.25 mm) over 12 in. If they don't, square the gantry as your machine's maker describes before going further.

## Tramming

A spindle that isn't square to the bed leaves ridges between passes and makes flat floors dish. Read tram with **VH-SRF-01** (a one-way surfacing pass across a 12 × 12 in board), or with a dial indicator on a sweep arm. Adjust to your machine maker's tolerance.

## Spoilboard

- Flat and freshly surfaced if you can (see **VH-SRF-02**). Through-cuts in the kit go 0.020 in (0.5 mm) into it.
- No screw heads within 1/8 in (3 mm) of any cut. Check the setup sheet's extents.
- Thickness: note it. Surfacing refuses to leave less than 1/2 in (12 mm).

## Calibrated steps

Cut the acceptance test (the *Controller and post* family) and measure its 40 mm square and 100 mm circle. If X or Y is off by more than 0.1%, correct your controller's steps per unit before judging any other test.

## Work zero and units

- **XY zero:** every kit project is zeroed at the **lower left** corner of the material unless its page says otherwise (the setup sheet always says).
- **Z zero:** the **top of the material**, set with a touch plate at each tool change, unless the page says otherwise (spoilboard surfacing zeroes on the spoilboard).
- **Units:** check that your controller is in the units the file's header says (`G20` inches, `G21` millimetres; ShopBot checks its own unit setting). A file in the wrong units cuts 25.4 times too big or too small.

## Your machine in NativeCAM

The projects carry the default machine, an Avid PRO6060 on Mach4. If yours is different:

1. In NativeCAM, **Settings ▸ Machine ▸ Set Up a Machine…** walks through your machine, controller, units, tool changes and spindle, and saves it to your machine library.
2. Open each kit project, choose your machine under **Material & Machine**, and save the project under a new name (keep the originals as they are).
3. If your controller can export its settings (`Machine.ini`, Grbl `$$`, a LinuxCNC INI, a FluidNC `config.yaml`), import them in the machine's **Motion** section, so run-time estimates use your real speeds.

## Record the setup

On the **Sign-off** sheet, write: machine model and size, controller and its version, the program that sends files (Grbl senders), spindle or router, G-code units, how tools change, and the NativeCAM build (**NativeCAM ▸ About NativeCAM**, or the commit). Every result depends on them.
