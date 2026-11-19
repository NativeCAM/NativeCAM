# Plan: lead-in/lead-out moves and dogbone/T-bone corners

## Context

Cabinet and furniture users ask for two missing options most often (both are listed as missing in `docs/known-limits.md`):

1. **Leads.** Today a profile plunges or ramps straight onto the finished wall and lifts off it at the end of the loop. That leaves a dwell mark where it starts and ends. A lead-in starts each loop with a short move in the waste: a tangent arc or a straight line. A lead-out ends it the same way. The bit never stops against the finished edge.
2. **Corner reliefs.** An end mill leaves a fillet of its own radius in every inside corner, so square tenons, tabs and finger joints don't fit. A dogbone cuts a little past each corner along its bisector. A T-bone cuts past it along one wall, so the notch can be put where it won't show.

Both options are off by default. When off, they must leave every golden file in `Tests/CAMCoreTests/Fixtures/golden/` byte-identical. Rotary code is not touched.

The user decided two points while this plan was drafted:
- Corner reliefs also apply to **outside** profiles (finger joints, slot-together notches, holes in a part).
- The T-bone side is chosen **per toolpath**. Picking it corner by corner is a later follow-up, since it needs corner picking on the canvas.

## How other CAM programs present them

- **Vectric** (Profile ▸ Leads): "Straight Line Lead" takes an Angle and a Lead length. "Circular Lead" takes a Radius and a Lead length. There is a "Do lead out" switch and an "Overcut Distance" that runs past the start point. The help page says leads avoid dwell marks from plunging on the edge. The ramp page has a "Ramp on Lead In" option, and ramps repeat at each level. Vectric's dog-bone and T-bone are **drawing-time fillets** on the vectors. Its T-bone goes "automatically on the longest side" unless you click a side. The help warns against dog-bones when the slot is about the width of the bit.
- **Fusion 2D Contour** (Linking tab): Lead-in and lead-out each take a horizontal radius, a sweep angle, a linear distance and a "Perpendicular" switch. There is a "Same as lead-in" option and a "Finishing overlap".
- **Carveco / ArtCAM**: Linear leads take a distance and an angle (45° in their example). Circular leads take a distance and a radius. ArtCAM turns a lead that would cross the profile into a linear move.
- **FreeCAD's dogbone dressup** (LGPL; I read only its public option names and re-derive everything else) offers Dogbone and T-bone horizontal, vertical, long-edge and short-edge styles, plus per-corner tags.

NativeCAM follows these names: Arc or Line, Radius and Sweep, Length and Angle, Lead out, Overlap. It does the relief **on the toolpath** rather than on the vectors, so the design stays clean and the relief always matches the bit actually used.

## 1. Leads (profiles, inside and outside)

### Geometry

All lead geometry is worked out on the tool-centre loop the profile already builds.
- At the entry point P, t is the direction of travel. The waste side n is to the left when climbing and to the right when conventional. That follows from the generator's rule that climb keeps the wall on the right, so it holds for inside cuts, outside cuts, holes and islands alike.
- **Arc lead-in:** an arc of radius R and sweep φ (default 90°, allowed 15–180°) on the circle centred at P + R·n. It is run in the same rotational sense as the cut, ending tangent at P.
- **Arc lead-out:** the mirror image, leaving Q, where Q is P plus the overlap along the loop.
- **Line lead-in:** A = P − ℓ·cos α·t + ℓ·sin α·n, with α between 10° and 90° and a default of 45°.
- **Line lead-out:** B = Q + ℓ·cos α·t + ℓ·sin α·n.
- Both kinds are flattened to `context.arcTolerance`. `ArcFitter` turns the arcs back into G2/G3 when the machine takes arcs; a ramp along an arc becomes a helical arc, which is already supported.
- There is no lead on "On" profiles, which have no waste side, or on open vectors. The toolpath gets a note instead.

### Clearance test (new `ToolCentreClearance`, shared with the pass links)

