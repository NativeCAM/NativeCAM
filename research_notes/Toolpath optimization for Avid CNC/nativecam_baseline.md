# NativeCAM toolpath efficiency baseline (Demo Sign, Demo Relief)

*Scope and method: this is a read-and-measure audit of the code in `/Users/dsmith/natcam` (commit ef765d3) and of its posted G-code. No repository files were changed. Sources are the repository's own files (cited by path and line) and measurements made with scripts in the session scratchpad, `/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/`. That folder is temporary and can be cleared on reboot. The scripts are `gcode.py` (parser), `analyze.py` (metrics and time models), `export_moves.py` and `engage.swift` (heightmap material-removal simulator), `air.py`, `whatif.py`, `scenarios.sh`, plus a patched copy of the sources in `audit/proto/`. I rebuilt the CLI there with `--scratch-path` and re-posted both example projects with the current code. The new G-code is motion-identical to the committed `examples/*.tap`: only two header comment lines differ. So every number below applies to the current code.*

## 1. From the code: how each generator orders cuts, picks entries, retracts and sequences depths, and where the obvious inefficiencies are

### Takeaway
All generators share one `ToolpathBuilder`. Any link that moves in XY goes up to the full 0.5 in clearance, back down to 0.1 in, then plunge-feeds. Only the pocket generator (hops of 2.5× stepover or less, inside the safe area) and the 3D-finish generator (hops of 3× stepover or less) stay down. Every operation is ordered by greedy nearest-neighbour. Depth levels are spread evenly, so N = ceil(depth / stepdown). The biggest code-level inefficiencies are not the retracts:
- The V-carve corner rule sends the tool up to Z0 at every vertex of a flattened convex curve.
- The 3D "Whole material" boundary machines the entire stock, including the area the cut-out throws away.
- Any descent steeper than 45° is fed at the plunge rate.
- Generators built with `startXY: nil` make the post rapid to X0 Y0 first.

### Cited Findings
**Shared builder and heights**
- Clearance is `max(stock.clearanceHeight, stock.plungeHeight)`. Plunge Z is `max(0.1 mm, stock.plungeHeight)`. The defaults are 0.5 in clearance, 0.1 in plunge height and a park height of 1.0 in. — [ToolpathBuilder.swift:16-24](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ToolpathBuilder.swift); [Stock.swift:47-48](/Users/dsmith/natcam/Sources/CAMCore/Model/Stock.swift)
- `enter(at:)` handles any XY change the same way: `retract()` to full clearance, rapid over at clearance, rapid down to plunge Z, then feed down at the plunge rate. It has no short-retract or stay-down option. `retract()` always goes to `clearanceZ`. — [ToolpathBuilder.swift:47-64](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ToolpathBuilder.swift)
- `feed()` switches to the plunge rate for any descent where the horizontal distance is less than |dz| (steeper than 45°). It slows the whole move rather than capping only the Z component. — [ToolpathBuilder.swift:33-40](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ToolpathBuilder.swift)
- Ordering uses `nearestNeighborOrder`, a greedy nearest-start-point search with no 2-opt and no choice of entry point inside an item. — [ToolpathBuilder.swift:183-201](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ToolpathBuilder.swift)
- Depth levels are evenly distributed: n = ceil(total / step), each level total / n deep. For example, 0.77 in at a 0.125 in stepdown gives 7 passes of 0.11 in. — [Operation.swift:30-36](/Users/dsmith/natcam/Sources/CAMCore/Model/Operation.swift)
- The CLI's time estimate is a constant-velocity sum that ignores acceleration. — [Toolpath.swift:156-161](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/Toolpath.swift)

