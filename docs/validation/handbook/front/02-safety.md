---
title: Safety first
---
# Safety first

A CNC router is a powerful machine with a sharp, fast-spinning bit, and a test file is by definition a file nobody has proved yet. Treat every first run as if it could do the wrong thing.

> **Warning.** NativeCAM's developers have not run most of these programs on a real machine. A test exists because something is unproven. Follow every step below, every time.

## Rules for every test

- [ ] **Air cut first.** Run every new program in the air before it touches material: raise Z (an air-cut export raises every Z for you) and watch the whole program. Only then cut.
- [ ] **Scrap stock.** Cut tests in MDF, rigid foam or scrap plywood, never in good material.
- [ ] **Eye and hearing protection.** Safety glasses always; hearing protection whenever the spindle or router runs. A dust mask or respirator when cutting MDF.
- [ ] **E-stop within reach.** Stand where you can hit the emergency stop without moving. Know where your feed hold and spindle stop are, and how your controller resumes.
- [ ] **Never leave a running machine.** Stay at the machine, watching, for the whole program, including air cuts.
- [ ] **Clamps clear of the toolpaths.** Check each clamp and screw against the setup sheet and the air cut. Keep hands clear of the bed while the machine can move.
- [ ] **Check the setup sheet.** Before each run, compare the setup sheet with the machine: material size and thickness, XY and Z zero, the bit in the collet and its number, the run order and tool changes.
- [ ] **Bit and collet.** Use sharp bits in a clean collet, tightened properly, with the stickout the project expects. A bit that slips in the collet cuts deeper than asked.
- [ ] **Dust collection on**, and nothing loose on the bed.
- [ ] **Know the stop.** Before Cycle Start, have a finger near feed hold. If anything looks wrong (wrong place, wrong height, wrong direction, a rapid toward material), stop first and think after.

## Before the first cut of each program

1. Read the file's header (Level 0): units, tools, extents, zero.
2. Simulate it in NativeCAM, or in your controller's preview.
3. Air-cut it with Z raised at least 1 in (25 mm) above the material.
4. Cut it shallow in foam or MDF (Level 2) before a full-depth cut (Level 3).

## Things the machine owner must do, never software

- Decide whether a file is fit to run. NativeCAM writes files; it never sends them to a machine.
- Measure the machine: rotary centre height, turn speed and direction, real tool lengths, travel and soft limits. Never type in a number you didn't measure.
- Run calibration programs and spoilboard surfacing, and time them.

## When something goes wrong

Press E-stop or feed hold. Don't restart until you know why it happened. Note the line number the controller shows, take a photo, and keep the file: they're what a report needs (see **Reporting a result**).
