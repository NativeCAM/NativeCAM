# 3-Axis Finishing Toolpath Strategies for Wood Reliefs (NativeCAM)

Context: NativeCAM today has one 3D finishing strategy, implemented in `/Users/dsmith/natcam/Sources/CAMCore/Toolpath/Model3DGenerator.swift` (`finish()`). It does a zig-zag raster at a chosen angle. Rows are clipped to the boundary with Clipper and sampled at a fixed step `ds = max(cellSize, 0.15)`. Each row is dropped in parallel with `DispatchQueue.concurrentPerform` and then simplified with `simplify3D`, and rows are linked at depth when the hop is ≤ 3 × stepover. The exact drop-cutter, `/Users/dsmith/natcam/Sources/CAMCore/Toolpath/TriangleDropCutter.swift`, supports only ball and flat cutters. It uses a uniform XY bin grid with `binSize = max(2R, 1)` and tests every triangle in the overlapping bins. These notes read against that baseline.

## Q1. Which finishing strategies to add, when each wins, and the scallop math on slopes

### Takeaway
For wood reliefs, the strategies worth the most effort, in order, are:
1. A second raster at 90° to the first (cross-hatch), plus a free choice of raster angle for grain.
2. Steep-and-shallow: waterline (constant Z) on steep areas and raster or offset on shallow areas, split by a slope threshold of about 30–45° with an overlap band.
3. Constant-scallop / 3D-offset finishing.
4. Pencil cleanup and rest machining with a smaller (tapered) ball.

Spiral, radial and morphed-spiral are niche: round, shallow features such as coins and domes. The governing fact is that a raster's XY stepover stretches on slopes that rise across the rows. Its effective spacing is s/√(1 − sin²θ·sin²φ), which grows to s/cosθ in the worst case, and scallop height grows with the square of that spacing.

