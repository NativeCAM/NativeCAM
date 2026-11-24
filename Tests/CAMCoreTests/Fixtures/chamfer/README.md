# Chamfer edge cases

Projects for the edge cases of the chamfer's overcut and round-nose chamfers (#90), written by NativeCAM for
`ChamferCatalogTests` (run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are never
replaced). Each test asserts what NativeCAM does with its project:

- `overcut-reaches-next-shape.nativecam`: two plaques 0.3" apart, each chamfered round its top 1/8" wide with a 0.04"
  overcut, so each flat would reach past the midline between them. Checks warns that the overcut reaches the next
  shape; both are still chamfered.
- `overcut-laps-stepped.nativecam`: the board's top chamfered 1/4" wide with a 0.04" overcut by a 90° V-bit set to a
  0.02" stepdown (#121). The bevel takes 13 passes; each of the 6 laps' strips is bigger than the bevel's first pass,
  so the laps are stepped too, but in only 5 passes each, cut only outside the bevel's foot.
- `roundnose-too-wide.nativecam`: a 1/4" roundover asked for a round-nose chamfer 5/16" wide, more of the profile than
  the bit has. Refused, saying so, and nothing is posted for it.
- `dovetail-refused.nativecam`: a chamfer with a 1/2" dovetail. Refused, saying it's a dovetail bit and to use a Profile
  toolpath, and nothing is posted for it.