**Profile (cut-outs)**
- Contours nested inside others are cut first. Within each nesting level the order is greedy nearest-neighbour from the home XY. Each closed loop is rotated to start at the point nearest the tool (`startingNearest`). — [ProfileGenerator.swift:52-87](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ProfileGenerator.swift)
- Depth is sequenced contour-major: all levels of one contour run continuously with no retract between levels. With a ramp entry, each level walks `rampLength + L` (the ramp, then a full lap). There is a full retract after every contour. — [ProfileGenerator.swift:84-92, 137-163](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ProfileGenerator.swift)
- Tabs are handled by clamping Z to `tabZ` inside each tab interval at every level below `tabZ`. On the final level the tool still runs over the tabs at feed, although that material was already removed on the previous level. — [ProfileGenerator.swift:105-135](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ProfileGenerator.swift)
- Open vectors are cut zig-zag, alternating direction per level, starting from the end nearest the tool. — [ProfileGenerator.swift:166-178](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ProfileGenerator.swift)

**Pocket**
- Depth is sequenced level-major: each level cuts the whole ring tree, then `b.retract()` to full clearance, then the next level re-enters at the innermost ring. Both offset and raster strategies do this. — [PocketGenerator.swift:42-68](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/PocketGenerator.swift)
- Rings are cut inside-out (children first, islands before the outer ring), ordered by greedy nearest-neighbour. — [PocketGenerator.swift:107-123](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/PocketGenerator.swift)
- The tool stays down only for links of 2.5× stepover or less whose straight segment stays inside the safe area. Otherwise it uses a ramp along the loop (if configured) or `enter()`, which is a full retract. The default pocket entry is a plunge. — [PocketGenerator.swift:127-151](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/PocketGenerator.swift); [Operation.swift:69](/Users/dsmith/natcam/Sources/CAMCore/Model/Operation.swift)

**Drill**
- Holes are visited in greedy nearest-neighbour order from home. The default `fullRetract: true` rapids up to plunge Z (0.1 in) after every peck and rapids back down to 0.5 mm above the previous depth. There is a full clearance retract after every hole. — [DrillGenerator.swift:28-54](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/DrillGenerator.swift); [Operation.swift:138](/Users/dsmith/natcam/Sources/CAMCore/Model/Operation.swift)

**V-carve**
- Each outline loop becomes one closed medial-axis path. Paths are ordered by greedy nearest-neighbour on their fixed first point (the start is not rotated). The loop runs pass-major: for each pass limit, it does `enter`, `follow`, then a full `retract` for every path. — [VCarveGenerator.swift:63-74](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/VCarveGenerator.swift)
- Corner rule: at every vertex with `turn > 1e-9` the carve "rises to the surface at the corner tip" (`out.append(Vec3(b, 0))`). Outlines are flattened at 0.01 mm chord tolerance, so every vertex of a convex curve passes this test. — [VCarveGenerator.swift:111-117](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/VCarveGenerator.swift); [CAMEngine.swift:49-51](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/CAMEngine.swift)
- The result is visible in the posted file. On the D, the tool feeds from depth up to the outline at Z0 and straight back down at 30 ipm, about every 0.05 in of travel. Example: `G01 X16.2628 Y10.0011 F80.0` / `G01 X16.2722 Y9.7512 Z0.0000` / `G01 X16.2631 Y10.0011 Z-0.4330 F30.0`. — [examples/Demo Sign.tap, lines 256-300](/Users/dsmith/natcam/examples/Demo%20Sign.tap)

**3D roughing and finishing**
- The `.material` boundary is the full stock rectangle. The only other option is the model's outline. No option clips 3D work to a chosen vector such as the cut-out outline. Both relief operations in the demo use `.material`. — [Model3DGenerator.swift:31-33](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/Model3DGenerator.swift); [DemoProject.swift:54-56](/Users/dsmith/natcam/Sources/CAMCore/Project/DemoProject.swift)
- Roughing is level-major. Levels are evenly spaced down to the deepest target. Each level is run through the offset-pocket engine (inside-out rings) and followed by a full retract. — [Model3DGenerator.swift:84-109](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/Model3DGenerator.swift)
- Finishing is a zig-zag raster: rows sorted, direction alternated per row. Hops of 3× stepover or less are fed along the drop-cutter surface. Anything longer gets `enter()`, a full retract. Samples are spaced at `max(cell, 0.15 mm)` and simplified at min(0.01, 2 × arcTol) = 0.01 mm. — [Model3DGenerator.swift:145-211](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/Model3DGenerator.swift)

