# Inside and on-line cuts near other parts

Projects for `PartGapInsideTests` (#190), written by NativeCAM (run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a
missing one; existing ones are never replaced). An inside cut reaches its bit's width (plus any allowance) in from the
hole's wall. An on-line cut reaches a bit radius either side of its line. Each test asserts what NativeCAM does with its
project; all use a 1/4" end mill.

A 6 × 6 in frame with a 3 × 3 in hole cut by an inside profile, and a 2.4 × 2.4 in part nested in the hole, cut out by
its own outside profile, its left edge `gap` from the hole's wall:

- `nested-part-under-bit-width.nativecam`: 0.24 in. The hole's cut is refused, naming the hole, the nested part's
  toolpath and the gap. So is the nested part's cut-out, naming the hole's toolpath; the frame's isn't.
- `nested-part-at-bit-width.nativecam`: 0.25 in, exactly the bit's width. Nothing is refused.
- `nested-part-over-bit-width.nativecam`: 0.26 in. Nothing is refused.

A 3 in groove cut on the line, `gap` from the edge of a pocket another toolpath cuts:

- `line-into-pocket.nativecam`: 0.115 in, inside the bit's radius. The groove is refused, the pocket isn't.
- `line-at-bit-radius-from-pocket.nativecam`: 0.125 in. The bit only touches the pocket's wall, but the check keeps
  0.1 mm clear of a part from the material side, so it's refused.
- `line-clear-of-pocket.nativecam`: 0.135 in. Cut.

Two 3 × 2 in rectangles cut on the line by one profile, `gap` apart:

- `lines-under-bit-width.nativecam`: 0.24 in. Refused, naming both and the gap.
- `lines-at-bit-width.nativecam`: 0.25 in. Cut.
- `lines-over-bit-width.nativecam`: 0.26 in. Cut.
