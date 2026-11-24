# Rest-machining edge cases

Projects for the edge cases of 3D rest finishing and pocket rest from earlier toolpaths (#83), written by NativeCAM
for `RestCatalogTests` (run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are never
replaced). Each test asserts what NativeCAM does with its project:

- `reference-smaller.nativecam`: a 1/4" ball rest pass whose named reference finishes with a 1/8" ball. Refused,
  saying the rest bit isn't smaller than the reference's, and nothing is posted for it.
- `nothing-left.nativecam`: a gentle cap finished inside its outline with a 1/4" ball, then a tapered-ball rest pass.
  The ball reaches all of it, so the rest pass is empty, says there's nothing left to cut, and posts nothing.
- `reference-disabled.nativecam`: a rest pass whose named reference is turned off. Checks says it still assumes the
  reference was cut, and the rest areas are worked out as if it had been.
- `reference-runs-later.nativecam`: a rest pass that runs before its named reference. Checks says so, and Optimize Run
  Order puts the reference first.
- `pocket-nothing-left.nativecam`: a 1/8" pocket resting from a 1/4" one on a round pocket the 1/4" reaches all of. The
  rest toolpath is empty, says there's nothing left to cut, and posts nothing.
