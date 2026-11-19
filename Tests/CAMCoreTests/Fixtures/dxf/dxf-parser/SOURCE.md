# Borrowed DXF fixtures

Copied unmodified from **gdsestimating/dxf-parser** (MIT License, see `LICENSE` in this folder):

- Repository: https://github.com/gdsestimating/dxf-parser
- Commit: `0df7a37a4207a1f925b8d0bfffc270ff121446b4`
- Path in the repository: `test/data/`

| File | What it exercises in `DXFImportTests` |
| --- | --- |
| `arc1.dxf` | Real-world ARC with extrusion (0,0,-1), no HEADER section |
| `arcs-as-splines.dxf` | Closed periodic rational quadratic SPLINEs (exact circles) and an open rational arc |
| `splines.dxf` | Cubic SPLINEs with control points + fit points, and one with 22 control points / double knots |
| `ellipse.dxf` | ELLIPSEs whose axis ratio is greater than 1 and whose end parameter is 6.283185 (not exactly 2π) |

The expected values in the tests are computed from the files' own data, not from dxf-parser's JSON output.
