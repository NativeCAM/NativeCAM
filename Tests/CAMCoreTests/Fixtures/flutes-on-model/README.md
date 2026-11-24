# Flutes-on-a-model fixtures

Inputs and edge cases for flutes that follow a 3D model (#91), written by NativeCAM's tests for
`FlutesOnModelCatalogTests` (run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are never
replaced). Each test asserts what NativeCAM does with its file:

- `column.stl`: a column face 8 in long and 2.5 in wide, 0.5 in thick at its edges, its top a convex crown rising
  0.25 in along its length and 0.15 in across it (0.9 in at the middle), as a binary STL in mm written for these tests
  from `columnSTL()`. The flat golden, the format-25 project and the edge cases are cut on it.
- `runs-off-edge.nativecam`: a flute drawn past both ends of the column. It's cut only where the bit reaches the
  model, ramping in and out at its ends, Checks warns that it runs off the model's edge, and it never goes deeper than
  its depth below the drop-cutter surface.
- `missing-model.nativecam`: flutes set to follow a model that isn't in the job. Refused: one empty toolpath, with a
  warning that the model isn't in the job.