A lead or link is sampled every min(0.25 mm, r/4). It is clear when every sample passes all four checks:
1. **On the waste side.** For an inside cut the sample is inside this toolpath's tool-centre regions (the `offsetRegions` already computed). For an outside cut it is outside all of them. Either way, 0.01 mm on the boundary is allowed. Because the test covers every loop in the toolpath, it also keeps leads off neighbouring parts, out of islands and off nested parts.
2. **On the material.** The sample is within the material bounds grown by the tool radius. That is the margin `CAMEngine.validate` already allows, so a lead never triggers "extends beyond the material edges".
3. **Clear of clamps.** The sample is at least r from every keep-out outline. `GenerationContext` gains `keepOuts`, filled by `CAMEngine` from the list it already builds.
4. **Over cleared material, where an earlier toolpath did the cutting.** When the rest-aware start has lowered the first pass, the material under the sample (`context.materialTop` at full tool radius) must be no higher than the pass the lead belongs to. This stops a finishing profile from slotting through uncut waste at full depth. The lead shrinks until it fits in the roughing kerf instead.

### Choosing the entry point

- The cut-order search is unchanged: it still uses the nearest loop points, and a lead moves the start and end by at most 2R.
- At cut time, `startingNearest` is replaced by "the nearest point where a lead fits":
  1. Candidates are the nearest point, then points about R apart along the loop in both directions, up to 64.
  2. Vertices turning more than 10° are skipped unless nothing else fits.
  3. Each candidate is tried at R or ℓ, then at halved sizes, but not below max(0.5 mm, r/4).
- If no candidate fits, the loop is cut without a lead. The warning reads "Leads didn't fit on N loop(s); they're entered without one."

### Passes, ramps, tabs

- With leads on, the entry point stays the same on every pass, so each pass's lead cuts exactly one stepdown deeper. Today's ramp moves its start around the loop each pass. That behaviour is kept exactly when leads are off: it lives in a new `cutClosedWithLeads`, and `cutClosed` is left untouched.
- **Plunge entry:**
  1. Plunge at A, in the waste.
  2. Run the lead-in at depth z, then the lap from P past P by the overlap, then the lead-out to B.
  3. If another pass follows and the straight line B→A is clear and no longer than the link optimiser's stay-down limit (max(3 × diameter, 10 mm)), feed back along it at z and feed down one pass at A.
  4. Otherwise retract and re-enter at A. `LinkOptimizer` turns that into a minimum lift.
- **Ramp entry:**
  1. The ramp walks the lead-in first, then the wall. It starts at A at the previous floor and descends over the ramp length measured from A.
  2. A full lap at depth follows, from the end of the wall part of the ramp, then the lead-out.
  3. The tool links back to A at the same depth, so a clear link means no plunge at all. If the ramp length is no longer than the lead, the whole descent is on the lead, matching Vectric's "Ramp on Lead In".
  4. If the link isn't clear, the tool lifts and drops in at A, a one-pass plunge in the waste.
- **Tabs:** they keep their spacing from P. The overlap is clamped so the exit stays clear of the first tab. Leads sit in the waste, so they never cross a tab.

### Edge cases

| Case | Behaviour |
|---|---|
| Small hole, tight gap between parts, concave stretch | The clearance test rejects the spot, then the entry moves or the lead shrinks. If nothing fits, there is no lead and the loop is counted in the warning. |
| Part flush with the material edge | Leads there would leave the material bounds, so the entry moves to another side. |
| Holes before outside, nested parts | Order unchanged. Holes in a part lead into the hole; a part inside another part's hole leads into the gap between them. |
| Climb or conventional | The waste side and the arc sense flip together: G3 lead arcs when climbing, G2 when conventional. |
| Lead out off | The lap ends on the wall. The link to the next pass is the straight line Q→A. The last pass lifts off at Q, as today. |
| Parts cut by a *different* toolpath | Not known to this generator. This goes in the documented limits: put parts that sit close together in one profile, or use a smaller lead. |

## 2. Corner reliefs (profiles inside and outside; pockets)

