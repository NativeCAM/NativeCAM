# Step flicker fixtures

Projects for 3D finishing passes that run along a step in the cutter-location surface (#208), used by
`StepFlickerTests`. A bit's radius from the top edge of a vertical wall, which side of the step the tool goes on turns
on a micron: the material round a model is a grid of points, so a ball a hair inside that radius of a wall of it catches
each point and drops between them, and a pass there sawed up and down the wall every grid cell. Each file is one of the
nativecam.org moulding tutorial's picture frames: a 12 × 10 in rectangle rail on 16 × 14 in hard maple, the 1.5 in ogee
from `../moulding/moulding.svg`, roughed with a 1/4" end mill and finished at a constant scallop with a 1/4" ball nose at
a 10% stepover. Since #205 their outline is exact, so their edges fall on the finishing grid (0.0125 in cells, the
ball's radius ten of them).

- `frame-flipped.nativecam`: the ogee flipped, inside the rail, so its deep side is on the rail, a 1/2 in wall down from
  the uncut wood round the frame. Its finish sawed along two rails (612 moves up or down the wall, 19:42). Now it doesn't,
  takes under 12:30, keeps the frame's extents (X 2.0125–13.9875 in, Y 2.0124–11.9875 in), and, simulated, cuts nothing
  below the swept surface or into the wood round the frame and in its opening.
- `frame-outside.nativecam`: the ogee outside the rail (385 saws, 20:02 before). Now it doesn't saw, takes under 15:30,
  and keeps its extents.
- `frame-inside.nativecam`: the ogee inside the rail, the plain frame, which never sawed: its finish takes what it did
  (11:40).

The website's mirrored frame posts the same G-code as the flipped one, so it has no file of its own.
