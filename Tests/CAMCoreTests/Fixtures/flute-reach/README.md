# Flute reach fixtures

Saved projects for the reach of flutes that follow a 3D model (#203), written by NativeCAM's tests for
`FluteReachCatalogTests` (run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are never
replaced). The stickout error and the cutting-length warning count the stock still over the model under the flutes,
as well as the flute depth. Each has an Avid Mach4 golden in `../golden/`:

- `leg-flutes-before-finish.nativecam`: the turned leg from the flutes-on-a-model catalog in a 3.75" wrapped blank
  (25 to 35 mm of stock over it). Its flutes, cut with a 1/4" ball let out 1", are ordered before its 3D rotary finish.
  The bit would go about 35 mm down through the uncut stock, so Checks gives the stickout error and `post` refuses the
  file. Golden: `flute-reach-leg-before-finish.tap`.
- `leg-flutes-after-finish.nativecam`: the same, fluted after the finish. The finish has cleared the stock, so there's
  no error or warning (as before #203), and the flutes are the same moves either way. Golden:
  `flute-reach-leg-after-finish.tap`.
- `column-sunk-under-pocket.nativecam`: the column face sunk 0.9" into a 2" board under a 0.3" pocket, then fluted
  with the same 1"-stickout ball. The stock left over the column plus the flute depth is past the bit's 0.75" cutting
  length (a warning) but within its stickout (no error). Without the pocket it's the error. Golden:
  `flute-reach-column-sunk-under-pocket.tap`.