**Arc fitting, engine and post**
- ArcFitter only fits runs of consecutive feed moves at the same F. Arcs must stay within tolerance, sweep less than 180°, and keep Z linear with angle. Other moves are collinear-merged at 0.1× tolerance. The tolerance is `machine.arcFitTolerance` = 0.01 mm. 3D rasters that are straight in XY get no arcs. — [ArcFitter.swift:9-71, 112](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ArcFitter.swift); [CAMEngine.swift:61-64](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/CAMEngine.swift)
- Operations are emitted in list order, with no grouping by tool. — [CAMEngine.swift:54-69](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/CAMEngine.swift)
- The post starts every toolpath with `G00 Z<safe>` then `G00 X Y` of `tp.start`. Generators that build with `startXY: nil` (pocket, drill, 3D rough, 3D finish) have `tp.start` = (0,0). The machine therefore rapids to X0 Y0 before going to the first cut. The posted files show this: `G00 X0.0000 Y0.0000` followed by `G00 X8.2250 Y4.9750` (pocket) and `G00 X2.5000 Y2.5000` (drill). — [AvidMach4Post.swift:76-85](/Users/dsmith/natcam/Sources/CAMCore/Post/AvidMach4Post.swift); [ToolpathBuilder.swift:21](/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ToolpathBuilder.swift); [examples/Demo Sign.tap, lines 613-617, 804-808](/Users/dsmith/natcam/examples/Demo%20Sign.tap)
- Starter feeds used by the demos:
  - T1 1/4 in upcut: 150 / 40 ipm, 0.125 in stepdown, 0.4 stepover.
  - T5 60° V-bit: 80 / 30 ipm.
  - T7 1/4 in ball nose: 120 / 30 ipm.
  - The T4 compression bit in the same library uses a 0.25 in stepdown.
  — [ToolLibrary.swift:32-58](/Users/dsmith/natcam/Sources/CAMCore/Model/ToolLibrary.swift)

### Inferences
Inefficiencies seen in the code, in rough order of impact on the two demos. The measured savings are in section 3.
1. **V-carve "corner" spikes on curved outlines.** The rule at line 115 needs a minimum turn angle. Smooth convex curves should not send the bit to the surface at every flattened vertex.
2. **3D work over scrap material.** There is no boundary option that limits 3D rough and finish to the cut-out outline plus a margin.
3. **Plunge-rate descents.** The 45° rule slows the whole move to the plunge rate instead of capping only the Z component.
4. **Full-height retracts everywhere.** Links go to 0.5 in even inside one operation over flat, already-cut stock, and drill pecks rapid all the way back to 0.1 in.
5. **X0 Y0 detour.** It comes from `startXY: nil` combined with the post's unconditional approach move.
6. **Level-major pockets and roughing.** These return to clearance and travel back to the centre at every level.
7. **No rest awareness in profiles.** A cut-out always starts at Z0 even when earlier operations have already cleared that depth.
8. **Minor:** final-level tab traversal in air, ramp overlap of 1 ramp length per level, and greedy nearest-neighbour order without start-point rotation for V-carve paths.

### Gaps
- I did not audit the importers, flattening, Clipper offset quality or the simulator code beyond what affects these two jobs.
- Raster pocketing and open-vector profiles are not used by either demo, so they were read but not measured.

## 2. From the G-code: measured lengths, moves, retracts and time, with and without acceleration

