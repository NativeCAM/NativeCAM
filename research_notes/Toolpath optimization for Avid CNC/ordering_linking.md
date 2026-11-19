# Cut Ordering, Rapid-Move Minimization, Retract/Linking, and Tool-Change Ordering for CNC Router Toolpaths (NativeCAM / Avid + Mach4)

Context: NativeCAM today does (a) greedy nearest-start contour ordering (`nearestNeighborOrder` in `/Users/dsmith/natcam/Sources/CAMCore/Toolpath/ToolpathBuilder.swift:184`), (b) a full retract to `clearanceZ = max(stock.clearanceHeight, stock.plungeHeight)` on every `retract()` (`ToolpathBuilder.swift:47-49`), (c) straight plunge or ramp-along-path entry, and (d) operations kept in user order. The notes below cover what other CAM systems do instead and what the literature says it is worth.

## 1. Which ordering algorithms are used for contour/hole/segment sequencing, and what do they save vs nearest neighbour? How do you handle precedence?

### Takeaway
Every CAM product examined that discloses its method uses greedy nearest-neighbour (NN) as the base. The better open-source implementations add cheap local search: NN followed by 2-opt and single-point relocation (Or-opt-1) in FreeCAD 2025. Published improvements over a *good* construction heuristic are small (about 4% in laser cutting; 10–15% in one practitioner's G-code reorder). The large figures (26–40%) are measured against naive or zig-zag orderings. For NativeCAM, NN plus 2-opt/Or-opt with neighbour lists is the best effort-to-gain choice, with precedence handled structurally (hierarchical ordering) rather than inside the TSP.

### Cited Findings
**What CAM systems actually use**
- FreeCAD CAM (2025) has a C++ `tsp_solver` whose documented algorithm is: "1. Add temporary start/end points if specified 2. Build initial route using nearest neighbor heuristic 3. Optimize route with 2-opt and relocation moves 4. Remove temporary points". The comments say it "typically converges quickly (a few iterations) to a near-optimal solution". NN is O(n²), uses squared distance, and breaks near-ties "within ±0.1" by preferring the point whose y is closer to the start. For open routes (no end point) it can also reverse or relocate a segment to the end of the route. License is LGPL-2.1-or-later. — [FreeCAD tsp_solver.cpp](https://raw.githubusercontent.com/FreeCAD/FreeCAD/main/src/Mod/CAM/App/tsp_solver.cpp)
- FreeCAD `PathUtils.sort_locations()` ("sort holes by the nearest neighbor method") is a priority-queue NN that starts from the location nearest the origin. `sort_locations_tsp(locations, keys, attractors=None, startPoint=None, endPoint=None)` wraps the C++ solver. With no startPoint, the path "is optimized to start near the first point in the original list" but "may not start exactly at that point". — [FreeCAD PathUtils.py](https://raw.githubusercontent.com/FreeCAD/FreeCAD/main/src/Mod/CAM/PathScripts/PathUtils.py)
- Kiri:Moto CAM uses pure greedy NN:
  - `tip2tipEmit` ("Uses greedy nearest-neighbor algorithm to minimize travel distance") orders open paths and considers both ends of each path, reversing as needed.
  - `poly2polyEmit` orders closed polygons. It tests **every vertex** of every remaining polygon as a candidate entry and takes the global nearest, so it is a greedy generalized-TSP. An option weights 3D distance by polygon area squared for "depth-aware ordering".
  - `tip2tipJoin` merges paths whose tips are within `mergeDist`.
  - Source: [Kiri:Moto src/geo/paths.js](https://raw.githubusercontent.com/GridSpace/grid-apps/master/src/geo/paths.js)
- Kiri:Moto orders whole parts (widgets) by explicit user order if given, otherwise "sort output by distance to origin". — [Kiri:Moto prepare.js](https://raw.githubusercontent.com/GridSpace/grid-apps/master/src/kiri/mode/cam/work/prepare.js)
- Vectric merged toolpaths: "each of these ordering strategies is calculated and the quickest strategy chosen". Without "Merge By Part", "no attempt is made to preserve either the toolpath order or the order of contours". Merging only works for toolpaths that use the same tool. — [Vectric Aspire 12.5 Merged Toolpath](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/Create%20Merged%20Toolpath/index.html)
- Carbide Create users report that drilling and contour ordering look near-optimal on simple layouts, while "pocket, engrave & texture all followed a slightly more random, but OK path". V-carve ordering is "entirely too random". Carbide staff (William Adams) call optimal ordering "a very hard problem… 'The Traveling Salesman'". The third-party utility GCodeClean "break[s] gcode into blocks separated by travel moves, and do[es] a TSP optimization". — [Carbide 3D community thread](https://community.carbide3d.com/t/how-to-get-better-toolpath-efficiency/82460)
- Estlcam users report carve toolpaths that run "from one end of a sign to the other for a very small detail and then back". The workaround is manually numbering the machining order, and one user saw no gain from Estlcam's built-in optimization. — [V1E forum, Estlcam carve efficiency](https://forum.v1e.com/t/estlcam-carve-efficiency/8662), [V1E forum, inefficient Estlcam paths](https://forum.v1engineering.com/t/do-estlcams-paths-ever-look-inefficient-to-you/20380)
- A hobby CAM author (foam milling) reorders only the air moves as a TSP, using 2-opt (idea taken from StippleGen2), and keeps the cutting paths unchanged. A commenter points out that the Y axis is faster than X because of differing moving mass. — [fightpc blog, "Minimizing tool air-time"](https://fightpc.blogspot.com/2015/07/minimizing-tool-air-time.html)

**Typical quality and runtime of TSP heuristics**
- The DIMACS TSP Challenge classifies NN and Greedy as "Classic Tour Construction Algorithms: > 15% above the HK Bound". Christofides, farthest insertion and savings fall in the "< 15%" group. Space-filling-curve methods are in "Tour Construction Algorithms that Emphasize Speed over Quality". — [DIMACS TSP Challenge results](https://archive.dimacs.rutgers.edu/Challenges/TSP/results.html)
- Fast Lin–Kernighan implementations "can get within 1.5% of optimal on million-city instances in 3 minutes". — [D.S. Johnson, NISS talk 2008](https://www.niss.org/sites/default/files/johnson20080306.pdf)
- On a small TSPLIB set, greedy tours were 19%–31% above optimum, and one 2-opt descent brought them to 2.82%–7.17%. This is a low-authority source (an AI-generated report), so treat it as indicative only. — [k-dense TSPLIB report](https://www.k-dense.ai/examples/session_20260712_115454_474a79e3fd37/writing_outputs/final/TSPLIB.pdf)
- 2-opt is usually "sub-quadratic in n" in practice and gives "tours which are only a few percent worse than the optimum". — [Engels & Manthey, 2-Opt (ORL)](https://foreman.virt.dacs.utwente.nl/~mantheyb/journals/ORL_EngelsManthey_2Opt.pdf)

**Measured savings in machining and cutting**
- Laser cutting: an improvement heuristic (rooted directed minimum spanning tree plus GTSP) gave tool paths 4.2% faster than an existing construction heuristic. — [Dewil et al. 2015, IJPR 53(6):1761–1776](https://ideas.repec.org/a/taf/tprsxx/v53y2015i6p1761-1776.html)
- A practitioner's own reordering program on a 4,000-line engraving "only reduced the machine time by about 10-15 percent". — [Carbide 3D community thread](https://community.carbide3d.com/t/how-to-get-better-toolpath-efficiency/82460)
- Drilling path, hybrid A* plus genetic algorithm: "average overall improvement of 38.8%" over the "traditional tool path method". — [Advances in Mechanical Engineering, Dec 2017 (DOAJ)](https://doaj.org/article/7aedb9c8ce664a10942bc2a244e2889d)
- Particle-swarm approach: "saves up to 40% of the tool's airtime". — [J. Mech. Sci. Technol. 2019, s12206-019-0134-3](https://springerlink.bibliotecabuap.elogim.com/content/pdf/10.1007/s12206-019-0134-3.pdf)
- 5-axis laser drilling sequencing with chained 2-opt local search improved overall cycle time by 26.0%, compared with an industry zig-zag approach and a modified NN. — [Univ. of Waterloo thesis (core.ac.uk)](https://core.ac.uk/download/196559838.pdf), via search snippet; full text not read

**Precedence constraints**
- Castelino, D'Souza and Wright model milling airtime as a generalized TSP *with precedence constraints*. "Cells" are districts, and entry/exit pairs are the cities. — [Castelino et al. 2003, J. Manuf. Syst. 22(3):173–180 (Bohrium listing)](https://www.bohrium.com/paper-details/toolpath-optimization-for-minimizing-airtime-during-machining/811909031554711553-3847)
- Laser cutting handles "inner contours before outer" by using a rooted directed minimum spanning tree over the contour partition together with a GTSP. — [Dewil et al. 2015](https://ideas.repec.org/a/taf/tprsxx/v53y2015i6p1761-1776.html)
- Cutting optimizers determine "paths that are nested inside of closed paths, in order to cut those first". — [Inkscape forum, cutting order optimizer](https://inkscape.org/cs/forums/cutplot/cutting-order-optimizer)
- Kiri:Moto forum users advise cutting inside features before the outline, because the part can shift otherwise. — [grid.space forum (CAM category)](https://forum.grid.space/c/kiri-moto/cam/7?page=6), via search snippet
- Multi-layer operations must keep their layer order. The fightpc author avoided that constraint by cutting full depth in one pass. — [fightpc blog](https://fightpc.blogspot.com/2015/07/minimizing-tool-air-time.html)

### Inferences
**Recommended pipeline for NativeCAM (100–10,000 items)**
1. **Spatial index.** Build a uniform grid or k-d tree of candidate start points.
2. **NN construction.** O(n log n) with the index, versus O(n²) now. That is about 10⁸ distance checks at n = 10k, which is fine but wasteful.
3. **2-opt and Or-opt (move segments of length 1–3, optionally reversed).** Restrict moves to the k = 8–10 nearest neighbours and use don't-look bits. This is the standard Johnson–McGeoch scheme and should run in milliseconds for n ≤ 10k in Swift.
4. **Entry-point re-optimization pass** (see Q2).
5. **Optional Or-3opt / LK-style polishing** only when n is large and time allows.

**Expected savings.** Expect roughly 10–20% less *air travel* than plain NN on scattered features (holes, V-carve letters, nested parts), and less on simple layouts. As a share of total job time the saving is smaller, because cutting dominates. The 26–40% figures in papers are against naive or zig-zag baselines, not against NN.

**Precedence: avoid general precedence-constrained TSP; use hierarchy:**
- **Nesting tree.** Build a tree from containment (Clipper2 PolyTree). A part is an outer contour plus all contours inside it.
- **Outer level.** Order parts with TSP over representative points (or the GTSP trick below).
- **Inside each part.** Solve an open-path TSP over the children (holes, pockets, V-carves), starting at the previous exit and ending near the part's chosen outer entry point. Then cut the outer profile.
- **Moves that stay legal.** 2-opt or Or-opt within one tree level never violates precedence. Moves across levels must be forbidden or feasibility-checked.
- **Depth levels.** These are precedence within the same contour, handled by the region-first vs level-first policy in Q2, not by the TSP.

**Use a time metric, not Euclidean distance.** Cost a link as `t = max(|dx|/vx, |dy|/vy) + retract/plunge time` (or a trapezoidal velocity model). On gantry routers X and Y differ (fightpc's comment), and retract and plunge time often exceeds XY rapid time for short links. That means "which link needs a retract" matters more than raw XY distance.

**Vectric-style portfolio trick.** Compute several orderings (NN from different starts, NN+2-opt, by-part vs global) with the time estimator and keep the fastest. It is cheap and robust.

### Gaps
- I could not open the Johnson & McGeoch (1997) chapter or the DIMACS raw tables. The commonly quoted averages for random uniform Euclidean instances (NN about 25% over the Held–Karp bound, 2-opt with neighbour lists about 5%, LK about 2%) are from memory and **unverified**.
- The Bartholdi–Platzman space-filling-curve figure (often quoted as about 25% over optimal) is also unverified.
- I found no published benchmark of NN vs NN+2-opt specifically on CNC-router job files (V-carve signs, nested plywood).
- I found no runtime benchmarks for CAM-sized instances (100–10k). The runtimes in the Inferences are extrapolated from general TSP experience.
- Full texts of Castelino 2003 and Dewil 2016 were not retrieved (one fetch returned HTTP 504, another HTTP 403), so their numeric results beyond the abstracts are missing.

## 2. Choosing entry/start points on closed loops, and ordering pocket regions and depth levels (level-first vs region-first)

### Takeaway
For closed loops the entry point is a free variable. Kiri:Moto picks it greedily by testing every vertex. The research formulation (Castelino; Dewil) treats each contour as a GTSP cluster of candidate entry points. For depth levels, commercial tools offer both "order by depth" (level-first) and "order by island/region" (region-first), and Fusion's region-first ordering has a long-standing parked bug. Region-first with stay-down step-downs inside each pocket removes most inter-region rapids.

### Cited Findings
**Entry points**
- Kiri:Moto's `poly2polyEmit` scans `poly.forEachPoint` and chooses the vertex nearest the current position as the start index. For open paths it tests first and last points and reverses the path if the last is closer (unless `swapdir:false`). — [Kiri paths.js](https://raw.githubusercontent.com/GridSpace/grid-apps/master/src/geo/paths.js)
- Castelino et al. treat the entry/exit pairs of each cell as the cities of a GTSP cluster. The best entry is chosen jointly with the order, under precedence constraints. — [Castelino et al. 2003 listing](https://www.bohrium.com/paper-details/toolpath-optimization-for-minimizing-airtime-during-machining/811909031554711553-3847)
- Dewil et al. combine GTSP (pierce-point choice) with a contour precedence tree for laser cutting. — [Dewil et al. 2015](https://ideas.repec.org/a/taf/tprsxx/v53y2015i6p1761-1776.html); review: [Dewil, Vansteenwegen, Cattrysse 2016, IJAMT 87:1865–1884 (peeref listing)](https://peeref.com/works/2392411)
- Carbide Create users want a toggle to skip "corner picking" in V-carve. This suggests entry or corner selection rules affect ordering there. — [Carbide 3D thread](https://community.carbide3d.com/t/how-to-get-better-toolpath-efficiency/82460)

**Depth-level and region ordering**
- In Kiri:Moto contour/outline, `depthFirst` changes behaviour:
  - When off: "output the polys in slice order" via `poly2polyEmit` per Z slice (level-first).
  - When on: re-nests polys across layers and `descend()`s through the depth stack (region-first).
  - Outer and inner polys get opposite winding (`setWinding(t, cutdir)` / `setWinding(c, !cutdir)`).
  - Source: [Kiri prepare.js](https://raw.githubusercontent.com/GridSpace/grid-apps/master/src/kiri/mode/cam/work/prepare.js)
- In Fusion's 2D Contour/Pocket, users expect "Order by islands" to finish each depth of a profile before moving on, but it does not:
  - "Preserve order" works with "Order by depth" but "goes completely out the window" for "Order by island". — [Autodesk forum](https://forums.autodesk.com/t5/hsm-forum/2d-contour-w-multiple-depths-and-profiles-order-by-island/td-p/8517114)
  - A 2018 report logged the failure as bug CAM-9911. An Autodesk community manager later said fixing the ordering "was going to be a large project. It's been parked". — [Autodesk forum "Order by island not working"](https://forums.autodesk.com/t5/fusion-support-forum/order-by-island-not-working/td-p/7943265)
- Fusion users trying to clear one pocket at a time untick "Order by depth", but report the tool still jumping between pockets. — [Autodesk forum "toolpath to cut 2 pockets layer by layer"](https://forums.autodesk.com/t5/fusion-manufacture/toolpath-to-cut-2-pockets-layer-by-layer/td-p/10399191)
- Vectric "Merge By Part" groups related geometry so each part is cut together. Contours from earlier toolpaths in the list are cut before later ones within the same part. Without it, all of one toolpath is cut before the next: "the squares are profiled after all the circles are pocketed". — [Vectric Merged Toolpath](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/Create%20Merged%20Toolpath/index.html)
- Estlcam users recommend running each tool across all nested parts rather than finishing part-by-part, to reduce tool changes. — [V1E forum Estlcam thread](https://forum.v1engineering.com/t/do-estlcams-paths-ever-look-inefficient-to-you/20380), via search snippet

### Inferences
**Closed-loop entry-point algorithm (exact per loop, given neighbours)**
- For a closed loop, entry equals exit. Fix the order, then for each loop choose the point p on the loop that minimizes `d(prev_exit, p) + d(p, next_entry)`.
  - On each polygon edge this is a convex function of the edge parameter, so use ternary search or a closed-form reflection trick. Then take the minimum over edges.
  - Alternate "optimize order" and "optimize entries" 2–3 times. This is a cheap stand-in for a GTSP solver and beats Kiri's vertex-only greedy, because the optimum is usually mid-edge.
- Apply legality filters before scoring candidate entries:
  - not on or within a tool radius of a tab;
  - not at a sharp corner if a lead-in or arc is required;
  - enough straight or arc length for the ramp (`rampLength`);
  - lead side on the waste side of the cut;
  - for climb vs conventional direction, entry placement does not change cut direction, only where the loop starts.
- For open paths (V-carve centrelines, engraving), allow reversal (both ends as candidates), as Kiri and FreeCAD's open-route moves do.

**Level-first vs region-first: link counts.** With R regions (pockets/contours) and L depth levels:
- Level-first needs about L·R inter-region links, each needing a retract unless already-cut area connects them.
- Region-first needs about R inter-region links, plus R·(L−1) intra-region step-downs. Those step-downs can stay down: helix or ramp to the next level inside the region's already-cleared footprint, or close the loop and ramp along it.
- NativeCAM currently retracts between pocket depth levels. Switching pockets to region-first with in-region stay-down step-down removes about R·(L−1) retract/plunge pairs.

**When level-first is still preferable:**
- Thin-walled parts (spreading heat and deflection).
- Through-profiles of many small nested parts in plywood: cutting every part's last pass at the end keeps the sheet stiff and holding longer, but costs more links.
- Tabbed profiles, where the final pass across tabs should be grouped.

Make it a per-operation setting ("Order: by depth | by region"), defaulting to region-first for pockets and level-first for final through passes.

**Always-on fix for multi-level pockets and contours.** Even when a retract is needed between levels, do not re-plunge at plunge feed from `plungeZ` above the stock top. Rapid down to (previous floor at this XY + small safe distance) whenever the XY is inside the already-machined footprint, then feed the rest. Plunge time at depth falls from (plungeHeight + depth already cut) / plungeFeed to about safeDistance / plungeFeed.

### Gaps
- I found no quantitative comparison (time saved) of level-first vs region-first ordering on router jobs.
- Vectric's handling of depth passes across multiple vectors in Profile/Pocket (beyond Merge) was not found in docs.
- Fusion's and Vectric's exact entry-point selection rules (e.g., "prefer straight edges", "start at a corner") were not found in official docs.

## 3. Retract strategies (full vs minimum, stay-down, helical/ramped re-entry, stock-aware heights): how vendors implement them, and safety

### Takeaway
Modern CAM decides each link separately:
- **Stay down** if the link lies in already-cut area and is shorter than a "maximum stay-down distance".
- **Minimum retract** otherwise: lift just above the material actually present plus a "safe distance".
- **Full clearance height** only when required (start and end, tool changes, clamp zones).

Hobby CAM (Vectric, Carbide Create, Estlcam, Kiri) mostly uses one Safe Z/clearance per toolpath. The easiest win there is a lower retract height, which users report halved a detailed V-carve's runtime.

### Cited Findings
**Autodesk Fusion (HSM/ModuleWorks Linking tab)**
- "Minimum Retraction… moves the tool straight up to the lowest height where the tool clears the workpiece, plus any specified safe distance". — [Autodesk forum quoting the Retraction Policy popup](https://forums.autodesk.com/t5/fusion-manufacture-forum/3d-adaptive-adjusting-safe-distance-for-minimum-retraction/td-p/7303220)
- The Modify Leads and Links help shows a linking move set to minimum retraction, "which keeps the tool as low as possible". To stay down, increase "Maximum Stay-Down Distance" on the Linking tab. — [Autodesk Fusion help: Modify leads and links](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MODIFY-LEADS-AND-LINKS.htm)
- Edits can apply to a single segment, a group of segments, or the whole toolpath. — [Autodesk blog on leads and links](https://www.autodesk.com/products/fusion-360/blog/unlocking-efficiency-and-customization-with-leads-and-links-modifications-in-autodesk-fusion/)
- "Maximum Stay-Down Distance" controls how long the tool stays down, "which reduces the number of retracts". Setting it to 0 forces retracts on every move.
  - 2D Contour, 2D Offset Roughing (pocket), Trace and Engrave need "Keep Tool Down" ticked first.
  - Thread, Bore, Circular, Chamfer, Rotary and Steep-and-Shallow have no Keep Tool Down.
  - All other strategies always keep tool down.
  - Source: [Fusion help: Stay-Down Distance](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID2E5ABA80-7240-4F1A-989C-2410C4A0CCE5.htm)
- Transition types between passes, set on the Linking tab:
  - "No contact": a retract move, leaving no marks.
  - "Straight line": a constant-angle move along the surface.
  - "Shortest path": usually a straight move.
  - "Smooth": tangential moves "using true arcs where appropriate" that respect the ramp angle.
  - Source: [Fusion help: Transitions Between Cutting Passes](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID32FB2A12-1443-43C9-9C33-A4946E36A888.htm)
- The Fusion API exposes the parameter `retractionPolicy` with values such as "minimum" and "shortest". Some ModuleWorks parameters cannot be changed until the toolpath is calculated. — [Autodesk API forum](https://forums.autodesk.com/t5/fusion-api-and-scripts-forum/modify-leads-and-links-after-toolpath-generation/td-p/13862285)
- Extra retracts in Adaptive persist "if the rapid motion violates the work piece". The main cause is "Minimum stay-down clearance", whose default scales with tool diameter. Users suggest Stay-Down Level around 90% ("Most"). An Autodesk community manager logged it as CAM-65783 and said there is no way to force "Most" to drop those retracts. — [Autodesk forum: Adaptive Clearing, Keep Tool Down](https://forums.autodesk.com/t5/fusion-manufacture-forum/adaptive-clearing-keep-tool-down/td-p/13772503), [3D Adaptive safe distance thread](https://forums.autodesk.com/t5/fusion-manufacture-forum/3d-adaptive-adjusting-safe-distance-for-minimum-retraction/td-p/7303220)

**Vectric (VCarve/Aspire)**
- Safe Z is the rapid height between toolpath segments and "must be sufficient to clear any clamps". This wording came from a similar help page and the official Vectric job-setup page was not opened, so treat it as a paraphrase. — [help page via search](https://help.autodesk.com/cloudhelp/2018/ENU/ARTC-ReferenceHelp/files/GUID-D09593F3-09BE-46C6-A5B5-7E62FB5C3AA0.htm)
- Aspire Keep-out Zones mark bed areas that rapid moves must avoid (Pro feature). Merging toolpaths reduces rapid Z moves, and a lower rapid Z height saves time on large batches. — summary of Vectric tutorial sources: [learnyourcnc, 2 tips for batch toolpaths](https://learnyourcnc.squarespace.com/blog/2-tips-to-save-time-on-batch-toolpaths), [Vectric Aspire what's new](https://vectric.com/upgrade/aspire)

**Kiri:Moto (MIT)**
- Computes the safe height from stock: `stockZClear = stockZ + camZClearance` and `zSafe = Math.max(camZTop, … stockZClear)`. — [Kiri prepare.js](https://raw.githubusercontent.com/GridSpace/grid-apps/master/src/kiri/mode/cam/work/prepare.js)
- Contour uses a topographic model "for safe travel moves when roughing and outlining". — [Kiri op-contour.js](https://raw.githubusercontent.com/GridSpace/grid-apps/master/src/kiri/mode/cam/work/op-contour.js)
- The community guide gives Z Clearance as "the amount your bit will lift above the work while traveling", with 2 mm in its example. — [V1E Kiri guide](https://docs.v1e.com/software/kiri/)
- A forum report: moves that would clip the part get lifted, producing many rapids through material that is cleared later. — [grid.space forum](https://forum.grid.space/c/kiri-moto/5?page=1), via search snippet

**FreeCAD CAM**
- Separates Clearance Height and Safe Height. SafeHeight's property text is "Rapid Safety Height between locations"; ClearanceHeight is the higher rapid height. — [FreeCAD Path/Op/Base.py](https://raw.githubusercontent.com/FreeCAD/FreeCAD/main/src/Mod/CAM/Path/Op/Base.py)
- The ClearanceHeight description text and the Adaptive "Keep Tool Down Ratio" text were not captured: the wiki was blocked by a bot-protection page.

**Estlcam / Carbide Create (practitioner reports)**
- Estlcam lets users "control the heights for each operation". — [V1E forum](https://forum.v1engineering.com/t/estlcam-gcode-optimization-with-carve-and-carve-pocket/31377), via snippet
- Carbide Create: "Reducing the safe/retract and increasing plunge rate cut the carve time in half" for a detailed V-carve (about 6 h originally). — [Carbide 3D thread](https://community.carbide3d.com/t/how-to-get-better-toolpath-efficiency/82460)
- One article says changing retract heights "from 0.5” to 0.050”" takes about 10 seconds and the per-retract saving adds up. The search snippet suggests it is the DATRON blog, but the page was not opened, so the attribution is uncertain. — [DATRON, 6 easy ways to optimize a CNC program](https://www.datron.com/resources/blog/6-easy-ways-to-optimize-cnc-program/)

**Research on retract optimization**
- Optimizing retractions in contour-parallel pocketing has been modelled as a TSP and solved with ant-colony optimization. — [UAEU: Minimizing machining airtime motion with an ant colony algorithm](https://research.uaeu.ac.ae/en/publications/minimizing-machining-airtime-motion-with-an-ant-colony-algorithm/)

### Inferences
**Per-link linking decision for NativeCAM.** Keep a 2D "cleared-region" model per depth: a Clipper2 union of the swept tool footprint (path offset by tool radius) for each completed pass, keyed by floor Z. For each link from exit A to entry B at current depth z:
- **(a) Stay down.** If the segment AB offset by the tool radius lies inside the region cleared to depth ≤ z (with tabs and onion-skin subtracted), and |AB| ≤ maxStayDown: feed (or "high-feed" G1) at depth. Optionally lift slightly (e.g. 0.01–0.02") to avoid dragging on the floor.
- **(b) Minimum retract.** Else lift to h = (highest remaining material under the swept disk of AB) + safeDistance. On a 2.5D sheet that is stock top + safeDistance unless the link is entirely inside a pocket cleared at a higher level.
- **(c) Full retract** to clearanceZ only for the first and last move, around tool changes, and when the link crosses a user "clamp/keep-out" polygon. Optionally give each keep-out polygon its own height.
- **Re-entry after (b) or (c).** Rapid to just above the actual floor or stock top at B, then ramp or helix. NativeCAM already has ramp and helical-arc entry; prefer a helix inside cleared pockets and a ramp along the path for profiles.

**Order of magnitude per link.** Full retract plus re-plunge costs Δz up (rapid) + Δz down (rapid to plungeZ) + plunge distance (at plunge feed). NativeCAM's 0.5" clearance and plunge-feed re-entry through already-cut depth is the dominant cost at deep levels:
- Example: 0.75" ply, 4 levels; plunge at 30 ipm from 0.1" above stock. Reaching level 4 is 0.1 + 0.5625 = 0.66" of feed, about 1.3 s.
- With rapid-to-floor-plus-0.04", the remaining feed is about 0.23", about 0.45 s.
- Multiplied over hundreds of links (V-carve letters, many holes) this is minutes. That matches the forum report of retract height and plunge rate halving a V-carve.

**Safety rules to encode:**
- **Tabs.** Never stay down across a tab, or across any region not cleared to the current depth.
- **Freed parts.** Once a part's through cut finishes, treat its kerf as unsafe for stay-down, because a loose part can shift or lift. After a through cut, retract to stock top + safe distance.
- **Warped or bowed plywood.** The real top can sit above nominal. Make safeDistance a user setting (default ≥ 0.1"; maybe 0.15–0.25" for sheet goods), not a hard-coded tiny value.
- **Clamps and screws.** Mostly outside the part. Use keep-out polygons or clamp height for links that cross them; otherwise keep the low retract.
- **Hold-down.** Vacuum or spoilboard screws inside nested sheets argue for a conservative default.

**Mach4/ESS.** Short G1 links at high feed may be smoother than many tiny G0 up/down pairs on an Ethernet SmoothStepper, but I found no source quantifying this (see Gaps).

### Gaps
- I did not get Autodesk's official definitions of "Full retraction", "Shortest path" retraction, "Safe distance", "Lift height", "Stay-down level" and "High feedrate mode". The official page was not found; the Minimum retraction wording comes from a forum quote of the in-app popup.
- Vectric's official Safe Z/Home pages and any automatic "minimum retract" behaviour (if it exists) were not retrieved.
- Carbide Create's retract options and Estlcam's official docs were not found; only forum reports.
- FreeCAD Adaptive "KeepToolDownRatio" and ClearanceHeight description texts were not captured (wiki blocked).
- No source quantified Mach4/ESS behaviour for G0 vs high-feed G1 links, Avid Z-axis rapid speed/acceleration, or how much plywood typically bows. Those numbers would be needed for an accurate time model.

## 4. Tool-change minimisation and operation ordering across toolpaths (dependencies; manual M6 + touch-plate re-zero on Avid)

### Takeaway
Group operations by tool only where machining-order dependencies allow. Pockets, V-carves and drills come before the cut-out of the same part, clearance tool before V-bit, roughing before finishing. On an Avid with manual changes, each tool change is a stop for a human plus a touch-plate re-zero (minutes, plus Z-zero error risk). That cost is much larger than any air-time saving, so the scheduler should minimise the number of changes first and air time second.

### Cited Findings
- Avid's Mach4 profile provides an M06 macro that "enables manual tool changes when your CAM post processor outputs M06 tool changes". The Tool Change tab has buttons to set an optional Manual Tool Change (MTC) location. — [Avid CNC Mach4 Users Guide v2020Q3](https://www.avidcnc.com/cad/2020Q3/Mach4_Users_Guide_v2020Q3_1.pdf), via search snippet; the PDF's text could not be extracted locally
- Avid users place the Auto Z touch plate directly under the tool-change position so they can touch off right after a manual change. — [Avid CNC forum: G codes for Auto Z touch plate](https://forum.avidcnc.com/t/g-codes-for-auto-z-touch-plate-commands/3525)
- Avid's touch-plate script was hard-coded to G43 H1 and fails when a tool height offset is active. One user's workaround disables the tool height during the touch and restores it afterwards; the same user's custom M6 calls his own macro. — [corbinstreehouse blog: Avid CNC ATC with Mach 4](https://www.corbinstreehouse.com/blog/avid-cnc-atc-automatic-tool-changer-with-mach-4), [Avid forum: touch plate bug](https://forum.avidcnc.com/t/avid-touch-plate-bug-when-a-tool-height-is-set-and-active/1789?page=2)
- The Mach4 sample M6 script moves Z to home and then to fixed X/Y coordinates for the touch pad. — [Mach4 sample m6.mcs](https://www.machsupport.com/ftp/Mach4/Sample%20Scripts%20Mach4/m6.mcs)
- Vectric prompts tool changes at toolpath boundaries. Putting all vectors that use the same tool into one toolpath avoids extra prompts; users also report prompts appearing when consecutive toolpaths use the same bit. For a V-carve with a clearance bit, the clearance bit runs first, then the primary bit. — [Onefinity forum: tool change prompts with same bit](https://forum.onefinitycnc.com/t/tool-change-prompts-when-using-the-same-bit/6784), [Onefinity forum: multiple toolpaths in one file](https://forum.onefinitycnc.com/t/multiple-tool-paths-in-a-single-file-help/29660)
- Vectric merge only combines toolpaths with the same tool, and "Merge By Part" keeps list order per part. — [Vectric Merged Toolpath](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/Create%20Merged%20Toolpath/index.html)
- Yeti Tool's knowledge base documents exporting multiple Vectric files for tool changes, a workaround for machines without M6 support. — [Yeti Tool KB](https://www.yetitool.com/SUPPORT/KNOWLEDGE-BASE/cadcam-software-vectric-further-reading-vectric-exporting-multiple-files-for-tool-changes)
- D'Souza (2006, RCIM) studies setup-level tool *sequence selection* for 2.5D pockets. It notes that the earlier feature-by-feature approach was local, and that connecting all toolpaths per tool to minimise airtime "can lead to tool crashes in certain situations". — [D'Souza, setup-level tool sequence selection (MTU PDF)](https://research.me.mtu.edu/pubs/D'Souza-%20On%20Setup%20Level%20Tool%20Sequence%20Selection%20for%202.5-D%20Pocket%20Machining.pdf), via search snippet; the fetch failed on a certificate error
- For nested multi-part jobs, users advise running each tool across all parts rather than part-by-part, to cut the number of tool changes. — [V1E forum](https://forum.v1engineering.com/t/do-estlcams-paths-ever-look-inefficient-to-you/20380), via snippet

### Inferences
**Scheduling model**
- **Precedence DAG.** Operations are nodes. Add edges for:
  - inside features (pocket, V-carve, drill, engrave) → the profile/cut-out of the same part (nesting tree);
  - roughing → finishing on the same region;
  - clearance/flat-area tool → V-bit for the same V-carve;
  - larger tool → smaller rest-machining tool;
  - any operation whose stock model depends on another.
- **Objective.** Lexicographic: (1) number of tool changes, (2) total estimated time (air + cut), (3) user order as tie-break.
- **Algorithm.** Ready-list scheduling: keep the current tool while any *ready* operation uses it, and when forced to change, pick the tool that unlocks the most remaining work. Job op counts are small (usually < 30), so an exact search is also feasible:
  - DP/branch-and-bound over (set of done ops, current tool);
  - or a DP over topological orders with memo on the done-set, fine for ≲ 20 ops.

**Cost of a manual change on Avid.** M6 → spindle stop → move to MTC location → operator swaps collet/bit → touch-plate Z re-zero → spindle spin-up. That is a human-paced stop measured in minutes. Each re-zero can also introduce a Z offset, which shows up as a visible step between surfaces cut by different tools.
- Never add a tool change to save air time.
- Prefer substituting one tool for two operations where quality allows (e.g., one 1/4" end mill for pockets and profile) and say so in the UI.
- Keep depth-critical mating surfaces on the same tool.
- Emit M6 only when the tool number actually changes, merging adjacent same-tool operations into one linked toolpath; that is the Vectric "same bit" prompt problem.
- Put the MTC location over the touch plate (Avid users' practice) and let the post optionally call the touch-off routine after M6.

**Respect D'Souza's warning.** Merging all same-tool operations across the job into one linked toolpath can create unsafe links, for example rapids across regions whose stock state depends on a later tool. Links must always be checked against the cleared-region/stock model from Q3, not assumed safe.

**Within a tool group.** Order operations with the same TSP machinery as Q1, using operation end/start points (the Vectric merge-by-part analog), while keeping per-part inside-before-outside.

### Gaps
- I could not extract the Avid Mach4 guide text describing the exact M6 sequence: whether it auto-runs the touch plate, Z retract to machine Z0, spindle stop/spin-up delay. The PDF uses compressed streams and local extraction timed out.
- I found no measured typical duration of a manual tool change plus re-zero on Avid machines.
- I found no published Z-repeatability figure for touch-plate re-zeroing.
- The D'Souza 2006 full text (tool-change time model, numeric results) was not retrieved.
- I found no vendor documentation showing an automatic "minimise tool changes" sort in Vectric, Carbide Create or Fusion. Fusion and Vectric appear to keep user order. Fusion's behaviour here is unverified.

## 5. Concrete open-source code: repos, licenses, algorithms, and use in a closed-source/commercial app

### Takeaway
Usable for a commercial Swift app: Google OR-Tools (Apache-2.0), VROOM (BSD-2-Clause), PyVRP (MIT), Clipper2 (BSL-1.0), CavalierContours (MIT). Kiri:Moto is MIT at repo level, but its file headers say "All Rights Reserved", so check before copying. FreeCAD (LGPL-2.1+), OpenCAMLib (LGPL-2.1), jscut (GPL-3.0) and PrusaSlicer (AGPL-3.0) are study-only for a closed app. LKH is academic/non-commercial only. NN + 2-opt + Or-opt is a few hundred lines and should simply be reimplemented in Swift.

### Cited Findings
License data comes from the GitHub API, queried 2026-11-19, unless noted.

| Project | URL | SPDX (GitHub) | Relevant algorithm | Closed-source use |
|---|---|---|---|---|
| Google OR-Tools | https://github.com/google/or-tools | Apache-2.0 | Routing solver (TSP/VRP with local search/metaheuristics) | Yes (permissive, patent grant) — [repo](https://github.com/google/or-tools) |
| FreeCAD CAM `tsp_solver.cpp`, `PathUtils.py` | https://github.com/FreeCAD/FreeCAD | LGPL-2.1(-or-later per file headers) | NN + 2-opt + relocation with start/end constraints; NN hole sort | Study only; LGPL linking/relinking obligations; don't copy code — [tsp_solver.cpp](https://raw.githubusercontent.com/FreeCAD/FreeCAD/main/src/Mod/CAM/App/tsp_solver.cpp), [PathUtils.py](https://raw.githubusercontent.com/FreeCAD/FreeCAD/main/src/Mod/CAM/PathScripts/PathUtils.py) |
| Kiri:Moto (grid-apps) | https://github.com/GridSpace/grid-apps | MIT (repo) **but** `src/geo/paths.js` header reads "Copyright Stewart Allen <sa@grid.space> -- All Rights Reserved" | Greedy NN (`tip2tipEmit`, `poly2polyEmit` with all-vertex entry choice), tip merging, depth-first option, stock-based zSafe | Probably yes under MIT, but the conflicting header means: verify the LICENSE file, keep notices — [repo](https://github.com/GridSpace/grid-apps), [paths.js](https://raw.githubusercontent.com/GridSpace/grid-apps/master/src/geo/paths.js) |
| OpenCAMLib | https://github.com/aewallin/opencamlib | LGPL-2.1 | Drop-cutter/waterline; ships a TSP example (`examples/python/tsp/tsp_01.py`) | Flag LGPL — [repo](https://github.com/aewallin/opencamlib), [Debian copy of tsp example](https://sources.debian.org/data/main/o/opencamlib/2023.01.11-6/examples/python/tsp/tsp_01.py) |
| libarea (HeeksCNC) | https://github.com/Heeks/libarea | GitHub reports none | Pocketing/profiling | Unknown; check source headers before use — [repo](https://github.com/Heeks/libarea) |
| jscut | https://github.com/tbfleming/jscut | GPL-3.0 | Browser CAM | No (copyleft) — [repo](https://github.com/tbfleming/jscut) |
| pycam | https://github.com/SebKuzminsky/pycam | NOASSERTION (GitHub couldn't classify) | 3-axis CAM | Treat as copyleft until verified — [repo](https://github.com/SebKuzminsky/pycam) |
| PrusaSlicer `ShortestPath.cpp` | https://github.com/prusa3d/PrusaSlicer | AGPL-3.0 | Travel-ordering ("chaining") for extrusions | No (AGPL) — [repo](https://github.com/prusa3d/PrusaSlicer); copy in an OrcaSlicer mirror: [ShortestPath.cpp](https://git.trueserve.org/PublicCodeMirror/OrcaSlicer-bambulab/raw/commit/a0b46a40191394f3a3ca0c1a9cc59d2f6eefe8ef/src/libslic3r/ShortestPath.cpp) |
| VROOM | https://github.com/VROOM-Project/vroom | BSD-2-Clause | VRP/TSP heuristics (C++) | Yes — [repo](https://github.com/VROOM-Project/vroom) |
| PyVRP | https://github.com/PyVRP/PyVRP | MIT | State-of-the-art VRP (C++ core, Python API) | Yes — [repo](https://github.com/PyVRP/PyVRP) |
| LKH-2/LKH-3 (Helsgaun) | http://webhotel4.ruc.dk/~keld/research/LKH/ (author site); mirror https://github.com/c4v4/LKH3 | Custom: "free of charge for academic and non-commercial use" | Lin–Kernighan–Helsgaun (best TSP/GTSP heuristic) | No for commercial without permission — [Helsgaun 2009, Math. Prog. Comp.](https://link.springer.com/article/10.1007/s12532-009-0004-6), [LKH3 mirror](https://github.com/c4v4/LKH3) |
| elkai (LKH-3 wrapper) | https://github.com/fikisipi/elkai | NOASSERTION; README says LKH native code is non-commercial | LKH-3 | No — [repo](https://github.com/fikisipi/elkai), [libraries.io](https://libraries.io/pypi/elkai) |
| Clipper2 | https://github.com/AngusJohnson/Clipper2 | BSL-1.0 | Polygon boolean/offset/PolyTree (for nesting tree and cleared-region model) | Yes — [repo](https://github.com/AngusJohnson/Clipper2) |
| CavalierContours | https://github.com/jbuckmccready/CavalierContours | MIT | Arc-aware polyline offset/boolean | Yes — [repo](https://github.com/jbuckmccready/CavalierContours) |
| GCodeClean | (repo not found at `md8n/GCodeClean`) | unknown | Splits G-code at travel moves and TSP-reorders the blocks | Unknown — [Carbide forum mention](https://community.carbide3d.com/t/how-to-get-better-toolpath-efficiency/82460) |

- LKH has also been used directly in toolpath generation: "Tool path generation for multi-axis freeform surface finishing with the LKH TSP solver". — [Bohrium/arXiv listing](https://bohrium.dp.tech/paper/arxiv/573695f26e3b12023e506b58)

### Inferences
- **Recommended for NativeCAM.**
  - Write a native Swift TSP module: NN with grid index, then 2-opt plus Or-opt with neighbour lists and don't-look bits, then the entry-point re-optimization pass.
  - Algorithms are not copyrightable, so reimplementing FreeCAD's documented approach in your own code is fine. Do not copy LGPL/GPL/AGPL source.
  - OR-Tools (Apache-2.0) is an option for an exact or near-exact "solve harder" mode with precedence. Its routing library supports pickup-and-delivery precedence and node disjunctions (GTSP-style "visit one of these entry points"). This is from my knowledge of OR-Tools' API; its docs were not fetched here.
  - OR-Tools is a large C++ dependency to build for arm64 macOS, so it is probably overkill for n ≤ 10k Euclidean instances.
- **Geometry.** Use Clipper2 (BSL-1.0, already chosen per project memory) for the nesting tree (PolyTree), the cleared-region model for stay-down checks, and keep-out polygons.
- **Avoid in a closed-source app:** LKH, Concorde (see Gaps), elkai, PrusaSlicer, jscut, pycam, and code-level reuse of FreeCAD and OpenCAMLib.

### Gaps
- I found no source stating Concorde's license terms.
- OpenCAMLib's TSP example algorithm (likely Boost's `metric_tsp_approx`) was not verified.
- libarea's license is undetermined (GitHub reports none).
- pycam is NOASSERTION on GitHub; its actual license (believed GPL) is not verified here.
- PrusaSlicer `ShortestPath.cpp` algorithm details (greedy chaining plus improvement) were not read.
- I found no Swift-native TSP package of note and did not search crates/Swift Package Index exhaustively.
- OR-Tools feature claims (disjunctions, pickup-and-delivery) are not sourced from its docs in this session.

## 6. Published papers and benchmarks on CNC tool-path sequencing / air-time reduction, with quantified results

### Takeaway
The core model is a generalized TSP with precedence constraints (Castelino et al. 2003; Dewil et al. for laser cutting). Reported savings depend heavily on the baseline:
- about 4% over a good construction heuristic (laser cutting);
- 10–15% from reordering hobby G-code;
- 26–40% over naive, zig-zag or "traditional" orders (drilling).

### Cited Findings
- **Castelino, D'Souza, Wright (2003)**, "Toolpath optimization for minimizing airtime during machining", J. Manufacturing Systems 22(3):173–180. Models airtime as a GTSP with precedence (cells = districts, entry/exit pairs = cities), implemented in an automated process-planning system, and "can be applied… to fused deposition modeling and laser cutting". — [Bohrium listing](https://www.bohrium.com/paper-details/toolpath-optimization-for-minimizing-airtime-during-machining/811909031554711553-3847)
- **D'Souza (2006)**, RCIM: setup-level tool sequence selection for 2.5D pockets; per-tool airtime linking can cause crashes. — [MTU PDF](https://research.me.mtu.edu/pubs/D'Souza-%20On%20Setup%20Level%20Tool%20Sequence%20Selection%20for%202.5-D%20Pocket%20Machining.pdf), via snippet
- **Dewil, Vansteenwegen, Cattrysse, Laguna, Vossen (2015)**, IJPR 53(6):1761–1776: improvement heuristic (rooted directed MST + GTSP) gives tool paths 4.2% faster than an existing construction heuristic. — [RePEc](https://ideas.repec.org/a/taf/tprsxx/v53y2015i6p1761-1776.html)
- **Dewil et al. (2014)**, IJPR 52(20):5965–5984: construction heuristics for laser cutting tool paths. — [RePEc/related listing](https://ideas.repec.org/a/taf/tprsxx/v53y2015i6p1761-1776.html), via search summary
- **Dewil, Vansteenwegen, Cattrysse (2016)**, "A review of cutting path algorithms for laser cutters", IJAMT 87:1865–1884, DOI 10.1007/s00170-016-8609-1. Classifies cutting-path problems and their technical side constraints. — [Peeref](https://peeref.com/works/2392411)
- **Ant colony optimization for contour-pocketing airtime**: tool retraction optimization modelled as a TSP. — [UAEU research portal](https://research.uaeu.ac.ae/en/publications/minimizing-machining-airtime-motion-with-an-ant-colony-algorithm/)
- **Hybrid A* + GA for drilling paths (2017)**: "average overall improvement of 38.8%" in cutting-tool travel distance vs the traditional method. — [Advances in Mechanical Engineering, DOAJ](https://doaj.org/article/7aedb9c8ce664a10942bc2a244e2889d)
- **PSO airtime optimization (2019)**, J. Mech. Sci. Technol.: "saves up to 40% of the tool's airtime". — [JMST PDF](https://springerlink.bibliotecabuap.elogim.com/content/pdf/10.1007/s12206-019-0134-3.pdf)
- **Woo (Waterloo thesis)**, 5-axis laser drilling: chained 2-opt sequencing improved overall cycle time 26.0% vs industry zig-zag and modified NN baselines. — [core.ac.uk](https://core.ac.uk/download/196559838.pdf), via snippet
- **PCB drilling (2026)**: NN and insertion "offer high computational efficiency and are commonly used to generate initial paths", but solution quality is limited, so refinement follows. — [Manufacturing Review 13, 11 (2026), DOI 10.1051/mfreview/2026005](https://mfr.edp-open.org/articles/mfreview/pdf/2026/01/mfreview250076.pdf), via snippet
- **ACO parameter tuning** (Ma) gave a 6% path-length reduction in a drilling context. — via search snippet, from the review search results ([core.ac.uk 235662849](https://core.ac.uk/download/235662849.pdf)); exact source not confirmed
- **Multi-axis finishing with LKH**: LKH used for tool path generation in freeform surface finishing. — [arXiv/Bohrium](https://bohrium.dp.tech/paper/arxiv/573695f26e3b12023e506b58)
- **Practitioner datapoints**: a 4,000-line engraving reorder gave a 10–15% machine-time cut; lower retract height plus higher plunge rate halved a detailed V-carve. — [Carbide 3D thread](https://community.carbide3d.com/t/how-to-get-better-toolpath-efficiency/82460)
- **TSP benchmark framing**: the DIMACS challenge reports quality as % over the Held–Karp bound. — [DIMACS](https://archive.dimacs.rutgers.edu/Challenges/TSP/results.html)

### Inferences
- Compared with NativeCAM's current state, the largest measurable wins are likely, in order:
  1. Smarter retract/re-entry: lower retracts, stay-down in cleared areas, rapid to near-floor before plunging. Forum evidence suggests up to about 2x on retract-heavy V-carves.
  2. Region-first pockets with stay-down step-downs.
  3. Fewer tool changes on Avid (minutes each).
  4. Ordering improvements over NN (about 5–15% of air-travel distance).
- Papers reporting 26–40% compare against naive baselines, so do not promise users those figures relative to NN.
- Build an internal benchmark: a set of real Avid jobs (sign V-carve, nested cabinet parts, drilled shelf-pin rows) with the time estimator. Compare NN vs NN+2-opt/Or-opt vs entry-point optimization vs retract policies, to get NativeCAM-specific numbers.

### Gaps
- Full-text numeric tables for Castelino 2003, D'Souza 2006 and Dewil 2014/2016 were not retrieved (paywalled or fetch errors).
- I found no published router- or woodworking-specific air-time benchmark.
- I found no PCB benchmark giving NN vs NN+2-opt percentages on a standard instance (e.g., pcb442). The ENGRI 1101 textbook poses that comparison but its rendered page does not show the numbers: [ENGRI 1101 TSP modeling](https://engri-1101.github.io/textbook/chapters/tsp/tsp_modeling_web.html).
