# Toolpath groups (#174)

Inputs for `ToolpathGroupsTests`. Groups and hiding change no cut, so these stay at the format of what's in them and aren't paired with `decoded-*` goldens. The saved project is `projects/toolpath-groups-v1.nativecam` (with `golden/decoded-toolpath-groups-v1.tap`); the other goldens are `golden/toolpath-groups-*.tap`.

Projects, each the demo sign with its toolpaths arranged in groups unless it says otherwise:

- `rest-across-groups.nativecam`: the slotted pocket in inches. Group "Rough" clears it with the 1/4" end mill; group "Rest" holds the 1/8" resting from it and the pocket taken deeper with the 1/4", whose links rapid down to the floor "Rough" cleared. Exporting "Rest" warns that it assumes "Rough" was cut and that the rest pass's reference isn't in the file; with full retracts no rapid goes below the material top. Goldens: `toolpath-groups-export-rest.tap` and `toolpath-groups-export-rest-full-retract.tap`.
- `hidden-included.nativecam`: the pocket and the cut-out hidden. They still generate, simulate and export, and the file is the same as with nothing hidden.
- `group-off.nativecam`: group "Inside" (the V-carve and the pocket) turned off with its checkbox. The checks and toolpaths are the same as with those toolpaths turned off one by one; exporting the group is refused, and with one member back on the checkbox is mixed and the other is left out.
- `cross-group.nativecam`: group "Outline" (the cut-out) runs before group "Detail" (the V-carve and pocket) and the ungrouped drill. Optimize Run Order keeps the order, and Checks says to move "Detail" and the ungrouped toolpaths before "Outline".
- `optimize-within.nativecam`: group "Lettering" (drill, V-carve, pocket), then group "Cut". Optimize reorders inside "Lettering" and keeps both groups whole, with a turned-off member staying in its group.

The tiled export reuses `restart/tiled.nativecam` with its last toolpath put in a group in the test.