### Takeaway
- Demo Sign: CV 10:11 → 11:18 with acceleration (+11%).
- Demo Relief: CV 18:48 → 23:10 with acceleration (+23%), mostly 3D roughing (+46%).
- NativeCAM's own estimate (10:03 and 18:45) is constant-velocity, so it understates by about 12% and 24% under the specified model, and by 4–58% across the 5–50 in/s² sensitivity range.
- Rapids are a small share of time (4–7%). The time goes into feed moves that remove nothing (55% of V-carve length, 46% of the relief cut-out) or that machine scrap: 46% of all relief feed length, about 44% of the job time under the acceleration model.

### Cited Findings
**Method**
- Parser: my own Python reader of the `.tap` files. It handles modal G0/G1/G2/G3, G91.1 incremental I/J, inches, M-codes and G4. Arc length is r·sweep from I/J, combined with Z for helical moves. The worst arc radius mismatch is 0.0001 in. Toolpaths are split on the `(Toolpath: …)` comments. Program start is assumed at X0 Y0 Z1.0, the park position. — [gcode.py / analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)
- Time models:
  - CV: feeds at the programmed F, rapids at 400 ipm.
  - B: a trapezoidal look-ahead planner over the whole program (forward and backward pass) at 15 in/s². It stops fully at any junction turning more than 30°, at M-codes and at dwells. Otherwise the junction speed is min(F_in, F_out).
  - C: B plus a centripetal limit on arcs (v ≤ √(a·r)) and a junction-deviation cap (δ = 0.001 in) on the shallow junctions.
  - "Corners > 30°" counts junctions between consecutive moves where at least one is a feed. "Tiny" means a feed move under 0.01 in.
  — [analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)
- Air and scrap: `engage.swift` replays every move on a 0.01 in heightmap of the stock using the real tool shapes (flat, ball, 60° V). It flags each sample that lowers some cell by more than 0.0005 in.
  - Air: feed length that removes nothing.
  - Scrap: feed length where the tool centre is more than one tool radius outside the finished part. The part is the 22×16 in rounded rectangle for the sign and the 153×103 mm ellipse for the relief.
  - Time attributed to air and scrap is the move's time multiplied by its air or scrap fraction.
  — [engage.swift / air.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/air.py)
- The NativeCAM CLI prints "Estimated run time: 0:10:03" for the sign and "0:18:45" for the relief. My CV reproduction gives 10:11 and 18:48. The difference is the post's per-toolpath approach rapids and the footer, which `Toolpath.estimatedSeconds` does not include. — `nativecam-cli post` output, [main.swift:57-71](/Users/dsmith/natcam/Sources/nativecam-cli/main.swift)

**Demo Sign: per toolpath** (source: [analyze.py, air.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/) on [examples/Demo Sign.tap](/Users/dsmith/natcam/examples/Demo%20Sign.tap))

| metric | V-Carve title (T5) | Pocket plaque (T1) | Drill holes (T1) | Cut out sign (T1) | Total |
|---|---|---|---|---|---|
| cutting (feed) length, in | 152.6 | 472.7 | 3.7 | 537.8 | 1166.8 |
| feed length above Z0, in | 0.6 | 0.2 | 0.4 | 0.1 | 1.3 |
| rapid length, in (XY / Z) | 30.0 (22.8 / 7.2) | 31.9 (29.8 / 2.2) | 78.1 (57.2 / 20.8) | 15.4 (13.2 / 2.2) | 155.4 (123.0 / 32.4) |
| retracts to clearance (0.5 in) | 6 | 2 | 4 | 1 | 13 |
| partial retracts (pecks to Z0.1) | 0 | 0 | 12 | 0 | 12 |
| vertical plunges (feed) | 6 | 2 | 16 | 13 | 37 |
| feed moves | 564 | 182 | 16 | 147 | 909 |
| mean / median feed segment, in | 0.271 / 0.110 | 2.597 / 0.550 | 0.232 / 0.270 | 3.658 / 1.504 | 1.284 / 0.249 |
| tiny segments < 0.01 in | 4 (1%) | 8 (4%) | 0 | 0 | 12 (1%) |
| arcs: share of moves / of length | 7% / 3% | 18% / 0% | 0 / 0 | 38% / 9% | 14% / 5% |
| corners > 30° | 303 | 126 | 16 | 50 | 495 |
| time CV (feed / rapid) | 3:01 (2:57 / 0:05) | 3:14 (3:10 / 0:05) | 0:17 (0:06 / 0:12) | 3:38 (3:36 / 0:02) | 10:11 (9:48 / 0:23) |
| time B (accel) | 3:27 | 3:36 | 0:29 | 3:46 | 11:18 |
| B / CV | 1.14× | 1.11× | 1.68× | 1.03× | 1.11× |
| time C (strict) | 3:27 | 3:38 | 0:29 | 3:46 | 11:20 |
| air feed length (share) | 83.9 in (55%) | 2.2 (0.5%) | 0.7 (18%) | 5.7 (1.1%) | 92.5 (7.9%) |
| air time, B model | 125 s | 2 s | 1 s | 5 s | 133 s |

