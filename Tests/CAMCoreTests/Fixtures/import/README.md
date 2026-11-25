# Command-line import fixtures (#152)

Files `nativecam-cli import` reads in `CLIImportTests`, imported into `../projects/cli-import-target.nativecam` (24 × 18 × 0.75 in; a pocket finding layer “Pocket”, a drill finding “Holes”, a profile finding “Profile”, and a hand-picked V-carve on a drawn square). The command line's output for each case is in `../golden/cli-*.txt`.

| File | What it covers |
|---|---|
| `cli-two-layers-inch.dxf` | Layers “Profile” (a 6 × 4 in rectangle as four LINEs) and “Pocket” (2 × 2 in), `$INSUNITS = 1`: one shape per layer, both bound by layer |
| `cli-no-units.dxf` | The same drawing without `$INSUNITS`: refused without `--units`; with `--units mm` 25.4 times smaller and warned as under 1% of the material |
| `cli-points.dxf` | Four POINTs on layer “Holes”, inches: drill marks, bound by the drill |
| `cli-off-material.dxf` | A 4 × 3 in rectangle at (30, 30) in, off the 24 × 18 in material: refused with the file's coordinates, placed by `--center` |
| `cli-mm-part.svg` | `width="100mm"`, one Inkscape layer “Profile” holding an 80 × 40 mm rectangle: the SVG's own unit |
| `cli-cube-mm.stl` | A 10 mm cube with no unit: millimetres assumed, or `--units in` |
| `cli-cube.3mf` | A 20 mm cube, `unit="millimeter"`: the file's own unit, which `--units` doesn't change |
