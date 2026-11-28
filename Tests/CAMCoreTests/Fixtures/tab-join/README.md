# Tab join fixtures

Projects for how far a 3D cut-out's tab stands proud of the model where its strip joins it (#209), used by
`TabJoinTests` (run it with `NATIVECAM_UPDATE_GOLDENS=1` to write a missing one; existing ones are never replaced). The
tab is measured against the lowest the model is across the band from its outline to half a millimetre in, read off the
model's own surface, rather than one sample half a millimetre in, which landed wherever it did on a steep edge.

- `steep-edge.nativecam`: the medallion job of `../3d-tabs` (3/4" MDF, four 3/8" × 1/8" tabs on the cut-out) with a
  solid round model whose sides lean 5° off vertical out to its foot at the board's bottom. Half a millimetre in from
  the foot the model is 5.7 mm up, above the tabs' 3.175 mm tops, so the probe saw nothing; at the foot each tab stands
  its whole height proud: it warns that the four tabs stand up to 0.1246 in proud, with the strips (and the G-code) as
  before.

The tests also use `../part-hold/deep-relief.nativecam` (the demo relief made 0.75 in deep, cut out on four tabs, which
warns that its tabs stand up to 0.0934 in proud) and `../3d-tabs/tab-above-edge.nativecam` (its 2 mm rim, now 0.0462 in
under the tabs' tops).
