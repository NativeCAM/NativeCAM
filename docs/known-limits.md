# Known limits and roadmap

[← Back to the README](../README.md)

- Only Avid Mach4 output has run on a real machine. Every other controller's output follows its documentation (and, for Centroid, Avid's EX posts) and should be treated as unverified: [run the acceptance test](controllers.md#trying-a-new-controller-safely) in check mode where there is one, then air-cut.
- Run-time estimates use each controller's planner model and look-ahead, with acceleration from your controller's settings when you import them and labelled class defaults otherwise. They haven't been timed against a real machine yet.
- 3D finishing uses one raster direction per toolpath; add a second at 90° for cross-hatching. No waterline or pencil passes yet.
- V-bit and bull-nose 3D finishing use the height-grid drop-cutter; the exact triangle drop-cutter covers ball and flat bits only.
- PDF clipping masks and hidden layers aren't applied. EPS isn't supported.
- Clicking to select vectors in the 3D view isn't wired up yet; use the Design list in the sidebar.
- No nesting or plasma (THC) support yet.
- Leads keep clear of the shapes in their own toolpath, clamps and the material edge, but not of parts cut by other toolpaths. The T-bone side is chosen per toolpath, not corner by corner. A corner relief can break through a wall thinner than the bit's radius if the other side of it belongs to another toolpath.
- Rotary (4th-axis) work is indexed only, and only from project files so far. Profile, pocket and drill operations repeat at a list of angles on a round blank, or on a square bar at multiples of 90°. The posts turn the blank with `G00 A` at safe Z for Avid Mach4, LinuxCNC, grblHAL, Centroid and Buildbotics. There's no setup screen for rotary jobs yet, the simulation shows every face on one flat sheet, and V-carve, 3D and wrapped (continuous) rotary toolpaths aren't supported. Rotary projects are saved as format 3. Imported G-code with A words is simulated as if the part never turned, with a warning.
- Canned drill cycles (`G81`–`G83`) in imported G-code aren't simulated. NativeCAM's own output expands them, so its files simulate fully.

Bug reports, results from your own machine and code reviews are all very welcome.
