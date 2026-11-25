# 3D holding-tab fixtures

Projects for holding tabs on 3D cut-outs (#173), written by NativeCAM's tests for `HoldingTabsCatalogTests` (run it
with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are never replaced). Each is a medallion model
(`medallionMesh`: a solid round or oval model with a domed or gently sloping top and straight walls) on 3/4" MDF, cut
round by 3D roughing and finishing with Selected vectors and cut out by an outside profile through the board with
tabs. Each test asserts what NativeCAM does with its file:

- `medallion-through.nativecam`: the model as deep as the board, four evenly spaced 3/8" × 1/8" tabs. Roughing and
  finishing leave a strip under each tab and cut to full depth elsewhere; no motion enters a strip below its top; the
  cut-out's tabs line up with the strips; the simulated part stays joined to the board after every toolpath and its
  tabs are 1/8" thick to within a cell. Goldens `rough3d-tabs-offset-inch` and `profile-3d-cutout-tabs-inch`; also
  used for rest finishing, the inspector line and the setup sheet's note.
- `medallion-adaptive.nativecam`: the same with adaptive roughing (golden `rough3d-tabs-adaptive-inch`).
- `medallion-raster-mm.nativecam`, `medallion-waterline-mm.nativecam`: raster and waterline finishing in mm (goldens
  `finish3d-tabs-raster-mm`, `finish3d-tabs-waterline-mm`).
- `medallion-placed.nativecam`: three tabs placed by hand; the strips are where they are (golden `3d-tabs-placed-inch`).
- `medallion-triangular.nativecam`: three triangular tabs; flat strips at their full height (golden
  `3d-tabs-triangular-inch`).
- `leads-tabs.nativecam`: the cut-out with arc leads; its entries land between the tabs, which still line up.
- `mismatch-entry-relative.nativecam`: three tabs. Cut as a plain 2D profile (spaced from its entry), they don't line
  up with the strips, which is an error; the job itself cuts them at the strips.
- Fallbacks to the whole-floor hold, each with the information line saying why:
  `material-boundary.nativecam` (Whole material), `applique-thin.nativecam` (a model edge 0.3 mm high, thinner than
  half the tab), `spike-tab.nativecam` (a tab placed on the narrow end of a 100 × 14 mm oval), `two-cut-outs.nativecam`
  (a second tabbed part within reach) and `undercut-cut-out.nativecam` (a dovetail cut-out, which leaves its tabs off).
- `tab-above-edge.nativecam`: a model edge 2 mm high, below the tabs' tops: strips, with a warning that the tabs stand
  proud.
- `medallion-shallow.nativecam`: the model's base above the tabs: nothing held, no strips, no note.
- `no-tabs-through.nativecam`: no cut-out: the finish reaching the bottom is still #166's warning.

The saved format-30 project is `../projects/3d-tabs-v30.nativecam`, with its golden `decoded-3d-tabs-v30`.
