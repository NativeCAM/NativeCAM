# Adaptive / Constant-Engagement Area Clearing (Adaptive Clearing, HSM, Trochoidal, Dynamic, Volumetric Milling): Algorithms and Implementation Notes for NativeCAM

Scope note: these notes target an "Adaptive" 2.5D pocket strategy and a layered 3D roughing strategy for NativeCAM (Swift, Apple silicon, Clipper2-based offset/raster pocketing already present) driving Avid CNC gantry routers under Mach4. Source-code facts about FreeCAD come from reading `Adaptive.cpp` / `Adaptive.hpp` on FreeCAD `main` as downloaded on 2026-11-19. Line numbers are approximate and will drift.

## How do the main approaches work (offset-based with engagement control, medial-axis/spiral, trochoidal, simulation-based engagement such as FreeCAD Adaptive, and the commercial products)? Step-by-step outlines, data structures, and how engagement is computed

### Takeaway
There are four main families. (1) **Simulation-driven "walk" algorithms** (FreeCAD Adaptive, Freesteel/Autodesk Adaptive Clearing, Mastercam Dynamic). They keep a running model of the cleared region and step the tool forward, choosing each step's heading so the area cut per unit distance matches a target. (2) **Medial-axis or Voronoi spirals** (Held & Spielberger, MATHSM). (3) **PDE or morphing spirals** (Bieterman & Sandstrom, Banerjee; iMachining's "morphing spiral" is a commercial cousin). (4) **Trochoidal cycles** placed along a medial-axis centerline (Ibaraki), used for slots and for the critical regions that offset paths overload. FreeCAD's open-source Adaptive is the best implementation reference, and it is now built on **Clipper2**, the same library NativeCAM uses. It is not a pixel/bitmap simulator: it keeps the cleared region as integer polygons and computes the cut area analytically.

### Cited Findings

