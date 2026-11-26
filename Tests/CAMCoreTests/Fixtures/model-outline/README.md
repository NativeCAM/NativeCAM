# Model outline fixtures

Meshes for a 3D model's exact outline from above (#202), written by NativeCAM's tests for `ModelOutlineCatalogTests`
(run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are never replaced). All are binary STLs
in mm. Each test asserts what NativeCAM does with its file:

- `disc-r60-256.stl`: a 256-sided disc, its corners at R 60 mm, 12 mm thick (`discSTL`). Every vertex lies inside or on
  its outline, and an outside profile with a 1/4" end mill keeps the bit's edge on or outside the disc's polygon. The
  traced outline this replaced put it 0.13 mm inside. Golden: `model-outline-disc-r60-mm.tap`. Three of them also nest
  with Nest Parts with the job's checks clean.
- `disc-r205-720.stl`: a 720-sided disc, its corners at R 205.74 mm, 3/4" thick. Its outline is one loop with exactly
  the polygon's area and every corner at the disc's radius; the outside profile keeps the bit's edge on or outside it
  (the traced outline put it 0.50 mm, 0.020", inside). Golden: `model-outline-disc-r205-inch.tap`.
- `open-sheet.stl`: an open mesh, a domed sheet 80 × 50 mm with no walls or bottom, every other row of triangles
  wound the other way and an 8 × 10 mm hole through it. Its outline is the 80 × 50 rectangle with the hole, exactly.
- `relief.stl`: a relief 200 × 150 mm on a 120 × 120 grid (about 30,000 triangles) with a wavy edge, walls and a
  bottom. Every vertex lies inside or on its outline. A 254 × 254 version of it (132,000 triangles, built by the test,
  not saved) times the outline.