- V-carve feed split:
  - 49.8 in at F30 (plunge rate, steep descents) takes 99.5 s CV, 56% of the V-carve's feed time.
  - 102.9 in at F80 takes 77.2 s.
  — [analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)
- The V-carve path for the D's outer loop is 89.85 in long with 348 moves, and only 17% of it removes material. The other letters' loops are 79–99% engaged. The V-carve has 96 surface apexes (feeds up to Z0 and straight back down). — [vcheck.py, engage.swift](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/)
- In-op retract links (retract, travel, approach, plunge):
  - V-carve: 5 links, hops 1.1–4.6 in.
  - Pocket: 1 link (the level change), hop 1.1 in.
  - Drill: 3 links, hops 13, 19 and 13 in (greedy nearest-neighbour is optimal for these four corners).
  - Total link time: 16 s CV, 25 s B.
- X0 Y0 detours add 19.2 in of rapid before the pocket and 7.0 in before the drill. — [analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)
- B-model time by category:
  - cut: 516 s
  - ramp/descend: 105 s
  - rapid XY: 25 s
  - rapid Z: 20 s
  - plunge: 13 s
  Rapids are 45 s of 678 s (6.6%). In CV they are 23 s of 611 s (3.8%). — [analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)

**Demo Relief: per toolpath** (source: [analyze.py, air.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/) on [examples/Demo Relief.tap](/Users/dsmith/natcam/examples/Demo%20Relief.tap))

| metric | Rough relief (T1) | Finish relief (T7) | Cut out medallion (T1) | Total |
|---|---|---|---|---|
| cutting (feed) length, in | 678.8 | 1452.8 | 125.7 | 2257.4 |
| feed length above Z0, in | 4.0 | 0.1 | 0.1 | 4.2 |
| rapid length, in (XY / Z) | 119.5 (74.7 / 44.9) | 15.9 (14.6 / 1.3) | 12.9 (10.7 / 2.2) | 148.3 (100.0 / 48.3) |
| retracts to clearance | 40 | 1 | 1 | 42 |
| vertical plunges (feed) | 40 | 1 | 10 | 51 |
| feed moves | 3,417 | 17,731 | 327 | 21,475 |
| mean / median feed segment, in | 0.199 / 0.079 | 0.082 / 0.038 | 0.385 / 0.365 | 0.105 / 0.041 |
| tiny segments < 0.01 in | 133 (4%) | 0 | 8 (2%) | 141 (1%) |
| arcs: share of moves / of length | 77% / 30% | 0% / 0% | 90% / 98% | 14% / 15% |
| corners > 30° | 724 | 1,011 | 38 | 1,773 |
| time CV (feed / rapid) | 5:03 (4:45 / 0:18) | 12:52 (12:49 / 0:02) | 0:53 (0:51 / 0:02) | 18:48 (18:26 / 0:22) |
| time B (accel) | 7:21 | 14:50 | 0:59 | 23:10 |
| B / CV | 1.46× | 1.15× | 1.11× | 1.23× |
| time C (strict) | 7:55 | 14:53 | 0:59 | 23:47 |
| air feed length (share) / B time | 17.6 in (2.6%) / 21 s | 8.3 (0.6%) / 10 s | 58.3 (46.4%) / 26 s | 84.2 (3.7%) / 56 s |
| scrap feed length (share) / B time | 470.3 in (69.3%) / 247 s | 563.2 (38.8%) / 366 s | 7.1 (5.6%) / 3 s | 1040.6 (46.1%) / 617 s |

