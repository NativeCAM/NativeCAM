# Moulding fixtures

Inputs and edge cases for mouldings (#87), written for `MouldingCatalogTests` (run it with `NATIVECAM_UPDATE_GOLDENS=1`
to write a missing project; existing ones are never replaced). Each test asserts what NativeCAM does with its file:

- `moulding.svg`: the profiles and rails, one layer each, 100 user units per inch: an ogee 1.5 in across and 0.5 in
  tall, a cove 1.2 in across and 0.4 in tall, a closed shape, a 12 × 10 in rectangle (a picture frame's outside edge),
  an open gentle curve, an open L whose corner is rounded to 0.5 in, and a ring 0.6 in in radius. The goldens, the
  format-22 project and the edge cases are all made from it.
- `tight-inside-curve.nativecam`: the ogee inside the L's rounded corner, which is tighter than the ogee is wide. The
  profile is cut back there to about the corner's radius, Checks warns, both toolpaths cut, and the simulated result
  never goes below the swept surface.
- `wider-than-radius.nativecam`: the ogee inside the 0.6 in ring, so the profile is wider than the rail's radius all
  the way round. It's cut back to no more than the radius, nothing reaches past the centre, Checks warns, and nothing
  is gouged.
- `closed-profile.nativecam`: a closed shape chosen as the profile on the frame's rail. Refused: one empty toolpath,
  with a warning that the profile has to be an open cross-section.
