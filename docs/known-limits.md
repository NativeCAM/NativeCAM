# Known limits and roadmap

[← Back to the README](../README.md)

- Only Avid Mach4 output has run on a real machine. Every other controller's output follows its documentation (and, for Centroid, Avid's EX posts) and should be treated as unverified: [run the acceptance test](controllers.md#trying-a-new-controller-safely) in check mode where there is one, then air-cut.
- Run-time estimates use each controller's planner model and look-ahead, with acceleration from your controller's settings when you import them and labelled class defaults otherwise. They haven't been timed against a real machine yet.
- 3D finishing uses one raster direction per toolpath; add a second at 90° for cross-hatching. No waterline or pencil passes yet.
- V-bit and bull-nose 3D finishing use the height-grid drop-cutter; the exact triangle drop-cutter covers ball and flat bits only.
- EPS isn't supported. A PDF clipping mask made from live text isn't applied; convert the text to outlines first.
- No nesting or plasma (THC) support yet.
- Leads keep clear of the shapes in their own toolpath, clamps and the material edge, but not of parts cut by other toolpaths. A corner's own relief choice is tied to its place on the shape: change the shape so that corner moves (resize a rectangle, say) and the choice no longer applies, and Checks says so. A corner relief can break through a wall thinner than the bit's radius if the other side of it belongs to another toolpath.
- Rotary (4th-axis) work is indexed or wrapped ([Rotary jobs](using-nativecam.md#rotary-jobs)). Indexed: profile, pocket and drill operations repeat at a list of angles on a round blank, or on a square bar at multiples of 90°, and the posts turn the blank with `G00 A` at safe Z for Avid Mach4, LinuxCNC, grblHAL, Centroid and Buildbotics. Wrapped: profile and drill operations wrap around a round blank, fed in inverse time (`G93`) for Avid Mach4, LinuxCNC and grblHAL; Mach4's `G93` isn't tested on a machine yet. Wrapped pockets, V-carving and rounding aren't supported yet, and a wrapped job simulates on its unrolled sheet. Only an A axis along X is supported. The simulation turns an indexed blank at a nominal 90° a second, and the run-time estimate doesn't count the turns yet, or time wrapped moves by the tool tip's path. 3D rotary toolpaths aren't supported. Rotary projects are saved as format 3, and wrapped ones as format 4. Imported G-code with A words is simulated as if the part never turned, with a warning; its `G93` moves are timed by their F words.
- Tapping and boring cycles (`G74`, `G76`, `G84`, `G87`, `G88`) in imported G-code aren't simulated. Drilling cycles are.

Bug reports, results from your own machine and code reviews are all very welcome.
