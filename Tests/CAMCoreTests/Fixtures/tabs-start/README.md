# Tabs and start-point edge cases

Projects for the edge cases of a profile's tabs placed by hand, triangular tabs and chosen start points (#167), written
by NativeCAM for `TabsStartPointCatalogTests` (run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one;
existing ones are never replaced). Each test asserts what NativeCAM does with its project:

- `orphaned-after-resize.nativecam`: four tabs placed on a 120 mm rectangle since made 100 mm wide. The two on its sides
  are now 10 mm off it, so they're left off the cut with a warning (and drawn in orange where they were); the two on
  its top and bottom slide onto the new outline and are cut. All four stay in the file.
- `all-tabs-removed.nativecam`: tabs placed by hand, every one removed, on a cut through the material. Checks warns
  the cut frees the part, nothing is lifted, the part-hold checks count no tabs, and the setup sheet lists none.
- `start-inside-tab.nativecam`: the chosen start is on a placed tab. The loop starts half a bit diameter past the tab's
  end, with a note, and the tool never steps down onto the tab.
- `start-no-lead-room.nativecam`: two parts 7 mm apart, the start chosen on the side facing the other. No lead fits
  there, so the entry moves along the loop to where one does, a note gives the distance, and no move comes closer to
  either part than the bit's radius.
- `triangular-ball-fallback.nativecam`: triangular tabs with a ball nose. They're cut rectangular, with a warning; the
  moves are the rectangular tabs' exactly.
- `triangular-steep.nativecam`: triangular tabs 0.1" long and 0.2" thick, a 76° ramp. Checks warns, and every move down
  off a tab keeps its vertical speed to the plunge rate.
- `tabs-overlap.nativecam`: two tabs placed closer than one tab's span. They merge into one lift.
- `tab-too-long-for-hole.nativecam`: a 3/4" tab on a hole 16 mm across, too long for the loop with the bit's width. It's
  left off with a warning.
- `tabs-on-inside-profile.nativecam`: placed tabs on an inside cut. They hold the waste piece inside the hole (the tool
  lifts over both), and there's no "cut free" warning.
- `tab-cleared-earlier.nativecam`: a pocket run first cuts below the tabs' top where one placed tab sits. That tab is
  flagged and Checks warns it's thinner than set there.
- `nest-rotated.nativecam`: a part turned 30° with placed tabs and a chosen start, then nested. The marks follow the
  part, before and after nesting.
- `tiled-tab-on-seam.nativecam`: a placed tab straddling a tile line. The tile split keeps the lift on both sides of the
  break, so the tab is cut whole, half in each tile.
- `edge-profile-reaches-placed-tabs.nativecam`: a cove run before a cut-out whose tabs are placed by hand (the count is 0).
  Checks warns the cove reaches the tabs; with every placed tab removed it doesn't.

For `KerfsTouchTabsTests` (#182): a 6 × 4 in lid and a 3 × 1 in divider above its back edge, cut by one outside profile
with a 1/4" end mill, four tabs placed on the lid's sides and front and two on the divider's edge facing the lid. Each
tab goes on its own part's loop and is marked on its own part, and the bridge under each of the divider's tabs isn't cut
away:

- `kerfs-overlap-under-bit-width.nativecam`: the parts 0.24 in apart, the kerfs overlapping. The lid's loop lifts over
  the divider's two tabs too, with a note.
- `kerfs-touch-at-bit-width.nativecam`: 0.25 in apart, one bit width, so the two loops coincide along the gap. The same.
- `kerfs-overlap-over-bit-width.nativecam`: 0.26 in apart, still under two bit widths, so the lid's kerf would cut the
  divider's tabs away. The same.
- `kerfs-apart-over-two-bit-widths.nativecam`: 0.51 in apart. Each loop keeps its own tabs, with no note.

Evenly spaced tabs (four per loop) on the same lid and divider. A tab whose bridge another part's kerf would cut moves
along its loop to where none does, with a note, and every tab is left whole:

- `even-tabs-kerfs-overlap-under-bit-width.nativecam`: 0.24 in apart.
- `even-tabs-kerfs-overlap-over-bit-width.nativecam`: 0.26 in apart.
- `even-tabs-just-under-two-bit-widths.nativecam`: 0.49 in apart, just inside the reach of the lid's kerf.

A 2.5 × 2 in part off centre in a frame's 3.25 × 2.75 in hole: 0.275 in from the hole on two sides and 0.475 in on the
others, so every stretch of its loop is closer than two bit widths to the hole's:

- `surrounded-part-placed-tabs.nativecam`: tabs placed by hand. The hole's loop lifts over the part's tabs, so they
  join the part to the frame. Held, with no tab cut away.
- `surrounded-part-two-even-tabs.nativecam`: two evenly spaced tabs. There's nowhere clear to move them, and the hole's
  kerf cuts both away, so the part would come free. Refused, with an error.
- `surrounded-part-four-even-tabs.nativecam`: four evenly spaced tabs. One is left whole, so the part is held, with a
  warning that the others are cut away.
