# Finishing-pattern fixtures

Inputs and edge cases for constant scallop, spiral and radial 3D finishing (#88), written by NativeCAM's tests for
`FinishingPatternsCatalogTests` (run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are
never replaced). Each test asserts what NativeCAM does with its file:

- `coin.stl`: a coin 30 mm across and 3.2 mm thick (a bump in the middle, a flat field, a raised rim with a chamfer and
  a 1.6 mm vertical edge), as a binary STL written for these tests from `coinProfile()`. The goldens and the format-21
  project are cut on it.
- `boundary-with-hole.nativecam`: the coin inside its outline with a 4 mm circle over its bump, so the boundary is a
  ring, finished by all three patterns. Each stays out of the hole and inside the outline and cuts all round the
  ring; the spiral's centre (the ring's centroid) is in the hole, so it starts at the hole's edge, with no warning.
- `vertical-wall.nativecam`: a round boss with a 6 mm vertical wall, finished by constant scallop. The passes don't
  pile up at the wall's foot (slopes past 75° count as 75°), Checks doesn't warn of bunching, and nothing cuts into
  the boss.
- `spiral-centre-outside.nativecam`: a spiral on the coin whose picked centre is outside the boundary. It's clamped to
  the nearest point on the boundary, with a warning giving both points, and the spiral starts there and stays inside.
