# Borrowed SVG fixtures

Copied unmodified (only renamed with a `path-` / `transform-` prefix) from **linebender/resvg**,
which is dual-licensed MIT OR Apache-2.0; used here under the MIT License (see `LICENSE-MIT` in this folder).

- Repository: https://github.com/linebender/resvg
- Commit: `433d0213a98d611793d105e08e141325e13720e3`

| File here | Original path |
| --- | --- |
| `path-M-A-trimmed.svg` | `crates/resvg/tests/tests/shapes/path/M-A-trimmed.svg` |
| `path-invalid-data-in-L.svg` | `crates/resvg/tests/tests/shapes/path/invalid-data-in-L.svg` |
| `path-no-commawsp-before-arc-flags.svg` | `crates/resvg/tests/tests/shapes/path/no-commawsp-before-arc-flags.svg` |
| `path-no-commawsp-between-and-after-arc-flags.svg` | `crates/resvg/tests/tests/shapes/path/no-commawsp-between-and-after-arc-flags.svg` |
| `path-numeric-character-references.svg` | `crates/resvg/tests/tests/shapes/path/numeric-character-references.svg` |
| `transform-matrix-no-commas.svg` | `crates/resvg/tests/tests/structure/transform/matrix-no-commas.svg` |
| `transform-nested-transforms-1.svg` | `crates/resvg/tests/tests/structure/transform/nested-transforms-1.svg` |
| `transform-rotate-at-position.svg` | `crates/resvg/tests/tests/structure/transform/rotate-at-position.svg` |
| `transform-zeroed-matrix.svg` | `crates/resvg/tests/tests/structure/transform/zeroed-matrix.svg` |

Most of these files draw a plain reference shape ("should be covered") and the same shape written with the
tricky syntax under test; `SVGImportTests` checks that the two import to the same geometry.