**FreeCAD CAM Adaptive (author Kresimir Tusek, "kreso"): what the code actually does**
- File locations: `src/Mod/CAM/libarea/Adaptive.cpp` (about 4,360 lines) and `Adaptive.hpp` (about 295 lines). Both carry `SPDX-License-Identifier: LGPL-2.1-or-later` and "Copyright (c) 2018 Kresimir Tusek" — [Adaptive.cpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp), [Adaptive.hpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.hpp)
- The implementation was migrated from Clipper 1 to **Clipper2** in a series of commits by David Kaufman (Aug–Nov 2026): "Migrate AppendToolPath to clipper 2", "Delete clipper 1", "bug fix, clipper offsets produce up to sqrt(2) error not 1 error", and "handle pancakes in the output of SimplifyPaths" (2026-11-03). The code now uses `Clipper2Lib::Paths64`, `ClipperOffset`, `Union`, `Intersect`, and `Difference` — [FreeCAD commit history for Adaptive.cpp](https://github.com/FreeCAD/FreeCAD/commits/main/src/Mod/CAM/libarea/Adaptive.cpp)
- The public API is `Adaptive2d::Execute(stockPaths, paths, clearedPaths, progressCallbackFn)`. It returns a list of `AdaptiveOutput`, each holding `HelixCenterPoint`, `StartPoint`, and `AdaptivePaths` (a vector of `(MotionType, DPath)`), plus warning flags (`StartPointNotFound`, `LeadPathFailed`, `TooManyFailedEngagements`, `UnclearedAreaRemains`, and others). Motion types are `mtCutting`, `mtLinkClear`, and `mtLinkNotClear`. Operation types are `otClearingInside`, `otClearingOutside`, `otProfilingInside`, and `otProfilingOutside` — [Adaptive.hpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.hpp)
- User parameters on the class: `toolDiameter`, `helixRampTargetDiameter`, `helixRampMinDiameter`, `stepOverFactor` (default 0.2), `tolerance` (default 0.1), `stockToLeave`, `forceInsideOut` (default true), `finishingProfile` (default true), `keepToolDownDistRatio` (default 3.0), and `opType` — [Adaptive.hpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.hpp)
- Tuning constants: `MIN_STEP_CLIPPER = 16*3` (48 integer units, with a written derivation that a finishing-size cut is never measured as zero area after integer rounding), `MAX_ITERATIONS = 30`, `AREA_ERROR_FACTOR = 0.05` ("how precise to match the cut area to optimal ... 5%"), `ANGLE_HISTORY_POINTS = 3` (used for angle prediction), `DIRECTION_SMOOTHING_BUFLEN = 3` ("gyro points"), and `FINISHING_THICKNESS_SCALE = 1/10` ("finish at this fraction of stepover") — [Adaptive.hpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.hpp)
- Integer scaling: `scaleFactor = MIN_STEP_CLIPPER / tolerance / min(1.0, stepOverFactor * toolDiameter)`. The code comment reads "1/'tolerance' = number of min-size adaptive steps per stepover". The tolerance setting therefore sets both the Clipper integer resolution and the minimum step — [Adaptive.cpp ~L1749](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp)
- **Target engagement as "area per distance".** The code builds the tool disk with `OffsetPath(point, R, Round)`, translates it by R/2, and takes `referenceCutArea = Area(Difference(tool, translatedTool))`, the crescent swept by a half-radius move. It then sets `optimalCutAreaPD = 2 * stepOverFactor * referenceCutArea / toolRadiusScaled`. Every step is judged by `areaPD = CalcCutArea(...) / stepLength` against this target — [Adaptive.cpp ~L1775-1784](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp)
- **`CalcCutArea(c1, c2, cleared)` is exact and analytic, not a raster.** It pulls the cleared-area polygons near the tool (bounding-box culled) and gathers every x-coordinate of interest: polygon vertices, polygon/circle intersections, circle/circle intersections, and vertical tangents. It sorts these and, in each x-interval, casts a vertical line through the midpoint. Along that line it walks the sorted crossings with an "outsideCount" state machine and integrates the boundary curves, giving the area inside the new tool circle c2, outside the old circle c1, and outside the cleared polygons. It returns `{totalArea, conventionalArea}`, where conventional area is the part with x < c2.x in the tool's local frame, used to detect conventional (non-climb) cutting — [Adaptive.cpp ~L1197-1490](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp)
- **Cleared-area model (`ClearedArea` class).** It holds `Paths64 clearedPaths`. `ExpandCleared(toolPath)` offsets the new tool-center path by R+1 with round ends, unions it in (EvenOdd), then calls `SimplifyPathsFilterPancakes(..., 1.415)`. Queries go through `GetBoundedClearedAreaClipped(toolPos, delta)`, a two-level cache: a large window of 10x delta is intersected with the cleared area and reused while the tool stays inside it, then a small focus box is intersected from that window — [Adaptive.cpp ~L970-1066](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp)
- **Per-step heading search.** Each step tries headings relative to the current direction in a range of [-pi/4, +pi/4] (`Interpolation::MIN_ANGLE` = max engagement, `MAX_ANGLE` = min engagement), in this order:
  - Iteration 0: the angle predicted from the average of the last 3 angles.
  - Iteration 1: MIN_ANGLE.
  - Iteration 2: interpolation if the error is bracketed on both sides, otherwise MAX_ANGLE.
  - Later iterations: interpolation on `error = areaPD - targetAreaPD`.
  - Iteration 3, if no positive area was found yet: flush pending cut into the cleared model and search a forward triangle (plus or minus 45 degrees) for uncleared material.

  A step is accepted when the error is within 5% of target. A safety check rejects steps where `area > step*optimal && areaPD > 2*optimal`. Cuts whose conventional fraction exceeds 0.51 are flagged — [Adaptive.cpp ~L3389-3640](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp)
- **Adaptive step length.** Near the boundary or the entry point (within `max(R/4, 8*MIN_STEP)`) the step is MIN_STEP. Otherwise it is `MIN_STEP/|angle|`, so the path takes longer steps when going straight and shorter ones when turning. It is clamped to `[MIN_STEP, min(R/4, 8*MIN_STEP)]` — [Adaptive.cpp ~L3355-3385](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp)
- **Pass structure.** An outer pass loop and an inner point loop. Each pass starts at an initial angle of pi/4. The cleared area is refreshed when the path direction has turned more than 45 degrees. A pass ends when no cut is found. After all passes there is a sanity check that reports "NO ENGAGEMENTS LEFT BUT NOT ALL CLEARED". Entry uses `FindEntryPoint` with a helical ramp (`helixRampTargetDiameter` defaults to the tool diameter and is clamped to at least D/8). Linking uses `FindLinkPath`, `ResolveLinkPath`, `IsClearPath`, `IsAllowedToCutTrough(areaFactor=1.5)`, and `MakeLeadPath`. A link stays at cutting depth when the path is clear and its length is at most `keepToolDownDistRatio` (3x) times the direct distance — [Adaptive.cpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp), [Adaptive.hpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.hpp)
- The finishing profile pass is offset by `stepOverScaled * FINISHING_THICKNESS_SCALE` (one tenth of the stepover) — [Adaptive.cpp ~L1770](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp)
- User-facing FreeCAD properties: Force Inside-Out, Helix Angle, Helix Cone Angle, Helix Diameter Limit, Keep Tool Down Ratio, Lift Distance, Operation Type (Clearing/Profiling), Side, Step Over ("Percent of cutter diameter"), Stock to Leave, Tolerance ("Influences accuracy and performance"), and Use Helix Arcs (G2 helix). The wiki describes the operation as one that "varies cutter engagement so that the material removal never exceeds a maximum value" — [FreeCAD wiki CAM Adaptive (mirror)](https://reqrefusion.github.io/FreeCAD-Documentation-html/wiki/CAM_Adaptive.html)
- The original 2018 add-on (`kreso-t/FreeCAD_Mod_Adaptive_Path`) was Python on **pyclipper**, with modules `EngagementPoint.py`, `Interpolation.py`, and `ProcessFeature.py`. It was described as keeping "the constant material removal rate throughout the cut", with Step Over and Step Down defining the target rate. It is now marked obsolete and merged into FreeCAD — [kreso-t/FreeCAD_Mod_Adaptive_Path](https://github.com/kreso-t/FreeCAD_Mod_Adaptive_Path)

**Autodesk Fusion / HSM Adaptive Clearing (lineage: Freesteel)**
- Fusion defines Optimal Load as "The maximum amount of engagement the Adaptive toolpath should maintain". The stepover varies to avoid overloading. Minimum Cutting Radius "Defines the smallest toolpath radius to generate in a sharp corner" and blends inside corners, leaving more material there. Further options:
  - Use Slot Clearing: start with a slot down the middle, then spiral toward the walls.
  - Feed Optimization: reduce feed at corners.
  - Stay-down level: higher levels stay down more but take longer to compute.
  - Smoothing: replaces collinear segments with lines and tangent arcs.
  - Helical ramp with a maximum helix diameter.
  - Both Ways: climb plus conventional on open profiles.

  — [Fusion 2D Adaptive Clearing reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUIDA73542E9-ED9C-4BD9-A87D-3A0ECA8BEB41.htm)
- Fusion 3D Adaptive Roughing "varies the step over and only takes climb cuts". In contrast, Offset Roughing (formerly Pocket Clearing) uses equal XY stepovers with both climb and conventional motion — [Fusion 3D Adaptive Roughing](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/3D-ADAPTIVE-READ.htm)
- Older Inventor HSM help: Adaptive Clearing "flows", eliminating conventional cutting moves and sharp direction changes. "Maximum Load = Optimal Load + Load Deviation". Autodesk claims up to 40% faster material removal — [Inventor HSM About Adaptive Clearing](https://help.autodesk.com/cloudhelp/2015/ENU/Inventor-HSM/files/GUID-970298C7-2F2E-47E6-AD54-454DEC0BBD7C.htm), [Inventor CAM Adaptive Clearing](https://help.autodesk.com/cloudhelp/2020/ENU/INVCAM/files/GUID-970298C7-2F2E-47E6-AD54-454DEC0BBD7C.htm)
- Origin: in a 2005 mailing-list post, Martin Dunschen described a Freesteel "Adaptive Clearing" system that keeps cutter engagement under a limit set at toolpath-calculation time. Autodesk forum posts later list him as an Autodesk employee who implemented Adaptive Clearing entry positions. Exact timelines of the Freesteel-to-HSMWorks transfer come from forum hearsay — [CAD_CAM_EDM_DRO archive](https://buildbotics.com/archive/cad_cam_edm_dro/messages/84807.html), [Autodesk HSM beta forum](https://forums.autodesk.com/t5/hsm-beta-testing-english-deutsch/entry-position-support-for-adaptive-clearing/m-p/6737812)

**Mastercam Dynamic Motion, SolidCAM iMachining**
- Mastercam says Dynamic Motion "continuously adjusts the toolpath trajectory to maintain consistent cutter engagement throughout the cut", managing chip thickness, radial engagement, and smooth entry/exit. It is marketing-level and gives no numbers — [Mastercam blog](https://www.mastercam.com/community/blog/how-dynamic-motion-optimizes-tool-engagement-automatically/)
- Dynamic Motion dates from the X4 release (2009). It uses dynamic stepover to hold tool load constant and trochoid-like smooth motion — [Modern Machine Shop](https://mmsonline.com/articles/dynamic-motion-moves-past-old-boundaries) (attribution via search summary; full article not read)
- SolidCAM iMachining's "morphing spiral": the inside is circular and the outer portion conforms to the feature. Stepover varies along the spiral within user min/max limits. Large areas are subdivided and islands separated by patented "Moating". A "Technology Wizard" sets feeds and speeds per path point, with an 8-level aggressiveness slider — [SolidCAM iMachining tool paths](https://solidcam.com/imachining/imachining-tool-paths/), [iMachining overview](https://solidcam.com/imachining/imachining-overview/)

**Trochoidal (circular loops along a slot or centerline): Ibaraki's algorithm**
- Ibaraki et al. (ICAM 2003) define the critical cutting regions of contour-parallel paths as sharp corners and the innermost full-immersion slot, where "the tool engagement angle abruptly increases". To clear a contour only by trochoid cycles:
  1. Offset the contour inward by the tool radius to get the set S.
  2. Compute the medial axis MA(S) from the Voronoi diagram.
  3. Choose the "centerline" edges. Voronoi edges that are not part of the medial axis are excluded, because their circles touch S at only one point.
  4. At point p on edge e_i, draw the clearance disk tangent to the two closest contour segments and crop the arc between the contact points in the heading direction.
  5. Close each cycle with a straight air-cut chord B-C instead of an arc.
  6. Advance p along e_i by a pitch "such that the maximum radial depth of cut is kept constant", and repeat edge by edge.

  — [Ibaraki et al., ICAM 2003 (PDF)](https://mecdes.hiroshima-u.ac.jp/~ibaraki.h0523/pubs/papers/icam03_ibaraki.pdf)
- The same work notes that Stori's constant-engagement algorithm "can be, however, applied only to convex contours" — [Ibaraki et al., ICAM 2003](https://mecdes.hiroshima-u.ac.jp/~ibaraki.h0523/pubs/papers/icam03_ibaraki.pdf)

**Spiral methods**
- Held & Spielberger: a spiral grows outward from an interior start point without self-intersections until it reaches the boundary. The cutting width stays above zero and below a user threshold, and smoothing yields G2 continuity. Decomposition and start-point heuristics use the Voronoi diagram of the contours (line segments and circular arcs). Multiply-connected pockets are decomposed into sub-pockets, each machined with a spiral — [Held HSM project page](https://www.cosy.sbg.ac.at/~held/projects/hsm/hsm.html)
- MATHSM (Elber, Cohen, Drake 2005): a continuous toolpath of maximal inscribed circles from the medial axis transform, joined by short tangent line segments. Arc radii are kept large to limit radial acceleration. It is especially suited to narrow, elongated pockets — [MATHSM (Scilit)](https://www.scilit.net/publications/def8a94497609a6cb992d62abd1346d1), [Elber et al. C1 5-axis follow-up (PDF)](https://www2.cs.utah.edu/gdc/publications/papers/ElberHSMI.pdf)

### Inferences

**Engagement quantities: equations to use in NativeCAM** (standard circle geometry, derived here)
- For a tool of radius R moving straight with radial width ae, the engagement angle is theta = arccos(1 - ae/R):

  | Stepover (% of D) | Engagement angle |
  |---|---|
  | 10% | 36.9 deg |
  | 15% | 45.6 deg |
  | 20% | 53.1 deg |
  | 25% | 60.0 deg |
  | 40% (Fusion default) | 78.5 deg |
  | 50% | 90 deg |
  | Full slot | 180 deg |

- The material area removed per unit travel equals ae in steady state. FreeCAD's `optimalCutAreaPD = 2*s*crescent(R/2)/R` works out to about 0.99·s·D. That is just "target ae", expressed as area per distance so that it also holds when the tool is turning or entering a corner. This is the key simplification: **control area-per-distance, not angle**.
- Chip thinning: when the engagement angle theta <= 90 deg, maximum chip thickness is fz·sin(theta). The feed-per-tooth multiplier to restore a nominal chip load is 1/sin(theta): about 1.67x at 10% stepover and 1.25x at 20%. NativeCAM's feeds UI should apply this, or adaptive on a router will rub and burn, matching the "rubbing" complaints in the router-practicality section below.

**Recommended clean-room algorithm for NativeCAM "Adaptive 2D"** (modelled on FreeCAD's structure, in Swift over Clipper2 `Paths64`)
1. **Inputs.** Pocket region as PathsD converted to Paths64 with scale = minStep/tolerance/min(1, s·D). Also tool R, stepover fraction s, stockToLeave, the stock outline, and an optional "already cleared" region (for rest machining and layered 3D).
2. **Tool-center boundary.** `toolBound = InflatePaths(region, -(R + stockToLeave))`. Initialise `cleared = (stock outside region) ∪ priorCleared`, and also treat the area outside the stock as cleared so open pockets enter from air.
3. **Entry.** If open (stock edge reachable), start from outside. Otherwise pick the point of maximum distance to the boundary (an approximate largest inscribed circle via repeated negative offsets or a distance field) and emit a helix of diameter <= D (minimum D/8). Union the helix disk into `cleared`.
4. **Pass (walk) loop.** Keep the state (pos, dir, angleHistory[3]). For each step:
   - Pick the step length L as in FreeCAD.
   - Search the heading delta in [-45, +45] deg so that `CutArea(pos, pos + L·rot(dir, delta)) / L` is within ±5% of target. Use predicted delta, then the bracket ends, then secant/regula-falsi, for at most 30 evaluations.
   - Reject candidates outside `toolBound` (rotate back in) and candidates whose conventional fraction exceeds 0.5.
   - Append the point and accumulate it into a pending "toClear" polyline. Flush that polyline into `cleared` (offset by R, round ends, union, simplify) every N steps or when the heading drifts more than 45 deg.
5. **Engagement area kernel.** Either port FreeCAD's sweep-line idea (clean-room) or use Clipper2: `Area(Difference(Difference({disk(c2)}, {disk(c1)}), clearedLocal))`, with `clearedLocal` from a cached window. The Clipper version is simpler but slower: one or two boolean operations per heading trial. Use it first, profile, then replace it with an analytic circle-polygon kernel.
6. **End of pass and re-engage.** When the area is 0 or the boundary is hit, search the boundary of `cleared ∩ toolBound`-reachable material for the next engage point. Prefer the nearest point that restarts in climb direction. Link at depth if the link path is inside `cleared`, keeps R clearance, and is no longer than 3x the direct distance. Otherwise lift by "lift distance" (not full retract) and traverse.
7. **Finish.** Run an optional profile pass at stepover/10, then fit lines to arcs (G2/G3) with tolerance for Mach4. Mark link moves so the post can use G0 or a higher feed.
8. **Output.** Segments tagged as Cutting, LinkClear, or LinkNotClear, so the existing simulator and post-processor can colour them, apply feeds, and estimate time with acceleration.

**Layered 3D roughing reuse**
- FreeCAD's `Execute` already takes `clearedPaths`. The same entry point serves rest machining and Z-level roughing: at each Z level, region = (stock slice) minus (model slice offset by stock-to-leave), and `clearedPaths` = what the previous (higher) level and earlier tools already removed. NativeCAM's existing layered roughing can call the adaptive kernel per layer instead of the offset kernel. The same "cleared" concept prevents re-cutting air at lower layers.
- **Use Slot Clearing** (start with a central slot, then spiral out) and **Minimum Cutting Radius** (corner blending) are worth copying as options. Both reduce the number of tiny re-engagements, which matters on low-acceleration machines.

**Simulation alternatives (bitmap/raster)**
- A raster "stock" (for example a 0.05–0.1 mm grid stored as a bitset, or a height map for 3D) makes the cut-area query a pixel count inside the new disk and outside the old one. It is simple, robust to degenerate geometry, and easy to vectorise with SIMD or Metal on Apple silicon. Its accuracy is limited by cell size: at a 10% stepover on a 6 mm tool, ae = 0.6 mm is only 6–12 cells wide. The polygon approach (FreeCAD) is more accurate and memory-light. A raster is attractive for the 3D height-field roughing case, where NativeCAM may already have a heightmap.

**Choosing among the families for NativeCAM**
- Walk/simulation (FreeCAD-style): most general (islands, open pockets, rest), but heavy compute and least predictable output.
- Medial-axis spiral: elegant, but needs a robust Voronoi diagram and handles islands only with decomposition.
- Trochoidal along the medial axis: easiest to implement correctly, but has the most air-cut time.
- Pragmatic first step: trochoidal slotting plus offset pocketing with corner engagement limits (an Ibaraki/Zhao-style hybrid). Then the full walk algorithm.

### Gaps
- I could not confirm whether the original 2018 FreeCAD/kreso implementation used a bitmap or polygons for engagement. Its pyclipper dependency suggests polygons, but this is inference. I found **no open-source implementation that uses a pixel/bitmap engagement model** for 2D adaptive clearing in this session.
- No primary technical description of Fusion's or Mastercam's internal algorithms is public. Vendor pages are qualitative.
- Vectric (VCarve/Aspire): no official documentation found confirming a trochoidal or adaptive pocket option. Searches of Vectric docs and release notes turned up none, and forum users say Vectric's adaptive/trochoidal capability lags Fusion — [mycncuk thread](https://www.mycncuk.com/threads/11221-Vectric-crazy-pocket-strategies), [Vectric V12 pocket docs](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/form/uiPocketMachineForm/index.html). Treat any claim of a Vectric "Trochoidal" option as unverified.
- Carbide Create: no official release note found confirming an adaptive toolpath. A community thread asks whether adaptive is planned, and a third-party source says adaptive requires other CAM programs — [Carbide 3D community "Adaptive toolpaths"](https://community.carbide3d.com/t/adaptive-toolpaths/63704), [Carbide 3D community toolpath strategies](https://community.carbide3d.com/t/toolpath-strategies-for-the-layman/14080).
- Kiri:Moto: I could not verify whether it has an adaptive or trochoidal clearing operation. The documentation URL I tried returned 404, and the GitHub API was rate-limited.

## Key papers: what each contributes and how hard it is to implement

### Takeaway
The literature splits into three groups:
- **Engagement-controlled offsetting:** Stori & Wright 2000 (convex only); Uddin/Ibaraki 2006 (arbitrary contours).
- **Smooth spirals:** Held & Spielberger 2009/2014 (Voronoi-based, bounded stepover, islands via decomposition); Bieterman & Sandstrom 2003 (elliptic PDE, convex only); Banerjee et al. 2012 (morphed biarc spiral); Elber/Cohen/Drake MATHSM 2005 (medial-axis circles, narrow pockets).
- **Local fixes:** Ibaraki 2003/2010 trochoidal grooving of critical regions; Zhao 2007 corner biarcs.

None is as general or as practical as the walk algorithm in FreeCAD. For NativeCAM, the papers are most useful for corner and slot handling and for smooth-spiral options on simple pockets.

### Cited Findings
- **Stori & Wright, "Constant engagement tool path generation for convex geometries".** A spiral-in algorithm for 2.5D removal from convex shapes. Simulations show far less engagement variation than contour-parallel paths and near-constant MRR, and dynamometer data show instantaneous engagement correlates closely with cutting force — [catalog record/abstract](https://bvbvf1.bib-bvb.de/vufind/PrimoRecord/cdi_proquest_journals_197658988). It is restricted to convex contours — [Ibaraki et al. 2003](https://mecdes.hiroshima-u.ac.jp/~ibaraki.h0523/pubs/papers/icam03_ibaraki.pdf). Later literature calls the method "constant engagement offsetting" — [Springer IJAMT 2019](https://link.springer.com/article/10.1007/s00170-019-03834-8)
- **Uddin, Ibaraki et al.,** "Constant Engagement Tool Path Generation to Enhance Machining Accuracy in End Milling", JSME Int. J. Series C 49(1):43–49 (2006). An arbitrary-contour extension of constant-engagement offsetting — [J-STAGE](https://www.jstage.jst.go.jp/article/jsmec/49/1/49_1_43/_article), [abstract](https://mecdes.hiroshima-u.ac.jp/~ibaraki.h0523/pubs/abstract/jsmeint06_uddin.html). Ibaraki's 2004 JUSFA paper states their algorithm "can be applied to an arbitrary contour geometry, unlike the Stori's algorithm" — [JUSFA 2004 PDF](https://mecdes.hiroshima-u.ac.jp/~ibaraki.h0523/pubs/papers/jusfa04_ibaraki.pdf)
- **Ibaraki, Yamaji, Matsubara,** "On the removal of critical cutting regions by trochoidal grooving", Precision Engineering 34(3):467–473 (2010). Critical regions (sharp corners, narrow slots) are extracted from the medial axis, and the trochoidal path is also generated from the medial axis — [abstract](https://mecdes.hiroshima-u.ac.jp/~ibaraki.h0523/pubs/abstract/pe10_yamaji.html)
- The ICAM 2003 precursor (hardened steel) gives the algorithm reproduced in the first section. Results:
  - Total time: 348 s for contour-parallel only, versus 573 s with trochoidal grooving.
  - Excluding the shared outer contour-parallel paths: 210 s versus 440 s.
  - Cutting force in the trochoid cycles was only about 70–80 N, lower than in the corresponding contour-parallel section.
  - The authors note every trochoid cycle contains an air cut and suggest raising the feed or pitch.

  The 40-degree critical engagement threshold is from this line of work (per search summary of the ICAM 2003 paper) — [Ibaraki et al. 2003 PDF](https://mecdes.hiroshima-u.ac.jp/~ibaraki.h0523/pubs/papers/icam03_ibaraki.pdf)
- **Wang et al. 2018:** radius-varying trochoidal milling to keep cutting force constant at critical regions — [Springer IJAMT s00170-018-2298-x](https://springerlink.bibliotecabuap.elogim.com/content/pdf/10.1007/s00170-018-2298-x.pdf)
- **Held & Spielberger:**
  - "A Smooth Spiral Tool Path for High Speed Machining of 2D Pockets", CAD 41(7):539–550 (2009), doi:10.1016/j.cad.2009.04.002.
  - "Improved Spiral High-Speed Machining of Multiply-Connected Pockets", CAD&A 11(3):346–357 (2014), doi:10.1080/16864360.2014.863508.
  - Held & de Lorenzo, "On the Generation of Spiral-Like Paths Within Planar Shapes", JCDE 5(3):348–357 (2018).

  The reported experiments show shorter paths, less curvature and engagement variation, and a smaller max/min stepover ratio — [Held HSM project](https://www.cosy.sbg.ac.at/~held/projects/hsm/hsm.html). The spiral interpolates growing disks placed on the medial axis and is guaranteed free of self-intersections without retractions. The 2009 method handled only simply-connected pockets — [search summary of arXiv 1412.5034 context](https://ar5iv.arxiv.org/html/1412.5034)
- **Abrahamsen et al., "Spiral Toolpaths for High-Speed Machining of 2D Pockets with or without Islands"** (arXiv 1412.5034) — [arXiv](https://arxiv.org/pdf/1412.5034). A closely related US patent exists: US10108172B2, "Spiral toolpaths for high-speed machining of polygonal pockets" — [Google Patents](https://patents.google.com/patent/US10108172)
- **Elber, Cohen, Drake, "MATHSM: medial axis transform toward high speed machining of pockets",** CAD 37(2):241–250 (2005). Arcs of maximal inscribed circles joined by tangent segments, large radii to limit radial acceleration, suited to narrow, elongated pockets — [Scilit](https://www.scilit.net/publications/def8a94497609a6cb992d62abd1346d1), [Technion PDF](https://gershon.cs.technion.ac.il/papers/hsm.pdf). Extended to 3D/5-axis (impellers) in "C1 Continuous Toolpath Generation Toward 5-axis HSM" — [Utah PDF](https://www2.cs.utah.edu/gdc/publications/papers/ElberHSMI.pdf)
- **Bieterman & Sandstrom (2003, Boeing),** curvilinear spiral. An elliptic PDE boundary-value solution morphs a smooth low-curvature interior spiral into one that conforms to the pocket boundary. Reported results: time savings in aluminum, and in titanium nearly 100% tool-life gain with a small cycle-time increase — [Modern Machine Shop](https://mmsonline.com/articles/curvilinear-tool-paths-for-pocket-machining). A later comparison says it suits only globally convex pockets without islands, and that a reparameterised spiral (Leroy et al.) cuts milling time 10–18% versus Bieterman–Sandstrom — [Applied Sciences 14:7492 (UMONS)](https://orbi.umons.ac.be/bitstream/20.500.12907/49560/1/applsci-14-07492-1.pdf)
- **Banerjee, Feng, Bordatchev,** "Process planning for floor machining of 2½D pockets based on a morphed spiral tool path pattern", Computers & Industrial Engineering 63(4):971–979 (2012). A G1 biarc/arc-spline morphed spiral with feed selection under cutting-force limits, which can handle islands. It showed shorter path length and dry-run time than commercial CAM — [IAOR record](https://iaorifors.com/paper/82242), [researchr bibtex](https://researchr.org/publication/BanerjeeFB12/bibtex)
- **Zhao, Wang, Zhou, Qin,** "Pocketing toolpath optimization for sharp corners", J. Materials Processing Technology (2007), pp. 175–180. Inserts biarc transitions in contour-parallel paths at sharp corners to remove corner residue and avoid engagement spikes — [index record](https://manuscript.isc.ac/Inventory/10/1181245.htm), [related abstract](https://www.scientific.net/KEM.407-408.198)
- **Rauch et al. (trochoidal):** studied CNC implementation and parameter selection for tool life, including machine-tool dynamic capability and the evolution of radial depth of cut, with circular versus cycloidal trochoid models — [summary in NSF PAR paper](https://par.nsf.gov/servlets/purl/10149559). Separately, it has been noted that trochoids are often generated without considering NC interpolation effects — [White Rose eprint, FIR interpolation trochoidal case study](https://eprints.whiterose.ac.uk/id/eprint/225331/1/Accurate%20real-time%20trajectory%20generation%20of%20circular%20motion%20using%20FIR%20interpolation%20-%20a%20trochoidal%20milling%20case%20study.pdf)
- **Patents to be aware of:** "Engagement milling" patents (US 7,451,013 and applications 2005/0246052 and 2005/0256604) — [Justia 7451013](https://patents.justia.com/patent/7451013), [Justia 20050246052](https://patents.justia.com/patent/20050246052). An EPO patent "Method of optimizing toolpaths using medial axis transformation" (EP2685332A3) — [EPO](https://data.epo.org/gpi/EP2685332A3). SolidCAM describes "Moating" as patented — [SolidCAM](https://solidcam.com/imachining/imachining-tool-paths/)

### Inferences
- **Implementation difficulty for a Swift developer with Clipper2:**

  | Approach | Difficulty | Main dependency or risk |
  |---|---|---|
  | Zhao corner biarcs, or corner loops added to the existing offset pocket | Low | None new |
  | Ibaraki trochoid along a centerline | Low–medium | Medial axis; for a plain slot the centerline is trivial |
  | FreeCAD-style walk | Medium–high (~2–4k lines) | Robustness work dominates |
  | Held spiral / MATHSM | High | Robust Voronoi diagram of segments and arcs, plus decomposition heuristics |
  | Bieterman PDE / Banerjee morphing | High | PDE solver or morphing machinery; limited to convex or single-island pockets |

- The walk algorithm subsumes Stori & Wright's goal (constant engagement) without the convexity restriction. That is why commercial and FreeCAD implementations converged on it.
- Patent risk is real in this field. Several "engagement milling" filings date from about 2004–2005 and may have expired by 2026 (20 years from filing), but **expiry and claims need checking by counsel**. Clean-room implementation from FreeCAD's documented ideas does not avoid patents.

### Gaps
- I did not retrieve the full text of Stori & Wright. Its venue and year (commonly cited as J. Manufacturing Systems, 2000) were not verified in this session.
- I did not verify the assignee, priority dates, or legal status of US10108172B2, US7451013, or EP2685332.
- The full Held & Spielberger papers were not read. Their specific stepover-bounding construction and runtimes are not captured here.
- I found no paper reporting results specifically in wood or MDF on router-class machines.

## Open-source implementations: repos, exact licenses (SPDX), code locations, and use in a closed-source app

### Takeaway
The only mature open-source **adaptive clearing** engine found is FreeCAD's `Adaptive.cpp`, licensed **LGPL-2.1-or-later**. It now runs on Clipper2 (BSL-1.0, the same base NativeCAM uses). Its code can be used in a closed-source app only as a separately replaceable LGPL library with source and license offered. A Swift port would be a derivative work under LGPL. Most other open CAM projects (jscut, BlenderCAM, CAMotics, pycam) are GPL, so they cannot be embedded in closed-source code. Permissive building blocks (Clipper2 BSL-1.0, Kiri:Moto MIT) do not include an adaptive clearer.

### Cited Findings

| Project | License (as found) | Relevance / location | Source |
|---|---|---|---|
| FreeCAD CAM Adaptive | `SPDX-License-Identifier: LGPL-2.1-or-later` in file header; repo license LGPL-2.1 | `src/Mod/CAM/libarea/Adaptive.cpp`, `Adaptive.hpp`; Python glue in FreeCAD CAM workbench; now on Clipper2 | [Adaptive.cpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp), [GitHub API repo metadata](https://api.github.com/repos/FreeCAD/FreeCAD) |
| kreso-t/FreeCAD_Mod_Adaptive_Path (original 2018 Python add-on) | **No license file in repo**; GitHub reports no license (default "all rights reserved" for the repo copy; the merged code is LGPL inside FreeCAD) | `Adaptive/EngagementPoint.py`, `Interpolation.py`, `ProcessFeature.py`; uses pyclipper; obsolete | [repo](https://github.com/kreso-t/FreeCAD_Mod_Adaptive_Path) |
| libarea (Heeks) | GitHub API reports **no detected license**; a `License.txt` could not be fetched | Offset pocketing (`AreaPocket.cpp`), Clipper 1; not adaptive. FreeCAD's copy lives in `src/Mod/CAM/libarea/` alongside Adaptive.cpp | [Heeks/libarea](https://github.com/Heeks/libarea), [FreeCAD libarea dir](https://github.com/FreeCAD/FreeCAD/tree/main/src/Mod/CAM/libarea) |
| Clipper2 (Angus Johnson) | **BSL-1.0** | Polygon boolean, offset, triangulation (C++, C#, Delphi) | [AngusJohnson/Clipper2](https://github.com/AngusJohnson/Clipper2) |
| Kiri:Moto (grid-apps) | **MIT** | Browser CAM; adaptive/trochoidal capability not verified | [GridSpace/grid-apps](https://github.com/GridSpace/grid-apps) |
| OpenCAMLib | **LGPL-2.1** | Drop-cutter/waterline 3D primitives; not adaptive clearing | [aewallin/opencamlib](https://github.com/aewallin/opencamlib) |
| OpenVoronoi | **LGPL-2.1** | Segment/point Voronoi, medial axis (useful for trochoid centerlines and spirals) | [aewallin/openvoronoi](https://github.com/aewallin/openvoronoi) |
| jscut | **GPL-3.0** | In-browser CAM; offset pocketing | [tbfleming/jscut](https://github.com/tbfleming/jscut) |
| CAMotics | GPL (LICENSE: "GNU General Public License"); GitHub reports NOASSERTION | G-code simulator and CAM | [CauldronDevelopmentLLC/CAMotics](https://github.com/CauldronDevelopmentLLC/CAMotics) |
| BlenderCAM | **GPL-3.0** (vilemduha and pppalain forks) | Blender CAM add-on | [vilemduha/blendercam](https://github.com/vilemduha/blendercam) |
| pycam | GitHub reports NOASSERTION for SebKuzminsky/pycam | Not verified | [SebKuzminsky/pycam](https://github.com/SebKuzminsky/pycam) |

- The FreeCAD class comment reads: "used to isolate state -> enable potential adding of multi-threaded processing of separate regions" — [Adaptive.hpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.hpp)

### Inferences
- **For NativeCAM (closed source), the options are:**
  - (a) **Clean-room reimplementation** in Swift from the algorithm description above. The ideas (area-per-distance target, heading search, cleared-area polygon model, link rules) are not copyrightable, though patents may apply. This is the recommended path.
  - (b) **Ship FreeCAD's Adaptive.cpp unmodified as a separate dynamic library or framework** under LGPL-2.1-or-later, with its source, the license text, and the user's ability to replace it. On the Mac App Store, LGPL compliance is debated and usually avoided. Outside the App Store (notarised direct download), a dylib is workable. Static linking requires providing relinkable object files.
  - (c) Do not copy from GPL projects (jscut, BlenderCAM, CAMotics) at all.
- Because both NativeCAM and FreeCAD's adaptive now use Clipper2 `Paths64`, data structures map one-to-one. A clean-room Swift implementation can mirror the same operations (`InflatePaths` with round ends, `Union` EvenOdd, `Intersect` with a window rectangle, `SimplifyPaths`) without crossing a C++ boundary per step. Alternatively, it can call a thin Swift-to-C++ Clipper2 bridge NativeCAM may already have.
- For medial-axis or trochoid work in a closed-source app, avoid OpenVoronoi (LGPL) and CGAL (GPL or commercial; not verified here). Boost.Polygon's Voronoi (Boost Software License) is generally permissive, but its license was not verified in this session. A simple trochoidal slot along an open path needs no Voronoi at all.
- This is not legal advice. Check the LGPL App Store question and the patents with counsel before shipping option (b).

### Gaps
- libarea's exact license (commonly said to be BSD-style) and pycam's could not be confirmed. GitHub returned no SPDX ID and the license file fetch failed. The GitHub API was rate-limited later in the session.
- I did not confirm whether a FreeCAD release (as opposed to `main`) already ships the Clipper2-based Adaptive.
- Kiri:Moto, fabex (BlenderCAM successor), and a standalone "adaptive2d" repo were not verified. `kreso-t/adaptive2d` returned 404 on GitHub.

## When does adaptive clearing pay off on a gantry router in wood/plywood/MDF? Settings, feeds, acceleration effects, practitioner reports

### Takeaway
On hobby or prosumer gantry routers, adaptive clearing pays off mainly when **deep pockets can be cut at or near full flute depth with low radial engagement** (roughly 10–25%), in hardwoods or dense sheet goods where a full-width offset pass would force low feeds or deflection. It also helps when slotting or corners would otherwise overload a small tool. For shallow pockets (depth under about 1x D), small features, or low acceleration settings, offset pocketing is often as fast or faster. Adaptive adds non-cutting moves and many small loops whose speed is capped by acceleration (v = sqrt(a·r)), and CAM time estimates ignore this. Avid users report Mach4 acceleration settings from about 15 to 50 in/s².

### Cited Findings
- A Onefinity user (cyberreefguru): consistent engagement lets you "cut faster and deeper", but adaptive has more non-cutting moves, so at the same feeds and speeds it "will usually take longer than a normal pocket". Use different settings for adaptive. Another user (CandL) uses FreeCAD Adaptive for nearly all his wood work — [Onefinity forum](https://forum.onefinitycnc.com/t/general-questions-on-machining-adaptive-clearing/11409)
- Shapeoko 2 owner: in hardwood, adaptive ran about 60 ipm with a 1/8" 2-flute without missed steps, but pocketing had to drop to 30–35 ipm. Advice: create both and compare times. A Fusion thread warns that 3D adaptive is retract-heavy on machines with slow Z — [Autodesk forum "Inefficient 2D adaptive"](https://forums.autodesk.com/t5/fusion-manufacture/inefficient-2d-adaptive-clearing-toolpath/m-p/5608904), [Autodesk forum "wasteful extra motions"](https://forums.autodesk.com/t5/fusion-manufacture-forum/adaptive-clearing-wasteful-extra-motions-and-how-can-i-optimize/td-p/7143562)
- 3D adaptive estimate of 75 minutes versus about 180 minutes actual. Others suggested a 2D pocket would be faster and just as good on a router — [Autodesk forum "3D Adaptive Clearing Woes"](https://forums.autodesk.com/t5/fusion-360-manufacture/3d-adaptive-clearing-woes/td-p/10142655)
- MPCNC user: CAM time estimates ignore acceleration and block-processing speed, and this matters most for adaptive clearing with its many short moves — [V1 Engineering forum](https://forum.v1engineering.com/t/should-i-skip-roughing-pass-cutting-xps-foam/20446)
- X-Carve: the gantry "can't handle increased cutting depths very well, even if you decrease the stepover to compensate". Another user reports adaptive running "upwards of 200 ipm" in hard and soft woods — [Inventables forum](https://community.inventables.com/t/implementing-adaptive-clearing-strategies-on-an-x-carve/26312)
- Shapeoko community: run shallower DOC even with adaptive (for example, halve it). In a 96-hour MDF 3D adaptive job, the minimum stepdown was too small and the feed too slow — [Carbide 3D "Playing with adaptive today"](https://community.carbide3d.com/t/playing-with-adaptive-today/32136), [Carbide 3D "Faster 3D adaptive clearing"](https://community.carbide3d.com/t/faster-3d-adaptive-clearing/78434)
- Fusion defaults per forum: Optimal Load defaults to `tool_diameter*0.4` (Shift-hover reveals the expression) — [Fusion forum "optimum load"](https://forums.autodesk.com/t5/fusion-manufacture/optimum-load/m-p/7265596). With "Multiple depths", the adaptive stepdown defaults to min(10 mm, flute length) — [Fusion forum "Recommended stepdown"](https://forums.autodesk.com/t5/fusion-manufacture-forum/recommended-stepdown-for-adaptive-clearing/m-p/6891051/highlight/true). Carbide 3D users describe adaptive as HSM, favouring large DOC with small stepover, with chipload around 0.001–0.002 in — [Carbide 3D "Issues with Fusion 360 adaptive clearing"](https://community.carbide3d.com/t/issues-with-fusion-360-adaptive-clearing/8545)
- **Avid / Mach4 acceleration (forum users, not Avid staff):**
  - The Avid default is believed to be about 50 in/s².
  - Users report 35 in/s² fixing shaking on a PRO 60x120, 25 in/s² greatly improving V-carve quality, and 15 in/s² as a normal working value (15–30 for less critical work).
  - Direction changes reduce chip load, and lower acceleration lengthens the reduced-load period.
  - Acceleration-limited starts and ends of paths run below optimal chip load and rub, shortening tool life and burning material.
  - Lead-in/ramp feeds far below the cut feed make the gantry jerk; keep them within about 15% of the cut feed.

  — [Avid CNC forum "Mach 4 Acceleration/Deceleration"](https://forum.avidcnc.com/t/mach-4-acceleration-deceleration/1123)
- Avid's Mach4 configuration guide lists per-axis max velocity and counts per unit — [Avid Mach4 Configuration Guide 2023Q3](https://www.avidcnc.com/cad/2023Q3/Mach4_Configuration_Guide_v2023Q3_1.pdf)
- An Avid PRO 4896 user (3 hp spindle, Baltic birch, downcut spirals) takes passes under 0.20" and leaves stock for a full-depth finishing pass — [Autodesk forum plywood edge quality](https://forums.autodesk.com/t5/fusion-manufacture/how-to-maximize-plywood-edge-cut-quality-in-fusion-360-cam/td-p/11449015)
- Trochoidal grooving in Ibaraki's (steel) test roughly doubled the time of the slot and corner portions versus contour-parallel paths (440 s vs 210 s), because every cycle includes an air cut — [Ibaraki et al. 2003](https://mecdes.hiroshima-u.ac.jp/~ibaraki.h0523/pubs/papers/icam03_ibaraki.pdf)
- Fusion's Minimum Cutting Radius warns that forcing the tool into a sharp corner, or one equal to the tool radius, can cause chatter — [Fusion 2D Adaptive reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUIDA73542E9-ED9C-4BD9-A87D-3A0ECA8BEB41.htm)

### Inferences
- **Acceleration cap on loops (centripetal: v_max = sqrt(a·r)):**

  | Accel a | Loop radius r | Max feed (in/s) | Max feed (ipm) |
  |---|---|---|---|
  | 15 in/s² | 0.125 in | 1.37 | 82 |
  | 15 in/s² | 0.25 in | 1.94 | 116 |
  | 15 in/s² | 0.5 in | 2.74 | 164 |
  | 25 in/s² | 0.25 in | 2.5 | 150 |
  | 50 in/s² | 0.25 in | 3.54 | 212 |

  Reaching 200 ipm (3.33 in/s) from rest at 15 in/s² takes 0.22 s and 0.37 in. For 1/4" tools, trochoid and re-engagement loops with radius at or below the tool radius cannot reach typical wood chip-load feeds (150–300 ipm) unless acceleration is raised. This is the core router-specific caveat.
- **NativeCAM should:**
  - (1) Enforce a **minimum toolpath curvature radius** (Fusion-style "minimum cutting radius", for example at least 0.5–1x tool diameter) and smooth headings, so loops stay large.
  - (2) Prefer **stay-down links** and Use-Slot-Clearing-style ordering over many small re-engagement loops.
  - (3) Include an **acceleration-aware time estimate**, using the machine profile's per-axis accel (Avid users run 15–50 in/s²), so users can compare Adaptive versus Offset honestly.
  - (4) Fit **arcs (G2/G3)** in output to cut block count for Mach4's planner.
  - (5) Apply **chip-thinning feed compensation** (1/sin(theta)), otherwise the low engagement rubs and burns wood or MDF.
- **Rule of thumb for when to offer Adaptive by default in NativeCAM:** pocket depth at least 1.5–2x D and the tool can cut that depth in one pass (flute length permitting); hardwood, phenolic, aluminium, or dense MDF; or small tools (1/8") where full-width slotting breaks bits. Otherwise default to Offset with corner-engagement limiting.
- **Suggested starting UI defaults for wood on an Avid-class gantry** (to validate in testing, not sourced as a recipe):
  - Optimal load 10–20% of D for DOC of 1–2x D; 25–40% for DOC at or below 0.5x D.
  - Feed derived from chipload x chip-thinning factor, capped by the acceleration-based loop limit.
  - Helix entry at no more than D diameter and a 2–3 degree ramp.

### Gaps
- I found no controlled time study of adaptive versus offset pocketing in plywood or MDF on Avid, Shapeoko, or Onefinity machines. Evidence is anecdotal forum reports.
- The "10–25% stepover at full flute depth" recipe is widely repeated, but I found no authoritative wood-specific source in this session.
- No Avid-staff-published acceleration values were found. The 50 in/s² default is a forum user's statement. Mach4 lookahead and constant-velocity behaviour on short segments was not documented in the sources retrieved.

## Performance: computational cost and how implementations stay fast enough for interactive use

### Takeaway
Adaptive clearing is far more expensive than offset pocketing. Each step requires several cut-area evaluations (up to 30) against an evolving cleared-region model. FreeCAD's tolerance setting trades accuracy for speed, and its docs advise deactivating the operation while editing parameters. Implementations stay usable through four techniques: (1) spatially windowed or cached queries of the cleared region, (2) bounding-box culling, (3) an analytic (not boolean-op) area kernel plus angle prediction to cut iterations, and (4) lazy, batched union of swept area, with progress callbacks and region-level parallelism.

### Cited Findings
- FreeCAD documents Tolerance as "Influences accuracy and performance". Because of recompute cost, it suggests deactivating the operation (Active toggle), changing properties, and then re-activating, rather than recomputing after every change — [FreeCAD wiki CAM Adaptive (mirror)](https://reqrefusion.github.io/FreeCAD-Documentation-html/wiki/CAM_Adaptive.html)
- FreeCAD speed techniques visible in code:
  - Two-level cleared-area window cache (window = 10x query box).
  - Bounding-box rejection of cleared polygons before area integration.
  - Analytic sweep-line cut-area integration.
  - Angle prediction from the last 3 steps plus interpolation, with at most 30 iterations.
  - Variable step length, longest on straight runs.
  - Deferred `ExpandCleared`, run only when the direction changes more than 45 degrees or a search needs it.
  - `SimplifyPathsFilterPancakes` to keep polygon vertex counts down.
  - `PerfCounter` instrumentation (CalcCutArea, ExpandCleared, DistanceToBoundary, PointIterations).
  - A progress callback every 1/10 s that can stop processing.
  - State isolated per region "to enable potential adding of multi-threaded processing of separate regions".

  — [Adaptive.cpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.cpp), [Adaptive.hpp](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.hpp)
- Fusion notes that higher stay-down levels increase calculation time — [Fusion 2D Adaptive reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUIDA73542E9-ED9C-4BD9-A87D-3A0ECA8BEB41.htm)
- Ibaraki notes the critical region always lies on the medial axis, so engagement only needs computing at contact points between the medial axis and the paths. This is a cheap check that avoids full simulation — per search summary of [Ibaraki et al. ICAM 2003](https://mecdes.hiroshima-u.ac.jp/~ibaraki.h0523/pubs/papers/icam03_ibaraki.pdf)

### Inferences
- **Cost model.** Total cost is roughly steps x iterations x cost(area query). Steps scale as (path length)/(step), and path length scales as pocket area/(stepover width). Halving the stepover doubles the path length, and tightening tolerance increases steps per stepover (FreeCAD: 1/tolerance minimum steps per stepover). Expect seconds for typical sign or cabinet pockets on Apple silicon if the area query is analytic and windowed, but tens of seconds if every trial does two Clipper booleans against the whole cleared set.
- **NativeCAM-specific plan:**
  1. Run each disconnected region and each Z-layer on separate tasks with Swift concurrency. Regions are independent, and per-layer 3D roughing can pipeline once the layer's "previously cleared" input is known.
  2. Keep the cleared region in a spatial index: a uniform grid of tiles holding clipped Paths64, so local queries touch about 1–4 tiles.
  3. Start with Clipper2 boolean-based area, profile, then replace it with an analytic circle-polygon area kernel in SIMD Swift.
  4. Stream partial paths to the UI via a progress callback (as FreeCAD does) and allow cancellation.
  5. Cache results by a hash of the geometry and parameters, and debounce recompute while sliders move.
  6. For 3D roughing, consider a coarse preview tolerance (for example 2–4x) during editing and full tolerance for posting.
- A Metal raster engagement model is an option for 3D roughing previews (a GPU disk-minus-mask pixel count). For 2D posting, the polygon approach is more accurate per unit of compute.

### Gaps
- I found no published benchmark timings for FreeCAD Adaptive, Fusion, or others on standard test pockets. Real runtimes would need local benchmarking, for example by building FreeCAD's `Adaptive.cpp` standalone (LGPL, fine for internal benchmarking) against representative NativeCAM jobs.
- Papers on medial-axis spirals report quality metrics, but the abstracts retrieved gave no runtime figures.
