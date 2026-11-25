# Finishing-pass edge cases

Projects for a profile's separate finishing pass (#157), written by NativeCAM for `FinishingPassCatalogTests` (run it
with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are never replaced). Each test asserts what
NativeCAM does with its project:

- `outside-full-depth-conventional.nativecam`: a 120 × 80 mm part cut out with a 0.5 mm full-depth conventional
  finish. The finishing loop sits r off the wall and the roughing r + 0.5 mm, by closest point; the finish runs the
  other way from the climbing roughing, in one lap at the cut depth.
- `inside-hole-finish.nativecam`: a 2" hole finished 0.02" in inches. The walls are on the hole's side and the finish
  runs clockwise (conventional inside).
- `tabs-survive-finish.nativecam`: five tabs and arc leads. Wherever the roughing lifted over a tab, the finish beside
  it is at or above the tab top, and in the simulated material the strip only the finish cuts is still at tab height
  in the middle of every tab.
- `finish-lead-in-kerf.nativecam`: a 1/4" arc lead with a 1/8" bit. The finish's lead is cut down to the kerf, and its
  plunge and every move stay between the finished wall's and the roughing's offsets, with no warning.
- `finish-without-leads.nativecam`: no leads. The finish enters on an automatic arc in the kerf, not on the wall.
- `allowance-too-large.nativecam`: a 3.3 mm finish allowance on a 1/4" bit (over half its width). Refused: nothing is
  cut, and the job has an error starting "Refused:", so `post` won't write it.
- `allowance-heavy.nativecam`: 2.5 mm (over a third of the bit's width). Cut, with a warning.
- `full-depth-past-flutes.nativecam`: a full-depth finish 19.55 mm deep with 12.7 mm flutes. Refused, suggesting Each
  pass (which the test then cuts).
- `on-line-finish-skipped.nativecam`: an On profile with a finish. Skipped with a warning; the G-code is the same as
  without it.
- `dovetail-finish-skipped.nativecam`: a dovetail bit with a finish. Skipped with a warning.
- `inside-finish-only-refused.nativecam`: a 6.8 mm hole where the 1/4" bit's finishing offset fits but the roughing's
  doesn't. That loop is refused with an error, and nothing is cut.
- `tiled-finish-skipped.nativecam`: a tiled job. The finish is skipped with a warning.
- `spring-pass.nativecam`: a spring pass at 80% feed. The lap runs twice at the finish feed, written once as F.
- `adjust-feeds-excludes-finish.nativecam`: Adjust Feeds for Load on. The finish laps keep their feed, and the usual
  cut is the same as for the roughing alone.
- `rest-start-depth-finish.nativecam`: a profile after a pocket that cleared the top 6 mm, finished each pass. The
  finish starts below the pocket's floor and still reaches the cut depth.