### Cited Findings
**Commercial strategy definitions**
- Fusion **Parallel** finishing uses a *horizontal* (XY) stepover. The help says parallel passes "are best suited for shallow areas." It offers "Machine Steep Areas", which adds passes "where the surface is steep perpendicular to the machining direction", and "Add Perpendicular Passes" (cross-hatch) to reduce cusps, with Minimum Steep Stepover and Maximum Steep Stepdown settings. Pass Direction sets the row angle, and passes can also be limited to a maximum contact angle — [Fusion Parallel Finishing reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID17CC1F90-A2A5-4CC3-80EB-B7972E327E0F.htm)
- Fusion **Slope Confinement** measures slope "from horizontal". Its examples pair Parallel limited to 0–45° with Contour (waterline) limited to 45–90°, and the help says most 3D finishing strategies support it — [Fusion Slope Confinement reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID544B46E7-E0EC-47C3-B50B-7252CB8303F0.htm)
- Fusion **Steep and Shallow** uses a threshold angle measured from horizontal. Steep areas get Contour passes and shallow areas get Parallel or Scallop passes. The threshold is "usually" around 30–45°, and setting it to 90° gives only shallow passes while 0° gives only steep passes. An overlap distance blends the two strategies so the seam is less visible — [Autodesk blog: Why Steep and Shallow](https://www.autodesk.com/products/fusion-360/blog/why-steep-and-shallow/); [Fusion Steep and Shallow reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID-A6933B73-D98F-43AD-BCFD-A450D91C4E61.htm)
- The Fusion Steep and Shallow help describes it as combining "the styles of Scallop and Contour into a single operation". Steep and shallow areas have separate cutting parameters, and an "Avoid Flat Areas" option skips flats so a flat end mill can do them later — [Fusion Steep and Shallow milling strategy](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/3D-STEEP-AND-SHALLOW-READ.htm)
- A 2019 Fusion blog post said continuous passes were "not currently available" in the Scallop toolpath; this may be out of date — [Autodesk blog: Fusion 360 extensions steep & shallow](https://www.autodesk.com/products/fusion-360/blog/fusion-360-extensions-steep-shallow/)
- Fusion **Scallop** creates passes "at a constant distance from one another by offsetting them inwards along the surface". The passes follow sloping and vertical walls, which holds the stepover. If "Limit Number of Stepovers" is disabled, the result is a "collapsed pencil finish" of the whole surface. Direction options are One Way (climb relative to the boundary), Other Way (conventional), Both Ways (shortest) and Up/Down milling — [Fusion Scallop Finishing reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID77067110-3D88-4DA7-B171-6B27F04CF8B3.htm)
- Fusion **Morphed Spiral**: the help says bull-nosed and ball end mills are best suited to it — [Fusion: Generate a Morphed Spiral toolpath](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/3D-MORPHED-SPIRAL-STEPS.htm)

**Morphed spiral and scallop in practice (search-snippet level; individual thread attribution not verified by fetch)**
- One user said morphed spiral works on "somewhat round" regions within about 45° of level but gives poor results on steeper surfaces, because its stepover is near-constant in XY rather than on the surface — [Autodesk forum](https://forums.autodesk.com/t5/fusion-manufacture/correct-toolpath-for-this-object/m-p/10067379)
- Another user said morphed spiral "looks great on the computer screen" but cut worse than Scallop, and settled on a scallop + parallel combination — [Carbide 3D community](https://community.carbide3d.com/t/surface-finish-with-scallop-toolpath/56921)
- A tutorial recommends spiral, radial or morphed spiral for circular features — [LinkedIn Learning: Learning Fusion 360 CAM](https://www.lynda.com/Fusion-360-tutorials/3D-finishing/2282150/2297188-4.html)

**PowerMill**
- **Optimised Constant Z** puts constant-Z passes on steep areas and 3D-offset passes on shallow areas, to reduce the stair-stepping that plain constant Z leaves on shallow surfaces. Its shallow stepover must be ≥ its steep stepover, it does not expose a threshold angle, and it keeps whole segments.
- PowerMill **Steep and Shallow** exposes the threshold and an overlap zone and offers raster or offset for shallow areas, but it produces "far more retracts".
- Sources (from search summaries of Autodesk help) — [PowerMill Optimised Constant Z overview](https://help.autodesk.com/cloudhelp/2019/ENU/PWRM-ReferenceHelp/files/GUID-26A95F05-F8C0-422D-9AA9-9A76CD36ABF1.htm); [PowerMill Steep and shallow finishing](https://help.autodesk.com/cloudhelp/2023/ENU/PWRM-ReferenceHelp/files/GUID-58BF2A5E-590E-4021-B0B9-7E4F95B9C808.htm); [Autodesk support: Optimized constant Z](https://autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/CHS/Optimized-constant-Z-in-PowerMill.html)

**Other CAM defaults for the steep/shallow split**
- PTC Creo's default slope angle dividing steep from shallow is 45°, and steep areas can take their own stepover — [PTC Creo: Milling parameters specific to finishing](https://support.ptc.com/help/creo/creo_pma/r12/usascii/manufacturing/nc/milling_parameters_specific_to_finishing.html)
- TopSolid computes its nominal scallop height "with respect to a theoretical slope at 45°" — [TopSolid'Cam Scallop Height](https://help.topsolid.com/7.15/en/TopSolid'Cam/CommonDialogBox/combhigh.htm)

**Vectric Aspire / VCarve Pro**
- The Aspire 3D Finish toolpath has two area strategies:
  - **Raster:** "a raster pattern (lace cut) projected onto the 3D surface", with Raster Angle limited to 0–90°.
  - **Offset:** climb or conventional, with a "Stepover Retract" lift between contours that is meant to "eliminate perpendicular tool marks".
  - Other options: machining limit boundary (Model / Material / Selected vectors / Selected level), Boundary Offset (lets the tool run past the edge of a raised object), and multi-tool **rest machining** with "Minimum Detail" and a boundary offset.
  - "The finishing toolpath is always a single pass."
  - Ball nose is typical, and "a tapered Ball Nosed cutter will also work and may offer more strength with smaller tool sizes."
  - Source — [Vectric Aspire V12 3D Finish Toolpath](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/form/Finish%20Machining%20Toolpath/index.html)
- Typical finishing stepover is 8–12% of tool diameter — [Vectric Aspire V10.5 3D Finish Toolpath](https://docs.vectric.com/docs/V10.5/Aspire/ENU/Help/form/Finish%20Machining%20Toolpath)
- Aspire V12.5 adds a "Use new raster" option that generates raster toolpaths "more consistent in regards to machining direction" — [Vectric V12.5 Options dialog](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/options-dialog/index.html)
- In 2013 one user reported jagged, distorted Offset finishes in Aspire, while Raster worked but took much longer; this predates current versions — [TalkShopBot forum](https://talkshopbot.com/forum/archive/index.php/t-17278.html)

**Carveco (ArtCAM lineage) relief finishing options**
- Strategies: Raster, Raster X & Y, Spiral and Spiral in box, Offset, 3D offset, 3D offset spiral, and Constant Z.
- Raster X & Y gives a "better surface finish, but time-consuming".
- 3D offset is for "constant stepover and near-horizontal surfaces", and 3D offset spiral "reduces air moves".
- Constant Z is for "near-vertical surfaces".
- Source — [Carveco Machine Relief panel finishing options](https://knowledge.carveco.com/portal/en/kb/articles/machine-relief-panel-finishing-options)

**Fabex (formerly BlenderCAM) 3D strategies** (GPL; see Q5)
- Parallel, Cross (perpendicular passes), Block, Spiral, Circles, Outline Fill, Carve (projects a 2D curve onto the 3D surface), Waterline, Medial Axis and Pencil — [Fabex strategies docs](https://spectralvectors.github.io/blendercam/strategies.html)

**General stepover guidance**
- A larger ball gives a smaller scallop at the same stepover. The scallop-vs-stepover curve "tends to flatten out" below about 1/8 of the diameter. General stepover guidance is 1/3 to 1/10 of diameter, and 1/5–1/3 for soft materials that hold detail poorly — [CNCCookbook: CNC stepover](https://www.cnccookbook.com/cnc-stepover)
- "Using the largest available cutter will give … the best surface finish and shortest cycle time." The minimum radius in the area to be machined sets the largest usable ball. The suggested workflow is a large ball first, then smaller balls on isolated areas — [Loughborough Univ. 3D machining notes](https://learn.lboro.ac.uk/ludata/cd/cad/cnc/3dmachining.htm)
- I found no source that states the inclined-surface (1/cos) stepover formula; the derivation below is my own.

### Inferences
**Scallop geometry (derived; standard sphere/plane geometry)**
- Flat surface, ball radius R, stepover s:
  - h = R − √(R² − (s/2)²) ≈ s²/(8R).
  - Inverse: s = 2√(2Rh − h²) ≈ √(8Rh).
- Plane of slope θ (from horizontal), with φ the angle between the raster row direction and the plane's uphill (gradient) direction in XY:
  - In-surface spacing of adjacent passes: **s_eff = s / √(1 − sin²θ·sin²φ)**.
  - Rows climbing straight up the slope (φ = 0) keep s_eff = s.
  - Rows running along the contour lines (φ = 90°) give s_eff = s/cosθ.
  - The exact scallop is h = R − √(R² − (s_eff/2)²).
  - Worked numbers: 1/8" ball (R = 1.5875 mm) at 10% stepover (0.3175 mm) gives h ≈ 0.0080 mm on flats. With φ = 90° it rises to ≈ 0.016 mm at θ = 45° (2×), ≈ 0.032 mm at 60° (4×) and ≈ 0.123 mm at 75° (≈ 15×).
- **Cross-hatch (second raster at α + 90°):**
  - The second pass sees s_eff' = s/√(1 − sin²θ·cos²φ).
  - Each surface patch is finished by whichever pass has the smaller spacing, so the worst case is φ = 45°: s/√(1 − ½sin²θ) ≤ √2·s.
  - At 60°, cross-hatch limits the spacing growth to 1.26× (single raster: 2×). This is why "Raster X & Y" and "Add Perpendicular Passes" exist. The cost is 2× the run time.
- **Waterline at Z-step Δz:**
  - In-surface spacing on a wall of slope θ is Δz/sinθ, which is perfect on vertical walls and diverges on flats.
  - Matching the worst-case raster spacing (s/cosθ) at the threshold θ_t gives **Δz = s·tanθ_t**. At θ_t = 45°, Δz = s.
  - This matches the 30–45° defaults reported by Fusion, Creo and TopSolid.
  - Recommendation: default θ_t = 40°, and derive Δz from the shallow stepover so the scallop is continuous across the seam.
- **Curved surfaces** (standard approximation, not verified against a source this session): h ≈ (s²/8)(1/R ± 1/ρ), where ρ is the surface radius of curvature. Use + for convex and − for concave. Concave hollows on reliefs therefore finish better than convex ridges at the same stepover.
- **Tapered ball nose** (tip radius r, flank half-angle α): use r in all scallop formulas. The ball tip only touches slopes up to 90° − α. Steeper walls are touched by the cone flank, which leaves a draft of about α. That makes it naturally suited to steep-and-shallow, and the exact drop-cutter needs a ball+cone composite (see Q2).

**Time model (arithmetic)**
- Raster path length ≈ area / s.
- Example: a 12"×12" relief with a 1/8" ball at 10% (0.0125") is ≈ 960 rows × 12" ≈ 11,500", or ≈ 77 min at 150 ipm before links.
- The same relief with a 1/16" tapered ball nose at 8% (0.005") is ≈ 28,800", or ≈ 3.2 h. Cross-hatch doubles either figure.
- Steep-and-shallow with constant-scallop logic saves time on reliefs whose area is mostly shallow. It adds passes only on the steep fraction instead of shrinking s everywhere.

**Suggested NativeCAM strategy roadmap (priority for wood reliefs)**
1. **Cross-hatch:** run the existing raster at angle and angle + 90°, with an option to run the second pass only on slopes the first handles badly (|sinθ·sinφ| above a limit). This is cheap because it reuses current code.
2. **Steep-and-shallow:** waterline on slopes > θ_t, raster (or cross-hatch) on slopes < θ_t, with an overlap band.
3. **Constant-scallop (3D offset):** user enters a target scallop height rather than a stepover %.
4. **Pencil** along concave creases.
5. **Rest machining** with a smaller (tapered) ball, restricted to areas the big ball could not reach.
6. **Spiral / radial / morphed spiral:** low priority (coins, domes, rosettes).

### Gaps
- No source found giving the inclined-surface stepover formula explicitly. The formula above is derived and should be checked numerically against NativeCAM's own simulator (`MaterialSimulator`).
- No quantitative published comparison (time vs. measured roughness) of these strategies specifically in wood was found.
- I did not find documentation of VCarve Pro's 3D finishing options separate from Aspire's. The V9.5 VCarve Desktop docs exist but were not fetched.
- Fusion's 3D "Contour", "Pencil", "Radial", "Spiral" and "Flow" reference pages were not fetched, so their option lists are not documented here.

## Q2. Algorithms: waterline, constant scallop, steep detection, drop-cutter acceleration, key papers

### Takeaway
The cleanest path for NativeCAM is to compute a **cutter-location (CL) height map** once per tool, using the exact drop-cutter or a GPU/SIMD scatter. Every strategy is then derived from that map:
- **Waterline:** iso-contours of the CL map at Z levels, with exact refinement of the contour vertices.
- **Steep/shallow regions:** thresholded CL-surface slope, which for a ball nose equals the contact-normal slope.
- **Constant-scallop paths:** iso-lines of a geodesic distance field computed on the CL surface.
- **Pencil lines:** contact-point discontinuities, i.e. double contact.

OpenCAMLib's fiber/push-cutter + "weave" waterline is exact but complex. FreeCAD already ships a simpler drop-cutter-grid waterline variant, which shows the CL-map approach is viable.

### Cited Findings
**OpenCAMLib (OCL) structure**
- OCL provides drop-cutter (drop the cutter at a fixed XY until it touches) and push-cutter ("used to create a Waterline toolpath at a constant z-height"). Cutters are CylCutter, BallCutter, BullCutter, ConeCutter and CompositeCutter — [OpenCAMLib README](https://github.com/aewallin/opencamlib)

**OCL batch drop-cutter** — [OCL batchdropcutter.cpp](https://raw.githubusercontent.com/aewallin/opencamlib/master/src/dropcutter/batchdropcutter.cpp); [OCL kdtree.hpp](https://raw.githubusercontent.com/aewallin/opencamlib/master/src/common/kdtree.hpp)
- Builds a `KDTree<Triangle>` over the XY dimensions (`setXYDimensions`, "we search for triangles in the XY plane, don't care about Z") with bucket size 1. The tree splits on the dimension of largest "spread".
- Ships four versions: `dropCutter1` (brute force), `dropCutter2` (kd-tree search for "triangles under the cutter"), `dropCutter3` (kd-tree plus an explicit `cutter->overlaps(cl,t)` test) and `dropCutter4` ("use OpenMP to share work between threads").

**OCL adaptive path drop-cutter** — [OCL adaptivepathdropcutter.cpp](https://raw.githubusercontent.com/aewallin/opencamlib/master/src/dropcutter/adaptivepathdropcutter.cpp)
- Subdivides each span at its midpoint while the forward step is above `sampling`, or while the three CL points are not `flat()` and the step is above `min_sampling`.
- `flat()` tests the dot product of successive unit segment vectors against `cosLimit`. Defaults are sampling 0.1, min_sampling 0.01 and cosLimit 0.999.

**OCL waterline** — [OCL waterline.cpp](https://raw.githubusercontent.com/aewallin/opencamlib/master/src/algo/waterline.cpp); [OCL batchpushcutter.cpp](https://raw.githubusercontent.com/aewallin/opencamlib/master/src/algo/batchpushcutter.cpp)
- Runs two `BatchPushCutter` sub-operations, for X-fibers and Y-fibers ("these two are independent, so could/should run in parallel").
- The fibers feed a `SimpleWeave` / `SmartWeave`; `weave.build()` and `face_traverse()` then produce the loops.
- The push-cutter's kd-tree searches in YZ for X-fibers and in XZ for Y-fibers, and can use OpenMP.

**OCL adaptive waterline** — [OCL adaptivewaterline.cpp](https://raw.githubusercontent.com/aewallin/opencamlib/master/src/algo/adaptivewaterline.cpp)
- Uses `FiberPushCutter` with adaptive fiber insertion. Defaults are sampling 1.0, min_sampling 0.1 and cosLimit 0.999, and the X and Y fiber passes run as parallel OpenMP tasks.

**OCL author's blog (Anders Wallin)** — [anderswallin.net waterline posts](https://www.anderswallin.net/?s=waterline)
- Adaptive waterline reuses the `flat()` predicate from adaptive drop-cutter to decide where to insert fibers ("Better adaptive waterline", Nov 2010).
- A new Weave class sped up waterline ("Faster Waterline", May 2011).
- OpenMP plus hard-coded determinant expressions ran about 3× more fibers in about 15 s ("Faster waterlines with OpenMP", Aug 2010).
- The weave is converted to a Boost graph and split into connected components ("Waterline toolpaths, part 3", Jul 2010).
- Waterline CL points come out "in an undefined almost random order", so a separate loop-ordering step is needed. The kd-tree search was extended to the XZ/YZ planes, which "dramatically reduces the number of triangles which go through the pushCutter function". The Tux example "took 96 seconds to generate five waterlines" (2010 hardware) — [Waterline toolpaths, part 2](https://www.anderswallin.net/2010/07/waterline-toolpaths-part-2/)
- In 2018-era Python example comments, the Weave class was "not wrapped" for Python. Current status is unverified — [Debian: OCL fiber_08_stl_weave.py](https://sources.debian.org/src/opencamlib/2023.01.11-6/examples/python/fiber/fiber_08_stl_weave.py)

**FreeCAD Waterline operation** — [FreeCAD Waterline.py](https://raw.githubusercontent.com/FreeCAD/FreeCAD/main/src/Mod/CAM/Path/Op/Waterline.py)
- Offers three algorithms:
  1. **"OCL Dropcutter":** parallel scan lines spaced by `SampleInterval` (default 1.0 mm) are run through `ocl.PathDropCutter`. A "topo map from scanLines (highs and lows)" is built per layer, then loops are traced on the 8-neighbour boundary. This does **not** use `ocl.Waterline`.
  2. **"OCL Adaptive":** `ocl.AdaptiveWaterline` with `MinSampleInterval` (default 0.005 mm).
  3. **"Experimental":** slices the B-rep at each depth, resolves islands, and offsets the cleared area by cutter radius + `BoundaryAdjustment`.
- According to the code, the operation is deprecated in favour of the Surface operation's Waterline strategy (as summarized from the source; verify).

**Papers: mesh slicing and z-level**
- Park, S.C. (2004), "Sculptured surface machining using triangular mesh slicing", *Computer-Aided Design* 36:279–288, DOI 10.1016/S0010-4485(03)00114-3. It slices the **CL surface** (an offset triangular mesh) with planes to get path segments, then removes invalid segments — [Bohrium summary](https://www.bohrium.com/paper-details/sculptured-surface-machining-using-triangular-mesh-slicing/812399952410968065-2539)

**Papers: drop-cutter on STL**
- Yau, H.-T. (2004), "Numerical control machining of triangulated sculptured surfaces in a stereo lithography format with a generalized cutter". This is the classic drop-cutter for generalized APT cutters on STL; abstract not retrieved — [EconBiz record](https://www.econbiz.de/Record/numerical-control-machining-of-triangulated-sculptured-surfaces-in-a-stereo-lithography-format-with-a-generalized-cutter/10006125737)

**Papers: GPU inverse offset**
- Inui (2003), "Fast inverse offset computation using polygon rendering hardware", *CAD*. It uses the graphics depth buffer as a Z-map of the CL surface, computed by intersecting rays from grid points with the inverse-offset shape, and needs different inverse-offset shapes for flat and round-end cutters — [Bohrium summary](https://www.bohrium.com/paper-details/fast-inverse-offset-computation-using-polygon-rendering-hardware/812453766413418497-2539)
- Kitahara et al. (2019), "Accurate Tool Path Generation Method for Large-Scale Discrete Shapes", *IJAT* 13(2):279–288. It fixes polygon-approximation error by building the offset surface from polygons, cylinders and spheres (GPGPU) — [Fuji Press IJAT](https://www.fujipress.jp/ijat/au/ijate001300020279); follow-up "Fast Tool Path Generation Algorithm for Large-Scale Discrete Shape" — [Bohrium](https://www.bohrium.com/paper-details/fast-tool-path-generation-algorithm-for-large-scale-discrete-shape/812769515514363905-21532)
- Balabokhin (2016), PhD dissertation, Univ. of South Carolina: GPU-based 3-axis tool-path planning including iso-scallop and contour-parallel paths (from search summary) — [scholarcommons.sc.edu/etd/3883](https://scholarcommons.sc.edu/etd/3883)

**Papers: iso-scallop / constant scallop**
- Zou, Q. (2021), "Robust and efficient tool path generation for machining low-quality triangular mesh surfaces", *IJPR* 59(24):7457–7467 (arXiv 2004.09136). Iso-scallop paths are equivalent to geodesic parallels under a modified Riemannian metric. The geodesic computation is converted to heat diffusion (the heat method) and needs only two sparse linear solves. The paper credits Kim with the equivalence for parametric surfaces and Kout & Müller with extending it to meshes — [arXiv 2004.09136](https://arxiv.org/pdf/2004.09136); [EconPapers](https://econpapers.repec.org/RePEc:taf:tprsxx:v:59:y:2021:i:24:p:7457-7467)
- Liang et al. (2021), "Iso-scallop tool path planning for triangular mesh surfaces in multi-axis machining", *RCIM*, DOI 10.1016/j.rcim.2021.102206. It builds a geodesic distance field from the boundary, normalizes it so the first contour meets the scallop limit, and takes the paths as contours — [Bohrium](https://bohrium.dp.tech/paper/arxiv/812544280475205633)
- A related paper by the same group uses harmonic mapping to a unit disk (relevant to morphed-spiral-style paths) — [IJPR DOI 10.1080/00207543.2021.1887535](https://informahealthcare.com/doi/full/10.1080/00207543.2021.1887535)

**Pencil / clean-up**
- Industrial CAM detects **double-contact points** and links them into chains. The academic literature more often uses intersections of offset surfaces — [Pencil milling (Wikipedia mirror)](https://ipfs.ssi.eecc.de/ipns/en.wikipedia-on-ipfs.org/wiki/Pencil_milling)
- A thesis whose table of contents covers a "2D Grid for center of double contact points" and connecting double-contact points by connectivity (contents only seen) — [core.ac.uk 276284982](https://core.ac.uk/download/276284982.pdf)
- A curve-based clean-up method for STL models with a ball-end mill, which detects pencil points among sharp-concave points — [Bohrium](https://www.bohrium.com/paper-details/tool-path-generation-for-clean-up-machining-by-a-curve-based-approach/812307921298784257-2539)

**Steep detection in commercial CAM**
- Fusion's slope is measured from horizontal (see Q1), and its "Contact Point Boundary" option limits where the *tool touches* rather than the tool centre — [Fusion Scallop reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID77067110-3D88-4DA7-B171-6B27F04CF8B3.htm)

### Inferences
**A. Drop-cutter acceleration for NativeCAM** (in rough order of payoff; NativeCAM already uses uniform bins and `concurrentPerform`)
1. **Z-bound pruning.**
   - For ball and flat cutters, a triangle can never lift the tool tip above its highest vertex Z (+ allowance), because the contact point lies on the triangle and the tip is the cutter's lowest point.
   - Store each bin's triangle list sorted by descending `zmax`, and stop scanning once `zmax + allowance ≤ best`.
   - On reliefs, where many small triangles sit under a cutter, this should skip most facet/edge/vertex tests.
2. **Warm start.**
   - Test the previous sample's winning triangle first so `best` starts high, then apply the pruning above.
   - Neighbouring samples along a row almost always share the same top triangles.
3. **Finer bins plus a disc-overlap pre-test.**
   - Bins of about R instead of 2R, and an AABB-vs-disc reject before `ballDrop`. This is the equivalent of OCL's `dropCutter3` explicit `overlaps()` test.
   - A kd-tree (OCL style, XY dims, bucket 1) is an alternative. Uniform bins are already fine for the roughly uniform triangle density of relief meshes.
4. **Data layout.**
   - Precompute per-triangle plane normal, offset and edge data in a structure-of-arrays (SoA) layout so the facet test is SIMD-friendly.
   - The current layout is 9 doubles per triangle. `ballDrop` recomputes `simd_cross` and `simd_length` (the normal) on every query, and it loops over array literals `[a, b, c]` and `[(a, b), …]` in the hot path. Those literals may allocate unless the optimizer removes them, so unroll them or use tuples.
5. **Adaptive sampling along rows.**
   - Replace the fixed `ds` with OCL-style midpoint subdivision: a coarse step, refined where the three-point `flat()` test fails (cosLimit ≈ 0.999) down to a minimum step.
   - Flat areas, which are a large share of a relief, then need few samples, and the later `simplify3D` has less work.
6. **GPU / Metal option.**
   - Compute the CL Z-map by scatter, in the spirit of Inui's inverse offset. Each triangle thread visits grid nodes inside its XY bbox grown by R, computes the exact ball drop (facet/edge/vertex), and writes an atomic max.
   - Floats can be handled with an order-preserving uint mapping, since a float atomic-max may not be available.
   - The map is exact *at the nodes*, unlike the current height-grid drop. Path points between nodes can be re-dropped on the CPU with the exact cutter.
   - Apple-silicon unified memory avoids copies. This is an inference; the Metal atomic API details were not checked.
7. **Exact drops for more cutters.**
   - Add BullCutter and a tapered ball (ball + tangent cone) to `TriangleDropCutter`.
   - OCL's CompositeCutter shows the pattern: combine component cutters, each valid over a radial interval, and take the max drop. Tapered ball noses currently fall back to the height grid.

**B. Waterline (constant Z) — recommended implementation**
- With CL(x,y) the drop-cutter tip height, the tool at height z gouges iff CL(x,y) > z. The waterline at z is therefore exactly the iso-contour CL(x,y) = z, oriented so that material is on the correct side.
- Steps:
  1. Compute the CL map on a grid of pitch about stepover/3 or finer.
  2. Run marching squares at each z, which yields closed loops with nesting for free.
  3. **Refine** each contour vertex by bisection, using the exact drop-cutter along the contour normal until |CL − z| < tolerance.
  4. Simplify the loops and offset them slightly with Clipper2 if needed.
- This is the FreeCAD "OCL Dropcutter" idea done properly with interpolation, and it avoids OCL's fiber/weave graph complexity.
- Cost is one CL-map build per tool plus O(cells) per level, and the levels are trivially parallel.
- **Adaptive Z levels:** when the horizontal gap between consecutive loops exceeds the target in-surface spacing (see the Δz/sinθ relation in Q1), insert intermediate levels locally, or hand that area to the shallow strategy. This is effectively steep-and-shallow.
- **Exact alternative:** OCL's push-cutter fibers in X and Y at each z give exact interval endpoints, and a planar "weave" graph traces the loops. Consider this only if contour accuracy from the refined CL map proves insufficient.

**C. Steep vs. shallow regions**
- For a **ball** cutter, the CL-surface normal equals the part's contact-point normal, so slope can be taken directly from the CL map: θ = atan(|∇CL|), using central differences.
- Alternatively, record the contact normal from the winning triangle: the facet normal for a facet contact, or the (centre − contact point) direction for edge and vertex contacts.
- Threshold at θ_t to get a mask, then apply a morphological open/close to remove slivers.
- Vectorize the mask with marching squares, then use Clipper2 to make the steep and shallow polygons and grow each by the overlap distance.
- Clip raster rows to the shallow polygons (the existing clip-to-boundary code) and waterline loops to the steep polygons.

**D. Constant-scallop / 3D offset**
- Compute a geodesic distance field on the CL surface over the grid, starting from the region boundary or from the steep/shallow seam. Use fast marching, or the Zou heat method, which is two sparse solves (Accelerate's sparse solvers could serve).
- The metric is ds² = dx² + dy² + dCL².
- Take iso-lines at multiples of the 3D stepover s3d = 2√(2Rh − h²) for the target scallop h. Spacing on the ball-centre surface equals the contact-line spacing on planes, and the curvature correction is ≤ R/ρ.
- Chain the iso-lines into loops. Link them by stepping inward at depth, or form a spiral by blending adjacent loops, as Carveco's "3D offset spiral" does.
- Morphed spiral is the same approach with a harmonic field (Laplace solve, 0 on the boundary and 1 at a centre) in place of geodesic distance.

**E. Pencil**
- Store the contact point (CC) with each CL sample. Along a concave crease, the winning contact jumps between the two faces, so mark cells where the XY distance between neighbouring contact points is much larger than the sample pitch (double contact).
- Thin the marked cells to a skeleton and chain them into polylines (Clipper2 cleanup).
- Emit 1 pass, or ±k parallel offsets ("multi-pencil"). Usually this runs with the *next smaller* ball so it cleans up what the finishing ball could not reach.

**F. Rest machining**
- Simulate tool A's finish with the existing `MaterialSimulator` / `HeightmapImage`, then compute residual = simulated − target. Residual > tolerance gives the rest region; drop regions smaller than a "minimum detail" (as Vectric does) and grow the rest by a boundary offset.
- Run tool B (smaller or tapered ball) with any strategy clipped to the rest region.

### Gaps
- Full texts of the key papers were not read (Park 2004; Yau 2004; Inui 2003; Kim's geodesic-parallel paper; Kout & Müller). Their exact algorithms and timings are not captured here.
- Two further papers were mentioned in search results but not retrieved and are unverified: Chuang & Yau (2005), "z-level contour machining … fillet endmills", and Kim & Yang (2005), "Triangular mesh offset for generalized cutter".
- No benchmark of kd-tree vs. uniform bins vs. GPU scatter for relief-sized meshes (≥ 1M triangles) was found. NativeCAM should measure this itself.
- Metal-specific feasibility (float atomic max, threadgroup sizing) was not researched.

## Q3. Linking, direction, lead-ins, point filtering and arc fitting for 3D finishing

### Takeaway
Keep the tool on the surface between rows and loops, which NativeCAM already does for short raster hops via the drop-cutter. Extend that to waterline and offset loops with a "shortest path / smooth" surface link and a retract threshold.

Set the point-filter tolerance well below the target scallop, but not so tight that it floods Mach4/ESS with tiny G1 moves. Very tight tolerances "can cause short line moves that lead to data starving on the control" (Fusion).

Arc fitting in 3D only works when a pass lies in a principal plane. A 0° or 90° raster row lies in an XZ or YZ plane, so G18/G19 arcs are possible there. A 45° row, or a waterline loop that is not planar in a principal plane, cannot use arcs, except in XY for waterline loops (G17).

### Cited Findings
**Fusion linking and filtering settings**
- **Retraction Policy:** Full, Minimum or Shortest path. "Shortest path" should only be used on machines that run linearized rapids.
- **Transition Type:** No contact, Straight line, Shortest path or Smooth.
- Lead-in/lead-out radii are available on parallel finishing.
- **Smoothing** "removes excessive points and fitting arcs where possible". Paths that lie mostly in a major plane, such as parallel passes, smooth well.
- **Tolerance:** the machining tolerance is the sum of the generation and triangulation tolerances, plus any filtering tolerance. Very tight tolerances cause short line moves and data starving.
- **Direction:** zigzag or unidirectional, with One Way, Other Way and Both Ways. Up/Down milling splits passes into only-downhill or only-uphill segments, and "down milling can reduce tool deflection" on complex surfaces.
- Sources — [Fusion Parallel Finishing reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID17CC1F90-A2A5-4CC3-80EB-B7972E327E0F.htm); [Fusion Up/Down Milling reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUIDC4E61233-6AF9-4375-A225-4807175A0C85.htm)
- In 3D Scallop paths, smoothing reduces point count less than it does in planar paths. Scallop also offers "Link from Inside to Outside", High Feedrate Mode and Safe Distance — [Fusion Scallop Finishing reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID77067110-3D88-4DA7-B171-6B27F04CF8B3.htm)

**Other CAM linking options**
- Carveco "Surface links": links above a length threshold retract to Safe-Z, while shorter links travel across the surface. The "Both" cutting direction reduces air moves. Very small tolerances increase file size and both calculation and machining time — [Carveco finishing options](https://knowledge.carveco.com/portal/en/kb/articles/machine-relief-panel-finishing-options)
- Vectric Offset finishing has "Stepover Retract": a small lift between contours "will eliminate perpendicular tool marks", with a warning if the lift is too small to clear the previous cusp — [Vectric Aspire V12 3D Finish](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/form/Finish%20Machining%20Toolpath/index.html)

**Arc fitting and circular planes (post processors)**
- In a UCCNC case, `allowedCircularPlanes = 1 << PLANE_XY` turned XZ/YZ curves into "hundreds if not thousands of short linear moves". Allowing XY|ZX|YZ planes replaced them with "a handful of G2/G3" — [CNCDrive forum](https://forum.cncdrive.com/viewtopic.php?p=32866)
- Fusion smoothing introduced XZ/YZ arcs that a post with those planes disabled re-linearized. A moderator warned that small arcs can cause radius errors on GRBL, and `linearizeSmallArcs` still linearizes arcs with radius < bit radius — [OpenBuilds forum](https://builds.openbuilds.com/posts/135426/)
- Fusion staff said smoothing is unlikely to give true arc motion on some 3D paths. A user reported that 0.001" tolerance with smoothing on fixed lost steps — [Autodesk forum: 3D arc support](https://forums.autodesk.com/t5/fusion-manufacture/3d-arc-support/m-p/11939509)
- Tiny Z noise from "Optimized XY machining" prevented RhinoCAM's arc fitter from producing arcs — [McNeel forum](https://discourse.mcneel.com/t/fillet-surface-and-rhinocam/81038)

**Mach4 / Avid specifics**
- On the Avid forum, the mcCvTuningWizard with max feedrate 300 and stop angle 179 "seemed to fix the jerkiness of the toolpath". Another user found Exact Stop (G61 in the G-code) gave the best shape on short-segment V-carve ovals, and that setting ES in Mach4 Defaults "doesn't do anything". Users disagree on what the stop angle means. A separate fix: "Setting Fusion 360 tolerance to .001" and turning smoothing on fixed the problem" (lost steps) — [Avid CNC forum: Mach4 CV Tuning Wizard](https://forum.avidcnc.com/t/mach4-cv-tuning-wizard/3205)
- In Mach4, G64 is Constant Velocity cutting mode — [MachMotion Mach4 G/M-code reference](https://support.machmotion.com/books/software/page/mach4-g-code-and-m-code-reference/revisions/10749)
- In Mach3 (Mach4 is likely similar but unverified), lookahead applies only in CV mode, with a maximum of 1000 lines. "CV Dist Tolerance" controls corner rounding: larger values run faster, while smaller values plus higher acceleration give tighter corners — [Mach3 CV Settings v2 (PDF)](https://www.machsupport.com/ftp/Docs/Mach3_CVSettings_v2.pdf)

**Short segments in general**
- Floods of very short segments starve a controller's lookahead queue and cause stalls. In LinuxCNC, coordinated moves that include axes beyond XYZ fall back to one-line lookahead. CAM-side fixes (coarser tolerance, fewer tiny segments) can solve it — [LinuxCNC forum: lookahead over short vectors](https://www.forum.linuxcnc.org/32-documents/53351-planning-moves-lookahead-over-short-vectors-and-blending-vectors)

**Grain and cutting direction (low-quality source)**
- One knowledge-base article suggests starting with a raster parallel to the dominant grain in long-grain hardwood. It says spiral and offset paths keep changing direction relative to the grain, which gives uneven finishes, and that climb and conventional each behave differently as the grain reverses, so test on the actual material. The source is an unattributed knowledge-base blog — [industrialmonitordirect.com](https://industrialmonitordirect.com/blogs/knowledgebase/cnc-surfacing-improves-with-correct-tram-and-toolpaths)

### Inferences
**Links**
- Keep the current "link at depth via drop-cutter if hop ≤ k·stepover" rule and generalize it:
  - (a) Use a **length threshold** in mm, not only a multiple of the stepover, plus a **max-Z-climb** limit. If the surface link rises more than about 2× the tool radius, a retract is cleaner.
  - (b) For waterline and offset loops, pick each loop's start point nearest the previous end (any CL point in a loop is equally valid, per Wallin) and link along the surface.
  - (c) Offer "smooth" links: replace a sharp row turnaround with a short arc in the row plane, kept above the drop-cutter surface. This removes the 180° direction reversal that the Mach4 CV planner must decelerate for.
- **One-way vs. zig-zag:** zig-zag minimizes air time. One-way means one retract and one rapid per row, about a 2× link overhead.
- **Climb vs. conventional in wood:** zig-zag alternates climb and conventional relative to the previous cusp. A "One Way" option should exist for figured or tear-prone woods.
- **Uphill/downhill-only option:** worth offering for wood. It addresses the reported "strandy" fibers on descending slopes (Q4), but this is hypothesis, to be tested.

**Lead-ins**
- For ball-nose finishing, the main visible artifact is the plunge/dwell mark where a pass starts on the model.
- Prefer starting rows off the model: extend rows past the model boundary onto the surrounding stock surface, as Vectric's Boundary Offset allows. Failing that, use a short ramp along the first segment instead of a vertical plunge to the surface.

**Point filtering**
- Chord error for a segment of length L on a path curvature radius ρ is ≈ L²/(8ρ) (standard geometry).
- Choose the filter tolerance at about ¼–½ of the target scallop. Example: scallop 0.008 mm gives a tolerance of about 0.002–0.004 mm, which on ρ = 5 mm features allows L ≈ 0.28–0.4 mm.
- Also enforce a **minimum segment length**, or a maximum segment rate: lines per second = feed ÷ L. At 150 ipm (63.5 mm/s) with 0.25 mm segments that is about 254 lines/s.
- NativeCAM's current `simplify3D` tolerance is `min(0.01, 2·arcTolerance)`. Expose it, tie it to the target scallop, and report the resulting minimum and median segment length and the lines-per-second at programmed feed in the warnings.

**Arc fitting (plane-aware)**
- A raster row at 0° lies in an XZ plane (G18) and a row at 90° in a YZ plane (G19), so biarc fitting within that plane is valid. For any other angle the row lies in a vertical plane that is not principal, so only G1 is possible.
- Waterline loops lie in XY at constant Z, so G17 arcs are fully valid. They are the best candidate for arc output.
- Offset and scallop paths are 3D curves: G1 only.
- When an arc-capable controller is targeted, a 0° or 90° raster could be favoured. That conflicts with grain-driven angle choices, so surface it as a trade-off in the UI.
- Only emit G18/G19 arcs if the Avid Mach4 post and ESS handle them reliably, which is unverified (see Gaps). Also skip arcs with a radius below a threshold, as Fusion's `linearizeSmallArcs` does.

### Gaps
- No Warp9 ESS or Mach4 primary documentation was found on lookahead depth, maximum line rate, or G18/G19 arc handling. The Avid Mach4 Configuration Guide PDF ([2023Q3](https://www.avidcnc.com/cad/2023Q3/Mach4_Configuration_Guide_v2023Q3_1.pdf)) was downloaded but could not be text-extracted here, so its CV and lookahead recommendations are uncaptured. It is worth reading manually.
- Whether Avid's stock Mach4 post emits G18/G19 arcs is unknown.
- No controlled study of climb vs. conventional, or uphill vs. downhill, ball-nose finishing in wood was found.

## Q4. Practical settings and common complaints for wood reliefs

### Takeaway
Typical wood-relief finishing uses:
- A 1/8"–1/4" ball nose, or a 1/32"–1/16" tip tapered ball nose (TBN) for detail.
- Stepover of about 8–12% of the tip diameter (Vectric's typical range). Very fine TBNs go to 5–8%, at the cost of very long runs.
- Raster at or near the grain direction, or two crossed passes (0/90°, or roughly ±35°) to hide tool marks.

The three classic complaints map to strategy features:
- **Torn grain** → raster angle relative to grain, a second crossing pass, and direction control.
- **Visible scallops on slopes** → cross-hatch, steep-and-shallow, or constant scallop.
- **Long run times** → the largest usable ball plus rest machining with a small TBN only where needed, instead of a tiny TBN everywhere.

### Cited Findings
**Tool and stepover settings**
- Vectric: ball nose, stepover 8–12% of diameter typical; a tapered ball nose "will also work and may offer more strength with smaller tool sizes" — [Vectric Aspire V12 3D Finish](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/form/Finish%20Machining%20Toolpath/index.html)
- One user runs "a 1/16 tapered ball nose with an 8% stepover" for fine detail and accepts "a long finish cut" — [Sawmill Creek](https://sawmillcreek.org/goto/post?id=2915892)
- On a 1/32" tip at 5% stepover, the bit steps about 0.0015" (0.04 mm): "an incredibly fine finish but it will take forever" — [Carveco community](https://support.carveco.com/hc/en-gb/community/posts/360076193912/comments/360013948351)
- IDC Woodcraft's 0.015" tip ultra-fine carving bit lists a stepover of 6–8% — [IDC Woodcraft product page](https://www.idcwoodcraft.com/product/ultra-fine-detail-carving-bit-for-cnc-routers/)
- Larger ball → smaller scallop at the same stepover. Diminishing returns below about 1/8 of diameter. Soft materials that hold detail poorly suit 1/5–1/3 — [CNCCookbook](https://www.cnccookbook.com/cnc-stepover)

**Raster angle, grain and tear-out (forum reports; snippet-level attribution, not fetched)**
- Raster at 35° on the first pass and −35° on the second gave a good finish, with "only some torn grain" needing sanding — [Sawmill Creek: roughing pass or no roughing pass](https://sawmillcreek.org/threads/roughing-pass-or-no-roughing-pass-for-3d-project.287197/)
- Cleaner finishes reported at raster angles of 22–40° — [LightBurn forum](https://forum.lightburnsoftware.com/t/no-depth-of-pass-in-3d-relief-finishing/192424)
- Advice to run "2 finishing passes: the first across the grain and the second along the grain, so that any tooling marks aren't as visible" — [Carbide 3D community](https://community.carbide3d.com/t/3d-finish-strange-results/77548)
- A user with a 0.5 mm TBN in maple, rastering along the grain, got "nests of strandy stuff on descending sloped sections" — [lemmy.amethyst.name post](https://lemmy.amethyst.name/post/90304/42091) (attribution from search snippet; not verified by fetch)

**Strategy trade-offs and software issues**
- Carveco: Raster X & Y gives a better finish but is time-consuming; 3D offset suits near-horizontal areas; Constant Z suits near-vertical ones — [Carveco finishing options](https://knowledge.carveco.com/portal/en/kb/articles/machine-relief-panel-finishing-options)
- A Vectric user fixed a 0.25 mm TBN toolpath problem by turning off "Use New Raster" (single report) — [Vectric forum](https://forum.vectric.com/viewtopic.php?p=238203)

**Tool sizing**
- The smallest concave radius in the region sets the largest usable ball. Rough-to-fine tool sequencing confines small tools to small areas — [Loughborough Univ.](https://learn.lboro.ac.uk/ludata/cd/cad/cnc/3dmachining.htm)

### Inferences
**Defaults for NativeCAM's 3D finish UI (proposed)**
- Stepover 10%, shown alongside the computed flat-surface scallop and the worst-case scallop on the model's steepest across-row slope, using the Q1 formula with the actual mesh slopes from the CL map.
- Raster angle in a full 0–180° range rather than Vectric's 0–90°, with a "grain direction" field on the stock so presets can be "along grain", "±35° cross" or "across then along".
- "Second pass" toggle (cross-hatch) with an independent angle.

**Complaint → feature map**
- **Tear-out across grain** → align rows to the grain; add a light second pass along the grain; offer a one-way or uphill-only direction (to be tested).
- **Scallops on slopes** → cross-hatch, or steep-and-shallow, or constant scallop. Q1 math shows a single raster at 10% has 4× the flat scallop on 60° across-row slopes.
- **Run time** → finish with the largest ball that fits the minimum concave radius, then rest-machine with a TBN only in the residual regions. Also use surface links and adaptive sampling, which shorten controller time but not cutting distance.

**TBN sizing**
- TBN nominal sizes refer to the tip (1/32" ≈ 0.79 mm, 1/16" ≈ 1.59 mm). Scallop and stepover must be computed from the tip radius, not the shank.
- The taper also means steep walls show the flank's draft angle, so the TBN's drop-cutter must model the cone (Q2-A7).

### Gaps
- No rigorous measurements found of tear-out vs. raster angle or species. Evidence is anecdotal, and the 45° raster specifically was not found tested.
- No sourced typical feed rates or RPM for ball-nose finishing in hardwood on Avid machines; out of scope here, but needed for time estimates.
- Specific TBN product geometries (taper half-angles for common 1/32" and 1/16" tip bits) were not collected.

## Q5. Open-source code: repos, exact licenses, usability in a closed-source app

### Takeaway
Only **Kiri:Moto (MIT)** is permissively licensed among the candidates, and it has the weakest 3D finishing.

**OpenCAMLib** and **FreeCAD** are **LGPL-2.1(-or-later)**. They can only be used in a closed-source app via dynamic linking with relinking rights, which is awkward for a Swift app and effectively rules out static or App Store bundling. They are excellent algorithm references.

**pycam (GPL-3.0-or-later)**, **Fabex/BlenderCAM (GPL-3.0)** and **CAMotics (GPL-2.0-or-later)** must not be incorporated into closed-source NativeCAM. Clean-room reimplementation from papers and documented algorithms is the safe route.

### Cited Findings
**OpenCAMLib (C++)** — ⚠ **LGPL**
- Repo: https://github.com/aewallin/opencamlib. GitHub's license API reports **LGPL-2.1**; the README says "From August 2018 OpenCAMLib is released under LGPL license"; source headers say "version 2.1 of the License, or (at your option) any later version", i.e. effectively **LGPL-2.1-or-later** — [OpenCAMLib repo](https://github.com/aewallin/opencamlib); [waterline.cpp header](https://raw.githubusercontent.com/aewallin/opencamlib/master/src/algo/waterline.cpp)
- Provides drop-cutter, batch drop-cutter with kd-tree and OpenMP, adaptive path drop-cutter, push-cutter, waterline (fibers + weave) and adaptive waterline.
- Bindings: C++ (CMake `find_package`), Python on PyPI (3.9–3.14), and Node/WASM, which the README calls "not 100% feature complete".
- Last push Oct 2026 (GitHub API).

**FreeCAD CAM (Python + C++)** — ⚠ **LGPL**
- Repo: https://github.com/FreeCAD/FreeCAD (GitHub API: **LGPL-2.1**). `Waterline.py` carries SPDX **LGPL-2.1-or-later**; the summary of its header text referenced "version 2", a minor inconsistency to recheck.
- Uses OpenCAMLib for its OCL algorithms — [FreeCAD repo](https://github.com/FreeCAD/FreeCAD); [Waterline.py](https://raw.githubusercontent.com/FreeCAD/FreeCAD/main/src/Mod/CAM/Path/Op/Waterline.py)

**pycam (Python)** — ⚠ **GPL**
- Repo: https://github.com/SebKuzminsky/pycam. `LICENSE.TXT` says "either version 3 of the License, or (at your option) any later version", and `COPYING.TXT` is the GPLv3 text, so **GPL-3.0-or-later**. GitHub's API shows NOASSERTION.
- Last push Jan 2024, so it is effectively dormant — [pycam LICENSE.TXT](https://github.com/SebKuzminsky/pycam/blob/master/LICENSE.TXT); [pycam COPYING.TXT](https://github.com/SebKuzminsky/pycam/blob/master/COPYING.TXT)

**Fabex, formerly BlenderCAM (Python, Blender add-on)** — ⚠ **GPL**
- Active repo: https://github.com/pppalain/blendercam (GitHub API: **GPL-3.0**; README: "licensed under GPLv3, UNLESS OTHERWISE INDICATED"; contributions must be GPL or more permissive). The original repo https://github.com/vilemduha/blendercam is also GPL-3.0.
- It was renamed at the Blender Foundation's trademark request — [Fabex README](https://github.com/pppalain/blendercam); [vilemduha/blendercam](https://github.com/vilemduha/blendercam)

**Kiri:Moto / grid-apps (JavaScript)** — permissive
- Repo: https://github.com/GridSpace/grid-apps (GitHub API: **MIT**; `license.md` is MIT text, "Copyright 2014-2018 Stewart Allen") — [grid-apps repo](https://github.com/GridSpace/grid-apps)
- Its CAM operation set (rough, outline, contour, trace, etc.) was not verified this session because documentation fetches failed.

**CAMotics (C++)** — ⚠ **GPL**
- Repo: https://github.com/CauldronDevelopmentLLC/CAMotics. `LICENSE` says "GNU General Public License … either version 2 of the License, or (at your option) any later version", so **GPL-2.0-or-later**. GitHub's API shows NOASSERTION.
- Primarily a 3-axis G-code *simulator* plus a JavaScript-based toolpath language, not a source of 3D finishing strategies — [CAMotics LICENSE](https://github.com/CauldronDevelopmentLLC/CAMotics/blob/master/LICENSE)

### Inferences
**Using LGPL code (OpenCAMLib, FreeCAD) in closed-source NativeCAM**
- Requires shipping it as a separately replaceable dynamic library (a `.dylib` or framework). It also requires providing its source and any modifications, and allowing user relinking.
- OCL also depends on Boost. Boost's own license (BSL-1.0) is permissive, but this is an assumption, not checked in this session.
- Reimplementing the specific algorithms in Swift is simpler and fits NativeCAM's existing code: adaptive sampling, kd-tree or bin search, push-cutter / waterline, and CL-map iso-contours.

**GPL code (pycam, Fabex, CAMotics)**
- Do not copy code or port line-by-line. Read documentation and papers only, or keep any GPL tool as a separate, user-installed program. A clean-room approach from the papers in Q2 is safest.

**Kiri:Moto (MIT)**
- Could be consulted or adapted freely, with the copyright notice retained. Its 3D finishing is limited compared with Fusion or Aspire.

### Gaps
- Kiri:Moto's current CAM operation list and its contour/finishing algorithm were not confirmed (docs URL 404, GitHub API rate-limited).
- Whether any Fabex files carry different licenses ("UNLESS OTHERWISE INDICATED"), e.g. files under MIT or other licenses, was not audited per file.
- OCL's transitive dependency licenses were not audited (Boost, and optional OpenMP/libomp, which is LLVM Apache-2.0 with exceptions).
- No permissively licensed (MIT/BSD/Apache) library implementing waterline or constant-scallop on meshes was found. One may exist; a targeted GitHub search was blocked by API rate limits.
