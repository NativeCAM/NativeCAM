---
family: controller
title: Controller and post
---
# Controller and post

Run your controller's test before any other. It cuts NativeCAM's **acceptance program** in scrap: a 40 mm square and circles of 1, 5, 10, 25 and 50 mm radius in all four quadrants with a 1/4 in end mill, a helix and a 3-second dwell with a 1/8 in end mill, and a tool change back to the 1/4 in bit with a long toolpath name. Everything is cut on the line, 0.5 mm (0.020 in) deep, on 300 × 200 mm (about 12 × 8 in) scrap zeroed at its lower-left corner and top.

It exercises what goes wrong between a CAM program and a controller: the **units**, **tool changes** and the touch-off after them, the **spindle** and its **dwell**, **arcs** in every quadrant and direction (including a helical arc), long **comments** and the **program end**. Unit errors show up in the sizes, arc errors in the circles' shapes, and re-zeroing errors in the depth after each tool change.

## The common procedure

Every controller page refers to these steps.

1. **Level 0.** Make the files with the page's command. Read the header and each tool change against the page's table. Load each file in the controller or sender: no errors.
2. **Check mode** where the controller has one (Grbl's `$C`): stream the file and expect no errors.
3. **Level 1.** Air-cut it 1 in (25 mm) above the scrap (`--air-cut` isn't available for the acceptance command: zero Z 1 in above the top instead). At each tool change, the program must stop for you, and continue only when you resume. Time the 3 s dwell.
4. **Level 3.** Zero on the scrap's top and lower-left corner, cut it, and measure:

| Feature (cut on the line, 1/4 in bit, 0.5 mm deep) | Target | Tolerance |
|---|---|---|
| 40 mm square: outside of the groove, X and Y | 46.35 mm (1.825 in) | ±0.13 mm |
| 40 mm square: inside of the groove, X and Y | 33.65 mm (1.325 in) | ±0.13 mm |
| 50 mm radius circle: outside diameter of the groove, in X and in Y | 106.35 mm (4.187 in) | ±0.13 mm; X and Y within 0.10 mm of each other |
| 25 mm radius circle: inside diameter of the groove | 43.65 mm (1.719 in) | ±0.13 mm |
| Groove depth, each tool (1st T1, T2 helix, 2nd T1) | 0.50 mm (0.020 in) | ±0.13 mm |
| Groove width (1/4 in bit) | 6.35 mm (0.250 in) | ±0.08 mm |
| Helix (1/8 in bit): a clean round groove, no flats or spirals off-centre | Round | — |
| Dwell at the helix's foot | 3.0 s | ±0.5 s |

A circle that comes out as a spiral, a flower or a straight-sided polygon means the controller read the arcs differently (I/J incremental or absolute, or the arc tolerance). A circle 25.4 times too big or too small means a units error. A depth that differs after a tool change means the re-zero didn't take.