**Which corners.** A corner is a vertex C of a tool-centre loop that turns toward the waste side. The corner angle θ is 180° minus that turn, which is also the angle of the cut-away wedge: a square mortise or an L-shaped notch both measure 90°. The relief applies when θ is at or below **Corners up to**, which defaults to 120°: squares and hexagons are relieved, while octagons and faceted curves are not. Turns split over vertices less than 0.05 mm apart count as one corner, which covers tiny chamfers from imports.

The same rule covers several cases:
- the corners of an inside cut;
- the inside corners of an outside cut: finger joints, slot-together notches, and the holes in a part;
- the inside corners of islands in pockets and inside cuts.

Sharp corners only arise where the bit can't follow, because Clipper's round joins smooth the corners it can reach.

**Find the drawn corner.** Let w be the unit bisector pointing into the corner, proportional to d_in − d_out, and let o = r + allowance. Cast a ray from C along w against the toolpath's own design loops, before any offset. It hits the drawn corner H at distance h. The corner is relieved only if all three hold:
- h ≤ o / sin(θ/2) + 0.01. A hit farther away means a pinch between separate features, such as an island near a wall, not a real corner.
- h − o ≥ 0.01. If not, the bit already reaches the corner, as with a corner rounded at or above the bit radius.
- The design points nearest the tool edges just before and just after C lie on H's loop, within 2o / sin(θ/2) of H along it. This rejects narrow inlets of a single loop.

**Dogbone.** The loop gains a spike C → D → C, with D = C + (h − o)·w, so the bit just touches H. At a sharp corner the cut goes r(1 − sin(θ/2)) past each wall: 0.29 r at 90°. A rounded corner smaller than the bit gets a shallower relief, because H is the deepest drawn point.

**T-bone.** The spike runs along one wall's tool line to T = C + ((H − C)·e)·e, where e is either d_in or −d_out. The notch lands in the *other* wall: a half circle o deep at 90°. **T-bone side** chooses which wall gets it:
- Longer side (default, as Vectric does);
- Shorter side;
- Sides along X;
- Sides along Y.

Wall length is measured as the straight run (within 2°) on each side of the corner. The side is picked from the walls, not the direction of travel, so climb and conventional cut identical reliefs.

**Gouge guard.** The spike is sampled. If any design segment outside the corner's own stretch of loop (within 2o/sin(θ/2) + 2o of H) is closer than o − 0.01, the corner is left alone. The warning reads "N corner(s) weren't relieved: the relief would cut into nearby geometry."

**Where it applies.**
- **Profiles:** every contour, inserted after the start point is chosen, so a plunge or a lead never lands on a relief tip. If the start happens to be a relieved corner, its spike comes first.
- **Pockets:** only the wall ring at each depth, meaning the outermost ring and its island rings, plus the raster clean-up loops. Inner clearing rings are untouched.
- **"On" profiles:** skipped, with a note.

| Case | Behaviour |
|---|---|
| Very acute (30° or less) | Still relieved, as asked. The spike grows as 1/sin(θ/2) and the T-bone notch approaches 2r. The gouge guard catches reliefs that would reach other walls. The docs say to check the preview. |
| Slot barely wider than the bit | Dogbones overlap at each end, which works. The UI caption recommends T-bones there, following Vectric's advice. |
| Allowance | The relief stops `allowance` short of the corner, matching what a later finishing pass would relieve. |
| Tapered bits | The relief is sized for the bit at the cut depth, as the profile already is. |
| Thin wall between two corners in other toolpaths | Not detectable here, so it goes in the documented limits. |

## 3. Interactions

- **Links (`LinkOptimizer`):** unchanged. Entries are still rapids followed by a straight-down feed at A. Leads, links between passes and reliefs are all feeds, carved into the material model like any cut.
- **Cut order (`TourOptimizer`):** unchanged, as described under "Choosing the entry point". Holes-before-outside nesting is unchanged.
- **Run order (`OperationScheduler`):** unchanged. Leads stay in each part's own waste, and reliefs stay within the shape bounds plus r.
- **Rest-aware start (profiles):** it also samples the relief tips. A corner an earlier toolpath didn't reach forces passes from the top, rather than cutting a full-depth sliver. Leads aren't sampled; they must pass clearance check 4 instead.
- **Simulator, preview, Result panel:** nothing to change, because they draw and time the motions.
- **Run-time estimates:** no change needed. Leads add feed length, and each dogbone tip is a full reversal that the junction-deviation model already brings to a stop.
- **Export checks (`GCodeCheck`):** nothing special; tests confirm the new output passes.

