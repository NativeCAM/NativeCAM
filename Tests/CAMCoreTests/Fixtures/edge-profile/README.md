# Edge-profile edge cases

Projects for the edge cases of the Edge Profile toolpath (#84), written by NativeCAM for `EdgeProfileCatalogTests` (run
it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are never replaced). Each test asserts what
NativeCAM does with its project:

- `tabs-reached-after-cut-out.nativecam`: a 1/2" cove 0.7" deep run after a through cut-out whose 1/8" tabs reach up to
  0.645" below the top. Checks warns that it reaches the tabs, and Optimize Run Order puts it before the cut-out.
- `inside-corner-sharper.nativecam`: a 1/4" roundover round a board with a square notch in its top edge. The notch's two
  inside corners are sharper than the bit can follow, which Checks notes as information; the edge is still profiled.
- `dovetail-refused.nativecam`: an edge profile with a 1/2" dovetail. Refused, saying it's a dovetail bit and to use a
  Profile toolpath, and nothing is posted for it.
- `hole-too-small.nativecam`: a 3/8" cove round a board's outside and two holes, one 0.4" across, too small for its
  1/2" pilot. That hole is skipped with a warning; the other hole and the outside are cut.