- Roughing has 39 in-op retract links. Hops run 0.53–5.7 in (median 0.92 in) and none is under 0.5 in. Link time is 36 s CV and 73 s B. Retracts by level: 16 at the first level (−0.095 in) and 8 at each of the three deeper levels. — [analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)
- Finishing stays down the whole time: 0 in-op retracts, about 339 zig-zag rows at 45° (counted from direction reversals) and a 0.025 in stepover. 28.6 in of steep descents run at the 30 ipm plunge rate, taking 57 s CV. — [analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)
- Cut-out: the roughing and finishing have already lowered the surrounding material to about −0.38/−0.40 in. That leaves the cut-out's first three levels (−0.11, −0.22, −0.33) fully in air, which is the 46% air figure. — [engage.swift / vcheck.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/)
- X0 Y0 detour before finishing: 11.2 in of extra rapid. — [analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)
- B-model time by category:
  - cut: 1093 s
  - ramp/descend: 212 s
  - rapid XY: 32 s
  - rapid Z: 31 s
  - plunge: 22 s
  Rapids are 63 s of 1390 s (4.5%). — [analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)
- Arc radii:
  - Roughing: median 0.258 in, p10 0.140 in.
  - Sign pocket: median 0.1255 in, 50% under 0.05 in.
  Model C's centripetal limit adds 34 s to roughing and almost nothing elsewhere.
  — [analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)

**Sensitivity of the acceleration underestimate** (B / CV, with the stop angle fixed at 30° unless noted)

| accel, in/s² | 5 | 10 | 15 | 25 | 50 |
|---|---|---|---|---|---|
| Demo Sign | 1.28× (13:00) | 1.15× (11:46) | 1.11× (11:18) | 1.07× (10:54) | 1.04× (10:34) |
| Demo Relief | 1.58× (29:46) | 1.33× (24:58) | 1.23× (23:10) | 1.15× (21:36) | 1.08× (20:18) |

- Varying the stop angle at 15 in/s²:
  - Relief: 1.32× at 15°, 1.23× at 30°, 1.14× at 60°.
  - Sign: 1.11× regardless of angle.
  - Cutting rapids to 300 ipm adds only 7–8 s CV to either job.
  — [analyze.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/analyze.py)

### Inferences
- The constant-velocity estimate errs most on 3D roughing (1.46×) and drilling (1.68×). Roughing has short, kinked contour segments (median 0.079 in, 724 corners over 30°). Drilling's Z moves are too short to reach 400 ipm at 15 in/s², which takes about 1.5 in of travel. Long straight work like the sign cut-out is close to CV (1.03×).
- Tiny segments are not a problem in these files: only 1% are under 0.01 in. The 3D finish is dense, though: a 0.038 in median at 120 ipm is roughly 50 blocks/s, and it has no arcs.
- Retract count matters less than it looks. Both jobs have 55 clearance retracts in total, 48 of them in-operation links (retract, travel, approach, plunge). Those links cost 98 s in model B (25 s sign, 73 s relief). Air cutting and scrap cutting cost far more.

### Gaps
- I have no machine-side ground truth: no Mach4 run logs or timed runs on the user's PRO6060.
- The 15 in/s² acceleration, the 30° stop rule, 400 ipm rapids on every axis (Z included) and uniform acceleration per axis are assumptions from the brief, not measured Avid/Mach4 values. Real CV-mode blending and look-ahead in Mach4 and its motion controller could land anywhere in the sensitivity table.
- Not timed: manual tool changes (M6 plus touch plate; one change on the sign, two on the relief), spindle spin-up, and any moves made by the Mach4 M6 macro.
- The engagement simulator's resolution is 0.01 in cells with a 0.0005 in removal threshold. Air and scrap figures are accurate to roughly ±1–2% of length.