## 4. Settings and file compatibility (`Sources/CAMCore/Model/Operation.swift`)

```swift
public enum LeadKind: String, Codable, Sendable, CaseIterable, Identifiable { case arc, line }
public struct LeadSettings: Hashable, Codable, Sendable {
    var kind: LeadKind = .arc
    var radius = 0.25.inch    // arc
    var sweep = 90.0          // arc, degrees, 15...180
    var length = 0.25.inch    // line
    var angle = 45.0          // line, degrees to the cut, 10...90
    var leadOut = true
    var overlap = 0.0         // last lap runs this far past its start before leading out
}
public enum CornerReliefStyle: String, Codable, Sendable, CaseIterable, Identifiable { case dogbone, tBone }
public enum TBoneSide: String, Codable, Sendable, CaseIterable, Identifiable { case longer, shorter, alongX, alongY }
public struct CornerReliefSettings: Hashable, Codable, Sendable {
    var style: CornerReliefStyle = .dogbone
    var tBoneSide: TBoneSide = .longer
    var maxCornerAngle = 120.0  // degrees; a square corner is 90
}
// ProfileParams: leads: LeadSettings? = nil, cornerRelief: CornerReliefSettings? = nil
// PocketParams:  cornerRelief: CornerReliefSettings? = nil
```

- nil means off. These are new trailing init parameters with nil defaults, so every existing call site still compiles: the V-carve and 3D-rough `PocketParams`, the demo projects and the sidebar's new-operation defaults.
- Older files load, because synthesised Codable decodes optionals with `decodeIfPresent`. Projects that don't use the options are written exactly as today, because nil keys are omitted. The `decoded-*` goldens and the saved fixtures are unaffected.
- **No format bump.** An older build opening a file that uses these options ignores them and cuts without leads or reliefs. That loses fit and finish, but isn't a safety problem, unlike posting for the wrong controller. Leaving the format alone also keeps format 3 free for the rotary work.
- When the user switches an option on, the UI seeds the lead radius or length from the tool diameter.

## 5. UI wording (`Sources/NativeCAM/OperationInspector.swift`)

**Leads** section (Profile):
- Picker **Lead**: None | Arc | Line (segmented).
- For Arc: **Radius**, and **Sweep** in degrees.
- For Line: **Length**, and **Angle** in degrees, with the help text "Angle between the lead and the cut; 90° comes in square to it".
- Toggle **Lead out**.
- **Overlap**, with the help text "How far the last lap runs past its start before leading out, to hide the seam".
- Caption: "Each loop starts and ends with a short move in the waste, so the bit never plunges or stops against the finished edge. Ramps run along the lead."
- With Side set to On, the section shows only: "Leads need an inside or outside cut."

**Corners** section (Profile and Pocket):
- Picker **Inside corners**: Rounded | Dogbone | T-bone (segmented).
- For T-bone: **T-bone side**: Longer side | Shorter side | Sides along X | Sides along Y.
- **Corners up to** in degrees, with the help text "A square corner is 90°. Flatter corners are left rounded."
- Caption: "Cuts just past each inside corner the bit can't reach, so square parts fit. A dogbone cuts into the corner; a T-bone cuts into one side only, which is easier to hide and better for slots about as wide as the bit."

## 6. Files

