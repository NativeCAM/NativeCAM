# Nest Parts' default spacing

Projects for `NestSpacingTests` (#193), written by `nativecam-cli` from the demo shelf (`nativecam-cli demonest`), with
nesting at seed 193 and 50 layouts. Nest Parts starts its spacing and edge margin at two widths of the bit cutting the
parts out plus 1/8 in (3 mm in a metric job). The spacing isn't saved in a project: only the parts' new places are.

- `shelf-unnested.nativecam`: the demo shelf as `demonest` writes it, cut out with a 1/4" end mill. Its default
  spacing is 0.625 in.
- `metric-shelf-unnested.nativecam`: the same in a metric job, cut out (and the hand hold cut) with a 6 mm end mill;
  the pin holes keep the 1/4" bit. Its default spacing is 15 mm.
- `shelf-nested-new-default.nativecam`: `shelf-unnested` nested at the default, 0.625 in. No tab is moved or lost.
- `metric-shelf-nested-new-default.nativecam`: `metric-shelf-unnested` nested at the default, 15 mm. No tab is moved
  or lost.
- `shelf-nested-old-default.nativecam`: `shelf-unnested` nested 0.375 in apart (`--spacing 0.375`), the default before
  #193 (one bit width and 1/8 in). It stands for a project nested and saved before: it opens with its parts where they
  were, 0.375 in apart, and #188 moves the tabs on facing edges along their loops.