## 3. Which single changes would save the most time on these two jobs, with estimated savings

### Takeaway
- Demo Relief: by far the biggest win is clipping 3D roughing and finishing to the cut-out outline plus a margin. It saves 8:16–9:33 under the acceleration model (36–41% of the job) with the relief surface unchanged.
- Demo Sign: the biggest code fix is a minimum turn angle for V-carve convex corners. It saves 1:39 (15%; the V-carve itself drops 3:27 → 1:48) with the carving unchanged to within 0.005 in.
- A larger sign lever is project data rather than code: a 0.25 in stepdown for the pocket and cut-out saves 3:19 (29%) but needs a machining-safety judgment.
- Short retracts, removing the X0 Y0 detour, Z-capped descent feeds and peck back-off together add only about 0.5 min per job.

### Cited Findings
**How savings were measured.** Most rows use a prototype: a patched copy of the sources in `audit/proto/` (the repository is untouched). Environment flags switch each fix on separately, both jobs are re-posted with the prototype CLI, and the output is re-timed with the same models. The finished-part heightmap is then compared with the baseline's. Rows marked "G-code transform" edit the parsed program instead. — [scenarios.sh, whatif.py, proto/](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/)

| job | change (how tested) | B saving | CV saving | quality check |
|---|---|---|---|---|
| Relief | Clip 3D rough and finish to the cut-out ellipse + 3.7 mm (proto `NC_CLIP_ELLIPSE=80.175,55.175`) | 9:33 (23:10 → 13:37, 41%) | 7:53 (18:48 → 10:55) | Relief surface unchanged; 0.7% of part cells differ by > 0.005 in, max 0.025 in, at the floor/wall foot the 1/4 in ball cannot reach |
| Relief | Same, + 7.5 mm margin (enough room for the 1/4 in rougher) | 8:16 (→ 14:54, 36%) | 6:39 (→ 12:09) | Same pattern; 0.5% of part cells > 0.005 in; net volume +0.0002 in³ |
| Relief | Cut-out start depth at the already-roughed floor, 0.38 in (project change) | 22 s (cut-out 0:59 → 0:37) | 21 s | Removed volume identical (10.74 in³) |
| Relief | Short retracts: links inside an op go to 0.1 in, not 0.5 in (proto `NC_SHORT`) | 17 s (rough retracts 40 → 1) | 5 s | Identical part |
| Relief | Z-capped descents, F = min(F, F_plunge / sin slope) (proto `NC_ZCAP`) | 14 s (finish) | 12 s | Identical part |
| Relief | No X0 Y0 start detour (proto `NC_START`) | 2 s | 2 s | Identical part |
| Relief | Combined clip (+7.5 mm) + short + start + zcap | 8:41 (→ 14:29, 37%) | 6:55 (→ 11:53) | As for clip |
| Sign | Stepdown 0.25 in instead of 0.125 in for T1 pocket and cut-out (project data) | 3:19 (11:18 → 7:59, 29%); pocket 3:36 → 1:50, cut-out 3:46 → 2:12 | 3:06 (→ 7:05) | Not a code fix; changes cutting load |
| Sign | V-carve convex corners only above 10° turn (proto `NC_VC_TURN=10`; 20° gives an identical result) | 1:39 (→ 9:39, 15%); V-carve feed 152.6 → 84.5 in, 564 → 415 moves, surface apexes 96 → 18 | 1:33 (→ 8:38) | Removed volume equal (25.08 in³); 27 of 3.5 M part cells differ by > 0.002 in, none by > 0.005 in |
| Sign | Z-capped steep-descent feed (proto `NC_ZCAP`) | 13 s | 14 s | Identical part |
| Sign | Drill pecks back off 0.02 in instead of rapiding to Z0.1 (G-code transform) | 8 s | 2 s | Not simulated |
| Sign | No X0 Y0 start detour (proto `NC_START`), 26 in less rapid | 5 s | 4 s | Identical part |
| Sign | Short retracts (proto `NC_SHORT`), retracts 13 → 4 | 4 s | 1 s | Identical part |
| Sign | Combined code fixes (VC turn + short + start + zcap) | 1:52 (→ 9:26, 16.5%) | 1:43 (→ 8:28) | As for VC turn |

