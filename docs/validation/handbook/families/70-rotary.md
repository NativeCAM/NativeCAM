---
family: rotary
title: Rotary jobs
---
# Rotary jobs

Only for machines with a rotary axis (or an indexer turned by hand). Rotary work has the most unknowns, and the most ways to crash: the chuck and tailstock stand above the bed, the blank's corners swing higher than its faces, and a wrong direction mirrors everything.

> **Warning.** Do **VH-ROT-01** (which way +A turns) and **VH-ROT-02** (does `G93` run correctly) before any other rotary test, and before any rotary cut of your own. Measure the rotary's centre height above the spoilboard and set it under **Material & Machine ▸ Rotary Axis**, so NativeCAM can check the job fits under the Z travel. Never guess the direction, centre height or turn speed.

The kit's rotary projects assume the axis runs along X with the chuck at X−, zeroed with X0 at the chuck end of the blank, Y0 on the axis and Z0 **on the axis** (the centre line), as the setup sheet says. Rotary axes mounted along Y are supported for Avid Mach4, LinuxCNC and grblHAL: set **Alignment** to along Y and redo VH-ROT-01 (along Y, +A should roll the top toward +X).

Wrapped jobs and 3D rotary jobs are fed in inverse time (`G93`) for Avid Mach4, LinuxCNC and grblHAL only. Grbl, FluidNC, Carbide Motion and Masso can run indexed jobs turned by hand; ShopBot and RichAuto files can't turn the blank at all.
