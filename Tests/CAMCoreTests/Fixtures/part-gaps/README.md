# Parts closer than the cut reaches

Projects for `PartGapTests` (#186), written by NativeCAM (run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one;
existing ones are never replaced). An outside cut reaches its bit's width (plus any allowance) out from each wall, so a
part nearer than that is cut into. Each test asserts what NativeCAM does with its project:

- `parts-under-bit-width.nativecam`: two 3 × 2 in parts 0.24 in apart, one outside profile with a 1/4" end mill.
  Refused, naming both parts and the gap.
- `parts-at-bit-width.nativecam`: 0.25 in apart, exactly the bit's width. The kerfs meet but cut into neither part, so
  it's cut.
- `parts-over-bit-width.nativecam`: 0.26 in apart. Cut.
- `parts-at-bit-width-with-allowance.nativecam`: 0.26 in apart with a 0.02 in allowance, so the cut reaches 0.27 in.
  Refused.
- `part-into-pocket.nativecam`: a cut-out 0.15 in from a pocket another toolpath cuts. The cut-out is refused, naming
  the part and the pocket's toolpath. The pocket isn't.
- `part-clear-of-pocket.nativecam`: the same 0.3 in apart. Both are cut.
