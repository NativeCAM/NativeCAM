# Bit-shape edge cases

Projects for the edge cases of the tapered ball nose, form and dovetail bits (#82), written by NativeCAM for
`BitShapeFixtureTests` (run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are never
replaced). Each test asserts what NativeCAM does with its project:

- `dovetail-past-flutes.nativecam`: a dovetail cut deeper than its flutes. It cuts once at full depth, the check warns
  that the depth exceeds the cutting length, and the leads off the wall allow for the narrower shank's overhang.
- `zero-taper.nativecam`: a tapered ball nose with a 0° taper (in fluting and a profile) and a dovetail with no angle.
  Every toolpath refuses them, saying why, and cuts nothing.
- `form-heights-go-down.nativecam`: a custom form profile whose heights go down. Refused, saying to list the points
  from the tip up.
- `form-narrows.nativecam`: a custom form profile that narrows going up (not monotonic in radius). Cut like a dovetail:
  one pass at full depth, tabs left off, and leads off the wall at least its undercut long.
