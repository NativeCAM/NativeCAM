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