- After the V-carve fix, the V-carve still has 16.1 in of air (19%) and 15.7 in at the 30 ipm plunge rate (31 s CV). This is the descent and re-trace along shared medial axes. — [air.py, analyze.py on scen/sign-vc10.tap](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/)
- The 7.5 mm clip still pre-clears the cut-out kerf, so the cut-out keeps its 46% air. The cut-out start-depth change (22 s) stacks on top of the combined relief figure. — [air.py on scen/relief-clip84.tap](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/)
- A naive G-code-level removal of every V-carve up/down spike estimated 145 s. That overstates the saving, because it also deletes the ascents needed at the 18 real sharp corners. The generator-level prototype figure (99 s) is the one to use. — [whatif.py](/private/tmp/claude-501/-Users-dsmith-natcam/46f07b7c-c8f3-4a25-9320-04d54556021a/scratchpad/audit/whatif.py)

### Inferences
- Priority by time saved per unit of effort:
  1. **3D boundary clipped to the cut-out vector.** Adds a boundary option, or auto-clips when a cut-out profile exists. Saves about 8–9.5 min on the relief.
  2. **V-carve minimum corner angle.** A one-line threshold in `carvePath`. Saves about 1.6 min on the sign.
  3. **Rest-aware profile start depth.** The cut-out starts at the depth earlier operations already cleared. Saves about 0.4 min on the relief.
  4. **Smoothing 3D-rough contours.** Fewer corners over 30° in the grid-derived rings. The upper bound is the 1:52 → 2:51 CV-to-B gap that remains after clipping (59 s). This is my inference; it was not prototyped.
  5. **Z-capped descent feeds.** About 13–14 s per job.
  6. **Short retracts, start-detour fix and peck back-off.** About 5–25 s each.
- Combining depth levels pays off far more than retract work on the sign: halving the T1 passes saves about 3.3 min. Whether a 1/4 in two-flute upcut can slot 0.25 in deep at 150 ipm in Baltic birch is a feeds-and-speeds call. The brief gives me no basis to make it, and NativeCAM's starter library already uses 0.25 in for the compression bit.
- Reordering the relief to rough → cut-out → finish (all T1 work first) would remove one manual tool change. It means finishing a part held only by tabs, which is a quality and safety trade-off. Tool-change time was not modeled.
- Stay-down linking beyond what already exists has little left to win on these jobs. Link time with full retracts is 25 s B on the sign and 73 s B on the relief. The short-retract prototype already recovers 4 s and 17 s of that, and no remaining hop is under 0.5 in.

### Gaps
- The clip prototype hard-codes the demo's ellipse. A real implementation would take the user's chosen vector and use proper offsets (separate margins for the rougher and the ball). It would also need to handle parts without a cut-out.
- Short-retract safety is assumed: nothing stands above the material top (no clamps or screws in the path). That needs a user setting or a check against the fixtures, which NativeCAM does not model.
- The savings are model estimates (B at 15 in/s², 30° stop). The ratios between options should hold, but absolute seconds depend on the real Mach4 and Avid motion behaviour, which was not measured.
- Not quantified: tool-change and touch-off time, the cost of V-carve wide-stroke ridges (strokes wider than 2 × rCap = 0.5 in are capped at 0.433 in depth with no flat-clearing tool), and any effect of the changes on cut quality beyond the heightmap comparison.