| File | Change |
|---|---|
| `Sources/CAMCore/Model/Operation.swift` | Settings above |
| `Sources/CAMCore/Toolpath/Leads.swift` (new) | Lead geometry, entry search, `ToolCentreClearance` |
| `Sources/CAMCore/Geometry/CornerRelief.swift` (new) | Corner detection, validation, dogbone and T-bone spikes, insertion (follows the pattern of `CornerFillet.swift`) |
| `Sources/CAMCore/Toolpath/ProfileGenerator.swift` | `cutClosedWithLeads`, reliefs, rest-aware sampling, warnings |
| `Sources/CAMCore/Toolpath/PocketGenerator.swift` | Reliefs on wall rings in `cutTree` and on the raster clean-up loops, through an optional relief passed to `cutLoop` |
| `Sources/CAMCore/Toolpath/CAMEngine.swift` | `GenerationContext.keepOuts` |
| `Sources/NativeCAM/OperationInspector.swift` | `LeadsSection`, `CornersSection` |

The new code reuses what exists:
- `LoopWalker` (walk, breaks, tabs) and `ToolpathBuilder.enter`/`feed`/`follow`;
- `Polyline.closestPoint`, `contains` and `startingNearest`, `Region.contains`, `distancePointSegment` and `segmentsIntersect`;
- the `offsetRegions` and `boundary` regions already computed, and `context.materialTop`;
- in tests, `Fixture` and `SimulationSession`.

## 7. Tests (new `LeadTests.swift`, `CornerReliefTests.swift`; additions to `ExportCheckTests`, `GoldenPostTests`)

**Leads**
1. No plunge feed lands within r + 0.5 mm of the finished wall, and the lead-in's last segment is tangent to the loop (within 2°). Checked for inside and outside cuts, Arc and Line.
2. Climbing gives the lead centre on the left and G3 arcs; conventional mirrors it with G2.
3. Multi-pass plunge entry: one plunge per pass, at A and no deeper than the pass depth. The simulated part is untouched (no gouge), and the kerf goes through all the way round, reusing the `rampedCutOutIsThroughAllTheWayAround` pattern.
4. Ramp plus lead: no straight-down feed into material on any pass, and the descent starts on the lead.
5. Tabs plus leads: tab heights are unchanged, and no lead or overlap lies on a tab.
6. A small hole: the lead shrinks; a tiny hole gets no lead, the warning and a valid toolpath. Two parts 5 mm apart in one toolpath: no gouge in either. A part flush with the material edge: no material-edge warning. A clamp beside the part: no keep-out error.
7. A finishing profile after a roughing profile with allowance runs as a single pass. Its lead lies only over material at or below that pass.
8. An "On" profile with leads produces the same motions as with leads off, plus the note.

**Corner reliefs**

9. A simulated mortise with dogbones is cut to depth at all four drawn corners. Overcut stays within r(1 − sin 45°) plus one cell, and the walls elsewhere are exact.
10. T-bones in a 60 × 20 mortise:
    - Longer side puts the notches in the 60 mm walls.
    - Shorter side flips them to the 20 mm walls.
    - Along X and along Y follow the axes.
    - Climb and conventional produce identical cut cells.
11. Outside profile of an L-shaped part and a finger comb: only the inside corners are relieved.
12. Pocket (offset and raster) with an L-shaped island: wall corners and the island's inside corner are relieved, with no other gouges. This reuses `checkPocket`'s cell logic.
13. Angle threshold: a hexagon is relieved at 120° but not at 110°. A 12-gon is never relieved at the default.
14. Acute corners and rounding:
    - A 30° triangle hole has its tip cut, with no far-wall gouge.
    - A 1 mm corner radius with a 6.35 mm bit is relieved.
    - A corner radius at or above the bit radius produces output identical to reliefs off.
15. An island close to the pocket wall gets no relief at the pinch. Allowance leaves material at the corner.
16. With leads and dogbones together, no entry lands on a relief tip.

**Files and export**

17. A project saved with both options on decodes back to the same settings. A project with them off encodes byte-identically to today.
18. One job with leads and dogbones, in inch and mm, with arcs on and off, is posted for Avid Mach4, Grbl, LinuxCNC and ShopBot. It passes `GCodeCheck.run` with no warnings or errors, `CAMEngine.generate` reports no errors, and the simulation has no rapids through material.
19. One new golden, `features-leads-reliefs.tap` for Avid Mach4, freezes the behaviour. All existing goldens must pass unchanged, without `NATIVECAM_UPDATE_GOLDENS`.

