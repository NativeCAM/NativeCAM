# Restart files (#156)

Inputs for `RestartTests`. They're at the current format and not paired with `decoded-*` goldens, because a restart saves nothing in the project. The goldens are `golden/restart-*.tap`.

Projects:

- `sign.nativecam`: the demo sign as `nativecam-cli demo` writes it, with a 0 s spin-up dwell, so every restart of it warns. It's used for:
  - the toolpath start;
  - a line inside an arc;
  - a line on a minimum-retract link;
  - the air cut;
  - the running-file comparison;
  - every pass boundary;
  - points past the end.
- `pocket-ramp.nativecam`: a ramped 3/8" pocket in two levels and a drilled hole, inch, with a 2 s dwell. It's used for:
  - the pass restart with its stop;
  - the exact restart in mm;
  - the router's speed-dial reminder;
  - no stop;
  - every pass boundary;
  - the command line.
- `wrapped-rounding.nativecam`: a 50 mm square bar rounded over many turns (wrapped, G93), then an indexed slot on the top face. It's used for an exact restart mid-G93 and for the slot's start after the rounding.
- `wrapped-rectangle.nativecam`: a wrapped pocket on the 50 mm dowel. It's used for every pass boundary, and posted on LinuxCNC and grblHAL.
- `by-hand-grbl.nativecam`: the table leg on Grbl with its rotary turned by hand, a file per tool. The restart asks for the blank's angle first.
- `split-per-tool-grbl.nativecam`: the demo sign on Grbl, a file per tool. The restart is only the T1 file.
- `tiled.nativecam`: a sheet in four tiles with registration dowels. The dowel stop is kept at the toolpath's start and dropped mid-toolpath.

Hand-built toolpaths, for refusals no generator writes, on the sign's stock:

- `exact-into-material.toolpaths.json`: a rapid sideways at depth leaves material uncut, so an exact restart at the next feed would plunge into it. Refused; snapped back, it's fine.
- `rapid-into-material.toolpaths.json`: the second pass rapids down into uncut material. The restart's approach is refused.

The rotary job on a Vectric post (refused), the calibration refusal and the 3D finish (the demo relief) are built in the test, from the rounding job with the tests' own Vectric-style post, `Calibration.timing` and `Project.demoRelief()`. A rotary job saved with a Vectric post would trip the fixture-wide travel check, since that post writes the unrolled sheet's Y.