## 8. Docs

- `docs/using-nativecam.md`: Profile row: "…ramp entry; arc or line leads in and out; dogbone or T-bone corners; tabs…". Pocket row: add "dogbone or T-bone corners". Add a short **Leads and corners** subsection on what each setting does and what to check in the preview.
- `docs/known-limits.md`: drop "lead-in/lead-out arcs, dogbones" from the "not yet" line. Add these limits:
  - leads only avoid shapes in their own toolpath, keep-outs and the material edge;
  - the T-bone side is chosen per toolpath, not corner by corner;
  - a relief can break through a wall thinner than the bit radius that belongs to another toolpath.
- `README.md`: the features bullet becomes "tabs, ramps, leads, dogbones and islands".
- `docs/development.md`: update the test count.

## 9. Effort and risks

**Effort:** about 7–8 developer-days.

| Piece | Days |
|---|---|
| Settings and UI | 0.5 |
| Leads: geometry, entry search, clearance, pass structure | 2.5–3 |
| Corner reliefs | 2 |
| Tests | 2 |
| Docs | 0.5 |

Leads are the larger and riskier half.

**Risks:**
- **Restructuring the profile's pass loop could change output with leads off.** Mitigation: a separate code path, guarded by the goldens.
- **Rest-aware start plus leads could slot through uncut waste.** Mitigation: clearance check 4, covered by test 7.
- **Corner detection could relieve a false corner (a pinch) or miss a split corner.** Mitigation: the validity rules, covered by tests 13–15.
- **Leads don't see parts in other toolpaths, and reliefs can't see thin walls.** These are documented.
- **Clearance checks on a sheet of 100+ parts could be slow.** Mitigation: filter by bounds, and time a 50-part sheet in a test.
- **An older build silently drops the options**, as decided in section 4.
- **The rotary branch also edits `CAMEngine`.** The change here is one field, so the merge risk is small.

## 10. Verification and delivery

1. After approval, save this plan as `reports/Lead-ins and corner reliefs.md` in the worktree.
2. Implement on branch `claude/infallible-booth-cd32ca`.
3. Run `scripts/test.sh` for the full suite. The existing goldens must be unchanged.
4. Build with `scripts/build-app.sh`. Render a demo project with leads and dogbones through `-NativeCAMSnapshotProject` to check the toolpath preview and the Leads and Corners sections.
5. Export through the in-app checks, and compare run time with `scripts/measure/analyze.py`.
6. Commit on the branch. Open a PR only when asked.

## Implementation notes (where the build differs from the plan)

- **Leads keep their distance.** On top of the four clearance checks, every point of a lead must stay at least a quarter as far from the cut as it would be off a straight edge (`ToolCentreClearance.keepsAway`). Without this, a lead near a corner could start exactly on the next wall's tool line and plunge against it. A quarter, not a half, still lets shrunk leads fit small holes.
- **Ramped links reach further.** With a ramp, the lead-out is a ramp length along from the entry, so the link back to the lead start may be the ramp length plus four lead sizes long, not just the stay-down limit.
- **Ramp fallback doesn't plunge.** When that link isn't clear, the tool lifts and drops to the floor already cut at the lead start, and the next ramp starts from there. That ramp is steeper, but each point still cuts at most one pass deeper.
- **Arc fitting kept out-and-back moves.** `ArcFitter` treated a move that returns to its own start (corner → relief tip → corner) as collinear and dropped it. With arcs on, every relief vanished from the posted file. Such a move now merges only if its detour is within tolerance. No existing golden file changed.
- **Tabs refactor.** Tab placement moved into a shared `TabPlan`, used by both the old and new loop cutters with the same arithmetic. The existing goldens confirm the output is unchanged.
- **Tests:** 28 new tests across 3 new suites (327 tests in 39 suites in all), plus the `features-leads-reliefs.tap` golden.
