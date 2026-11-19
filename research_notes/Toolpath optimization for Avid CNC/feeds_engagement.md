# Feed-rate and engagement optimization for CNC routing of wood and sheet goods (NativeCAM / Avid PRO)

Scope note: all findings are for wood, plywood, MDF and particleboard on gantry routers unless marked **[metal]** or **[plastics]**. Claims marked "(search snippet)" came from search-result summaries whose page I could not fetch or verify line-by-line; treat them as lower confidence. Formulas I derived myself, rather than found, are in the Inferences sections and labelled "derived".

---

## 1. Chip load fundamentals, radial chip thinning and axial (depth) considerations

### Takeaway
Router chip-load charts give per-tooth chip load by diameter and material at depth of cut up to 1xD. They derate by 25% at 2xD and 50% at 3xD. They assume a full chip, meaning radial engagement of 50% or more. Below 50% engagement the real chip is thinner than the programmed feed per tooth. The standard compensation is `fz_adj = fz * D / (2*sqrt(D*ae - ae^2))`, which is the same as `fz / sin(phi)`. It must not be applied to slotting, plunging or other uncontrolled-engagement moves.

### Cited Findings
**Core formulas (all manufacturers agree)**
- `Chip Load = Feed Rate / (RPM x flutes)`, `Feed Rate = RPM x flutes x chip load`, `RPM = Feed Rate / (flutes x chip load)`, with feed in IPM. Worked example: 18,000 RPM x 2 flutes x 0.019" = 684 IPM. — [Freud CNC feed & speed guide (PDF)](https://www.freudtools.com/public/assets/freud/downloadables/freudtools-router-bit-feed-and-speed-for-cnc-20170822.pdf)
- Amana's charts give the same feed and chip-load formulas plus `RPM = SFM x 3.82 / diameter`. Most of Amana's CNC router charts assume an 18,000 RPM spindle (search snippet). — [Amana Spektra 3D profiling chart (PDF)](https://cdn.shopify.com/s/files/1/1558/5651/files/A_Spektra-Coated-3D-Profiling-Feed-Chip-Load-Chart-v7.pdf)

**Why chip load matters for wood (burning)**
- Freud's reasoning: a very small chip, or sawdust, does not carry enough heat away from the edge, and the excess heat dulls carbide early. A chip that is too large leaves a rough edge. — [Freud guide](https://www.freudtools.com/public/assets/freud/downloadables/freudtools-router-bit-feed-and-speed-for-cnc-20170822.pdf)

**Freud solid-carbide chip loads (inches per tooth, depth of cut = 1xD)** — [Freud guide](https://www.freudtools.com/public/assets/freud/downloadables/freudtools-router-bit-feed-and-speed-for-cnc-20170822.pdf)

| Dia | MDF/Particle | Lam. particle | Hardwood | Softwood | Acrylic/soft plastic | Solid surface/hard plastic | Plywood |
|---|---|---|---|---|---|---|---|
| 1/8" | .004–.007 | .003–.006 | .002–.005 | .004–.006 | .003–.005 | .002–.004 | .003–.005 |
| 1/4" | .013–.017 | .010–.015 | .008–.011 | .010–.012 | .006–.009 | .005–.008 | .006–.009 |
| 3/8" | .018–.021 | .014–.018 | .014–.016 | .016–.019 | .010–.012 | .008–.010 | .015–.018 |
| 1/2" | .023–.027 | .022–.026 | .018–.021 | .020–.023 | .012–.015 | .010–.012 | .018–.021 |

- Freud's carbide-tipped straight and profile bits use much lower values. At 1/2" the ranges are MDF .006–.007, hardwood .008–.010, softwood .008–.012 and plywood .007–.009; at 3/4" they are MDF .007–.009 and plywood .009–.011. — [Freud guide](https://www.freudtools.com/public/assets/freud/downloadables/freudtools-router-bit-feed-and-speed-for-cnc-20170822.pdf)

**Onsrud-based chart (as reproduced from the 2017 LMT Onsrud catalog, inches per tooth)** — [Artisan's Asylum wiki, citing the Onsrud catalog](https://wiki.artisansasylum.com/wiki/ShopBot_Feeds_and_Speeds_and_Chip_Load)

| Material | 1/4" | 1/2" |
|---|---|---|
| Softwood | .002–.020 | .003–.030 |
| Hardwood | .005–.020 | .005–.030 |
| MDF | .005–.020 | .005–.030 |
| Plywood | .005–.020 | .005–.030 |
| Laminated chipboard | .008–.020 | .010–.030 |
| Soft plastic **[plastics]** | .004–.012 | .006–.014 |
| Hard plastic **[plastics]** | .006–.012 | .008–.016 |

- Amana Spektra 1/4" ball nose (3D carving) at 18,000 RPM: wood/MDF/sign foam 0.007"–0.009" chip load, 250–320 IPM; acrylic 0.004"–0.006" (search snippet). — [Amana Spektra 3D chart (PDF)](https://cdn.shopify.com/s/files/1/1558/5651/files/A_Spektra-Coated-3D-Profiling-Feed-Chip-Load-Chart-v7.pdf)
- MDF hardness and density vary a lot between manufacturers, so chart values are only a starting point (forum, search snippet). — [ShopBot feeds & speeds PDF / forum discussion](https://support.shopbottools.com/ShopBotDocs/files/FeedsandSpeeds.pdf)

**Axial (depth-of-cut) derate**
- Freud: "If Cut Depth is 2X the bit diameter, reduce the Chip Load by at least 25%; if 3X, reduce by at least 50%." Example: 0.019" x 0.75 = 0.014" for a 1/2" bit cutting 1" deep. — [Freud guide](https://www.freudtools.com/public/assets/freud/downloadables/freudtools-router-bit-feed-and-speed-for-cnc-20170822.pdf)
- The Onsrud-based chart gives the same 25% derate at 2xD and 50% at 3xD. — [Artisan's Asylum wiki](https://wiki.artisansasylum.com/wiki/ShopBot_Feeds_and_Speeds_and_Chip_Load)

**Radial chip thinning**
- Helical Solutions: tool engagement angle is the arc of the cutter periphery in contact with material and "directly related to the radial chip thickness." Below 50% RDOC, the chip is much thinner than the programmed advance per tooth. The adjustment formula is `CLPT_adj = CLPT x D / (2 x sqrt(D x RDOC - RDOC^2))`. Helical also warns that this adjustment still has to respect engagement-angle increases in corners. — [Helical Solutions, "Angle of Engagement & Chip Thinning" (PDF, catalog p.102)](https://cdn.shopify.com/s/files/1/0961/5830/files/Milling-_Angle_of_Engagement_and_Chip_Thinning.pdf)
- Harvey Performance: at 50% stepover, chip thickness equals feed per tooth. Below 50% RDOC the maximum chip thickness falls. The goal is "constant chip thickness by adjusting the feed rate," using the recommended IPT at 50% as the target chip thickness. — [Harvey Performance, In The Loupe](https://www.harveyperformance.com/in-the-loupe/combat-chip-thinning/)
- Exact factor: `RCTF = 1 / sqrt(1 - (1 - 2*WOC/D)^2)`, multiplied onto the programmed IPM. At 10% stepover the feed rises 1.66x. The same source says not to apply it to full-width slotting, plunging or uncontrolled engagement, and it also gives a cruder approximation, `D/(2*ae)`, that disagrees at larger engagement. — [JLC CNC chip thinning guide](https://jlccnc.com/blog/chip-thinning) (aggregator)
- Dapra's data points: 35% WOC gives an actual chip of 95% of programmed fz (multiplier 1.05), and 10% WOC gives a 1.70x multiplier. The adjustment applies below 50% of tool diameter. **[metal, but geometric so it transfers]** — [Dapra, radial chip thinning](https://www.dapra.com/articles/radial-chip-thinning)
- A Fusion user forum claim: Fusion does not apply chip thinning itself, so the user has to account for it (search snippet). — [Autodesk forum, adaptive stepdown thread](https://forums.autodesk.com/t5/fusion-manufacture-forum/recommended-stepdown-for-adaptive-clearing/m-p/6891051/highlight/true)

### Inferences
- **Derived equivalence.** Helical's formula, the RCTF and `1/sin(phi)` are the same expression, where `phi = arccos(1 - 2*ae/D)` is the engagement angle. `sin(phi) = (2/D)*sqrt(D*ae - ae^2)`. NativeCAM can therefore work entirely in engagement angle:
  - `h_max = fz * sin(phi)` for `phi <= 90°`
  - `h_max = fz` for `90° <= phi <= 180°`
  - Chip-thinning feed multiplier: `m_ct(phi) = 1/sin(phi)` for `phi < 90°`, otherwise 1.
- **Derived multiplier table**, with `ae/D` mapped to `phi` and `m_ct`:

  | ae/D | phi | m_ct |
  |---|---|---|
  | 5% | 25.8° | 2.29 |
  | 10% | 36.9° | 1.67 |
  | 20% | 53.1° | 1.25 |
  | 30% | 66.4° | 1.09 |
  | 40% | 78.5° | 1.02 |
  | 50% and above | — | 1.00 |

  This matches Dapra's 1.70 at 10% and JLC's 1.66.
- **Combined target chip.** `h_target = fz_chart(material, D, z) * k_ap`. The depth factor `k_ap` is 1.0 at depth ≤ 1D, 0.75 at 2D and 0.5 at 3D, interpolated linearly in between. That interpolation is my assumption; the sources give only the three points.
- **Effective diameter for non-flat tools (derived geometry, not sourced).**
  - Ball nose at depth `ap < R`: `D_eff = 2*sqrt(ap*(D - ap))`.
  - V-bit: `D_eff = 2*ap*tan(theta/2)` plus the tip flat.
  - Use `D_eff` for surface speed and for picking a chip load from charts, as Amana gives separate ball-nose chip loads.
- **Burning floor.** The lower bound of the chart is effectively the minimum safe chip: about 0.005" for hardwood, MDF and plywood at 1/4"–1/2" (Onsrud). NativeCAM should warn whenever a scheduled `n*z*h` falls below the floor, because that rubs and burns.

### Gaps
- I could not open Onsrud's, Whiteside's or Vortex's own current charts (the onsrud.com feed-speed pages were not reachable). The Onsrud values above are a third-party reproduction of the 2017 catalog.
- I did not verify per-flute-count differences (for example, whether 3-flute charts use lower per-tooth loads).
- I found no wood-specific axial chip-thinning data for ball nose tools; only the geometric formula is available.

---

## 2. Engagement-based feed scheduling: algorithms and how to compute engagement

### Takeaway
Commercial CAM uses two families of approach:
- **Geometric corner slowdown.** Fusion's Feed Optimization keys on direction change, radius and distance. It is simple, but it ignores actual stock.
- **Engagement-controlled toolpaths.** Fusion Adaptive "Optimal Load", Mastercam Dynamic/OptiRough and FreeCAD Adaptive constrain engagement or cut area while generating the path.

The literature divides into MRR (volumetric) scheduling and force-model scheduling, and finds force-based more reliable. No published cutting-force coefficients for wood turned up, so for NativeCAM the practical method is geometric. Compute engagement from a cleared-region polygon (Clipper2) or a raster stock model, then cap both peak chip thickness and MRR.

### Cited Findings
**Fusion Feed Optimization (geometric)** — [Autodesk Fusion Feed Optimization reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUIDCFB956EA-793B-4F8A-B487-028219913D96.htm)
- *Maximum Directional Change*: "the maximum angular change allowed before the feedrate is reduced."
- *Reduced Feed Radius*: "the minimum radius allowed before the feed is reduced."
- *Reduced Feed Distance*: "the distance to reduce the feed before a corner."
- *Reduced Feedrate*: "the reduced feedrate to be used at corners."
- *Only Inner Corners*: "only reduce the feedrate on inner corners."
- The page lists no defaults.

**Fusion Feed Optimization: user-reported pitfalls (forum, search snippet)**
- Reduced Feed Radius applies to radii smaller than the value entered.
- "Only inner corners" has been reported as buggy.
- Corners made of many short line segments may not be detected, because the optimizer looks for curvature across segments.
- A fillet at least as large as the tool radius is the better fix.
- Source: [Autodesk forum thread](https://forums.autodesk.com/t5/fusion-manufacture/feed-optimization-slows-all-corners-when-quot-only-inner-quot-is/td-p/9238577); [Autodesk forum thread 2](https://forums.autodesk.com/t5/fusion-manufacture-forum/feed-rate-optimization-what-am-i-missing/m-p/7367240)

**Fusion Adaptive "Optimal Load"**
- Optimal Load is the maximum engagement the toolpath keeps; adaptive "will vary the stepover to reduce overloading the tool," so stepover is equal to or less than this value. — [Autodesk 2D Adaptive Clearing reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUIDA73542E9-ED9C-4BD9-A87D-3A0ECA8BEB41.htm); [Autodesk Adaptive steps](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/3D-ADAPTIVE-STEPS.htm)
- Hobby-router users report about 1 mm Optimal Load in hardwood with 1/4" tools. These are desktop-class machines, far less rigid than an Avid PRO (search snippet). — [Carbide 3D community, adaptive in hardwood](https://community.carbide3d.com/t/recipes-for-adaptive-clearing-in-hardwood-201-endmill/40760)

**Mastercam Dynamic Motion / OptiRough**
- Mastercam describes Dynamic Motion as optimizing engagement "to maintain a constant chip load," adjusting both motion and feed rates, and applying radial chip thinning to any geometry rather than only to straight passes (marketing material, search snippet). — [Mastercam Dynamic](https://www.mastercam.com/dynamic); [Mastercam OptiRough blog](https://www.mastercam.com/community/blog/optirough-the-roughing-solution-you-might-be-overlooking/)
- A reseller article says basic radial chip thinning holds chip load "until it enters a corner or curve at which the cutter engagement is greatly increased and overloads the tool." Dynamic paths fix this by changing the trajectory, not just the feed (search snippet). — [CimQuest article](https://cimquest-inc.com/?p=7630)
- I found no public algorithm details for Mastercam.

**FreeCAD CAM Adaptive (open source, LGPL)**
- The operation manages cutter engagement so that engagement and material removal never exceed a maximum. — [FreeCAD wiki: CAM Adaptive](https://wiki.freecad.org/CAM_Adaptive)
- Its header (Kresimir Tusek, 2018, LGPL-2.1-or-later) builds on Clipper. It has constants for an engage-area threshold, a minimum cut-area factor, an area error factor of 5% ("how precise to match the cut area to optimal") and at most 10 iterations. The original add-on describes keeping a constant material removal rate set by Step Over and Step Down. — [FreeCAD Adaptive.hpp (mirror)](https://huggingface.co/AbdulElahGwaith/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.hpp); [FreeCAD_Mod_Adaptive_Path mirror](https://gitee.com/BinGo2019/FreeCAD_Mod_Adaptive_Path)

**Academic feedrate scheduling**
- Layegh, Erdim and Lazoglu (MERL TR2012-041, Procedia CIRP 2012) compute cutter-workpiece engagement per cutter location with the Parasolid solid modeller. They estimate cutting force and set the feed per NC block so the resultant force stays at a user threshold, relying on a linear force-feed relation. They report a drastic cycle-time reduction on an impeller. **[metal]** — [MERL TR2012-041](https://www.merl.com/publications/docs/TR2012-041.pdf)
- The same paper cites Erdim, Lazoglu and Ozturk, who compared MRR-based and force-based 3-axis scheduling and found force-based "more applicable and reliable." It states "volumetric based feedrate strategy is insufficient for determining the optimum feedrate values." **[metal]** — [MERL TR2012-041](https://www.merl.com/publications/docs/TR2012-041.pdf)
- Kloypayan and Lee, "Adaptive Feedrate Scheduling and Material Engagement Analysis for High Performance Machining," analyzes MRR for cutter geometries and schedules feed to hold cutting load roughly constant on 2.5D pocket paths. The PDF returned 403, so this is from the search snippet only. — [core.ac.uk PDF](https://core.ac.uk/download/357378215.pdf)
- A 2003 paper on off-line feedrate scheduling for pocket machining proposes an improved cutter-engagement model over MRR or force models (search snippet). — [Springer, 10.1007/s00170-003-1609-y](https://springerlink.bibliotecabuap.elogim.com/content/pdf/10.1007/s00170-003-1609-y.pdf)
- Jacso et al. (2023, trochoidal milling) note that geometric methods keep chip thickness or MRR constant to control load (search snippet). — [Springer, 10.1007/s00170-023-11506-x](https://link.springer.com/article/10.1007/s00170-023-11506-x)
- Modern Machine Shop distinguishes horizontal engagement (sweep angle) from vertical engagement (instantaneous edge engagement) under constant material removal. **[metal]** — [MMS, constant material removal](https://mmsonline.com/articles/constant-material-removal-the-key-to-hard-milling)

### Inferences
**Recommended two-constraint feed law for NativeCAM (derived).** Define the tool's stored "feed" as the reference slot or profile feed `F_ref = n * z * h_target` at depth ≤ 1D. That matches how router charts are used to cut parts out. Per path sample:

```
phi      = local engagement angle (from stock model)
m_ct     = 1/sin(phi)            if phi < 90°, else 1        // keep peak chip = h_target
MRR(F)   = ae_eff * ap * F,  ae_eff = r*(1 - cos(phi)) for straight-line cutting
F_chip   = F_ref * k_ap * min(m_ct, m_ct_max)                 // m_ct_max ~2.0-2.5, user-tunable
F_power  = MRR_max / (ae_eff * ap)                            // MRR_max calibrated from a known-good slot: D*ap_ref*F_slot
F        = clamp(min(F_chip, F_power, F_machine_cut_max), F_floor, ...)
F_floor  = n * z * h_min_chart                                // burn floor; if F_power < F_floor -> warn (reduce stepover/depth), don't silently drop
```

- **Scalars are enough.** For `phi >= 90°` the chip-thickness constraint already binds: `h_max = fz`, so there is no boost. Full slotting (`phi = 180°`) therefore runs at `F_ref`, and light-stepover finishing runs up to `m_ct_max` times faster. Under a linear force model the per-tooth integrated chip area is proportional to `fz*(1 - cos(phi)) = fz*ae/r`. The MRR cap therefore stands in for average force, and `h_max` stands in for peak edge load. Neither needs wood force coefficients.

**Computing `phi` with Clipper2 (which NativeCAM already vendors).**
1. Keep a cleared region `C` per Z layer.
2. The disc swept along a polyline is exactly `InflatePaths(open path, delta = r, JoinType::Round, EndType::Round)`. After each pass, set `C = Union(C, sweep)`.
3. Evaluate pass k against `M = Stock - C_(k-1)`. At each sample point P with motion direction t, sample the leading semicircle of radius r at N angles (N ≈ 90–180) and test point-in-polygon against M.
4. The engaged arc gives `phi`, and its two end angles give entry and exit, so climb versus conventional can be told apart.
5. Restricting to the leading semicircle stands in for "already cut by this pass" on smooth paths.
6. At sharp reversals, for exact accuracy, also subtract the sweep of the current pass up to P−Δ.
7. Sample spacing of about 0.05–0.1·D, with refinement where `phi` changes quickly, should catch corner spikes.

**Area-based alternative (FreeCAD-style idea, re-derived, not copied: LGPL).** Cut area per step is `A = area(Inflate(segment P_i→P_(i+1)) ∩ M)`. Then `ae_eff = A/|Δ|` and `phi_eff = arccos(1 - ae_eff/r)`. This is cheaper and integrates well with Clipper2. It underestimates peak engagement inside a step.

**Raster alternative.** NativeCAM already uses Metal. A 2D height or occupancy bitmap at about 0.05–0.1 mm per pixel, with a compute kernel counting stock pixels on the leading arc per sample, would parallelize well and generalizes to 3D roughing through a Z-map. This is the dexel/Z-map approach many papers use.

**Emitting feed changes.**
- Quantize F to about 5% bins.
- Require a minimum run length (say ≥ 0.5·D) before changing F, with hysteresis.
- Apply decreases early: start the slowdown one look-ahead distance before the spike, as Fusion's "Reduced Feed Distance" does.
- Apply increases only after the spike has passed. This avoids flooding Mach4 with F words and avoids trapezoidal accel and decel at every small change.

**Phasing for v1.** Build Fusion-style geometric corner slowdown first (direction change, radius, distance, %), then add stock-model engagement. The geometric version misses stock-dependent spikes: the leftover corner material in offset pockets, the first slot after a helix, and rest material.

### Gaps
- I found no published specific cutting energy or force coefficients for wood or MDF suited to a force model. `MRR_max` has to be user-calibrated or derived from spindle power and a guessed specific energy.
- I could not access full texts of Kloypayan & Lee or the 2003 pocket paper, so their exact formulations are not captured.
- Vectric (VCarve/Aspire) documentation shows no engagement-based feed adjustment; its profile page mentions no corner feed reduction ([Vectric 2D Profile docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/uiProfileMachineForm/index.html)). I did not confirm whether newer Vectric versions add one.

---

## 3. Entry strategies: helix, ramp, plunge; angles, diameters, plunge rates; upcut, downcut and compression

### Takeaway
- **Order of preference:** helix, then ramp, then plunge.
- **Ramp angles:** published guidance is mostly metal-oriented, at 0.5–3°. Router practice tolerates more with center-cutting spiral bits. I found no wood-specific manufacturer ramp-angle spec.
- **Carbide-tipped straight bits:** must not plunge-drill.
- **Compression bits:** the first pass must reach below the upcut section, often about 1xD (shorter on "mortise" compression bits).
- **Ramp feed:** Vectric runs every ramp at the plunge rate. A better rule caps Z velocity and keeps XY feed near cutting feed so the tool does not dwell.

### Cited Findings
**Entry ranking and plunge feed**
- Ranking: helical interpolation causes the least tool wear, ramping is next, and plunging is harshest. Plunging needs a center-cutting tool. Plunge feed rule of thumb is slot feed divided by number of flutes. Typical conservative ramp angles are 1.5° and 2.5°, and OSG cites 10°–20° for some premium end mills. **[metal]** — [CNCCookbook helical/ramp calculator article](https://www.cnccookbook.com/helical-interpolation-ramp-angle-calculator-best-ways-to-enter-a-cut)

**Helix formulas** **[metal source, geometry is general]** — [CNCCookbook](https://www.cnccookbook.com/helical-interpolation-ramp-angle-calculator-best-ways-to-enter-a-cut)
- Tool-centre path diameter = hole − tool.
- Programmed (centre) feed = edge feed x (hole − tool) / hole. For example, 43 x 1.5 / 2 = 32 IPM for a 1/2" tool in a 2" hole.
- Ramp angle = `arctan(depth_per_rev / (pi * centre_path_diameter))`, which gives about 3.0° in their example.
- Avoid holes tight to the cutter diameter, because chip evacuation suffers.

**Helix and ramp in Fusion (forum)**
- An Autodesk staff member gives Fusion's default 2D-adaptive helix diameter as `Math.max((tool_diameter - 2*tool_cornerRadius)*0.95, tool_diameter*0.25)`. A user notes that a helix below about half the tool diameter loses its benefit. Staff also say most tools do not allow much more than about 3° ramping, and that cutter suppliers specify the maximum ramp angle (search snippet). — [Autodesk forum: Minimum Helix Diameter](https://forums.autodesk.com/t5/fusion-manufacture-forum/minimum-helix-diameter/td-p/8516994); [Autodesk forum: Ramp Angle & Plunging Approaches](https://forums.autodesk.com/t5/fusion-manufacture-forum/ramp-angle-amp-plunging-approaches/td-p/12816036)
- The same forum material gives pitch as `pi*D*sin(angle)`. That is an approximation of CNCCookbook's exact `tan` relation; see Inferences.

**Seco helical ramp angle**
- Seco advises helical ramp angles of 0.5°–1° (search snippet). **[metal]** — [Seco Tools, Helical Interpolate Like A Pro](https://www.secotools.com/article/125931)

**FeatureCAM fallback logic**
- If the computed horizontal ramp distance is shorter than the "Minimum ramp distance" (a percentage of tool diameter), the tool plunges instead. A "Max. ramp angle" setting applies, and helical ramping is used when enabled, otherwise zigzag. — [Autodesk FeatureCAM Lead/Ramp page](https://help.autodesk.com/cloudhelp/2022/ENU/FCAM/files/GUID-2F2383B5-EE1B-41A8-A638-93F291BD3D2C.htm)

**Vectric ramp options** — [Vectric Aspire 12.5, 2D Profile](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/uiProfileMachineForm/index.html)
- *Smooth*: ramps by distance or angle.
- *Zig Zag*: by distance or angle; the angle option is "typically used for cutters that cannot plunge vertically."
- *Spiral*: ramps around the whole profile with the angle computed automatically; only available without lead-ins.
- "All ramp moves are performed at the plunge rate selected for the current tool."
- Lead-ins can be straight (angle and length) or circular (radius and angle, 0.1–90°), plus an overcut distance.

**Bit manufacturers on plunging and ramp-down**
- Freud: "Carbide tipped bits should not be used to drill directly into the work piece." — [Freud guide](https://www.freudtools.com/public/assets/freud/downloadables/freudtools-router-bit-feed-and-speed-for-cnc-20170822.pdf)
- Amana spiral plunge sheets give a ramp-down or plunge rule of "Feed Rate / 2" on one sheet and "Feed Rate IPM / # of flutes" on another. The two conflict, and I did not verify which sheet says which (search snippet). — [Amana Spektra spiral plunge v40 (PDF)](https://www.amanatool.com/pub/media/productattachments/Solid-Carbide-Spektra-Spiral-Plunge-2-3-Flute-v40.pdf); [Amana spiral plunge feed/speed (PDF)](https://es.global.toolstoday.com/content/ProductFile/Attachments/Feed-Speed-for-Amana-Tool-Solid-Carbide-Spiral-Plunge-2-3-Flute.pdf)

**Upcut, downcut and compression bits**
- Downcut forces chips down and packs them in. On deep profiles they get recut, adding heat and wear.
- Upcut gives the best evacuation, allowing higher feed and less heat, but frays the top face.
- Compression: "the first pass must go below the upcut section," otherwise it cuts like an upcut. It is designed for a single pass; multiple passes are fine if the first is below the upcut section. Ramp-in and lead-in help life and edges. It is not ideal for shallow pockets.
- Source: [ToolsToday (Amana) Learning Desk](https://toolstoday.com/learn/downcut-upcut-and-compression-bits)
- Retailer and forum detail: the upcut portion is typically the first bit diameter of cutting length. Mortise compression bits have a shorter upcut section, so they can take a shallower first pass. The first pass should be slightly deeper than the upcut section (search snippet). — [BitsBits, what is a compression bit](https://bitsbits.com/?p=8515); [TalkShopBot compression bits thread](https://talkshopbot.com/forum/archive/index.php/t-7003.html)

### Inferences
**Ramp feed law (derived).** A Vectric-style "ramp at plunge rate" with a 3° ramp moves Z at only `F_plunge*sin(3°) ≈ 5%` of the plunge rate, while XY crawls at the plunge rate. That is a classic burn and dwell condition in wood. Better:

`F_ramp = min(F_cut * k_entry, F_plunge_max_Z / sin(alpha))`

where `k_entry` is about 0.5–0.8. Because the ramp is a full-width slot, `k_entry` should match the slot rule, not the chip-thinned rule.

**Helix geometry (derived, exact).**
- `pitch = pi * d_c * tan(alpha)`, with `d_c` the centre-path diameter. The forum's `sin` form is a small-angle approximation.
- Default helix: `d_c ≈ 0.5–0.95·D_tool`. Never larger than `(pocket inscribed diameter − D_tool − stock_to_leave)`.
- Below about `0.25·D` (Fusion's floor) fall back to zigzag ramp, then to plunge if the tool is center-cutting. Otherwise refuse with an error (FeatureCAM's fallback chain).
- Apply edge-feed compensation on the helix: `F_centre = F_edge*(d_c)/(d_c + D_tool)`, the CNCCookbook formula rewritten with hole = `d_c + D_tool`.

**Tool-library fields NativeCAM needs:**
- `centerCutting` (Bool)
- `maxRampAngle` (default about 3° when unknown)
- `upcutLength` for compression bits (default 1·D)
- `helixAngle` and type: upcut, downcut, compression, straight or carbide-tipped
- `maxPlungeFeed`

**Validation rules:**
- Compression bit: first pass depth ≥ `upcutLength` + small margin (for example 0.5 mm). Otherwise warn of top-face chipping.
- Carbide-tipped or non-center-cutting tool: forbid straight plunge, force ramp or helix.
- Downcut tool at depth > about 1·D in a slot: warn about chip packing and heat, and suggest upcut or more passes.

**Compression bit plus ramp.** The start of a ramp is shallower than the upcut section, so it can fuzz the top face locally. Prefer to ramp on a lead-in in waste, or in the scrap side of the kerf, or go to full depth on the first pass. This is my inference, not a manufacturer statement.

**Wood ramp angles.** The 2–5° range the user mentioned is plausible for router spiral bits, which are generally center-cutting. The sources I found that I could verify, though, are metal-oriented (0.5–3°). Default to 2–3° with a per-tool override.

### Gaps
- I found no Onsrud, Whiteside, Vortex or Freud document giving a recommended ramp angle or helix diameter for wood. The Carveco ramping page that reportedly suggests 1–5° returned 404.
- I found no authoritative plunge-rate ratio for router bits in wood; Amana's two sheets conflict.
- I found no manufacturer upcut-length specs for specific compression bits.

---

## 4. Depth-of-cut strategy, tabs, onion skin, finish allowance and avoiding burning

### Takeaway
For sheet goods the standard approach is:
- Cut parts out at about 1xD per pass, derating chip load at 2D and 3D.
- With a compression bit, use one pass or a first pass below the upcut section.
- Leave a thin onion skin (about 0.03–0.05") or tabs for hold-down, then a final skin pass.
- Use a small last-pass finish allowance, well under 1/3·D.

Burning comes from low chip load (thin chips), dwell, recut chips (downcut in deep slots) and dull bits. Keep `n*z*fz` above the chart minimum and lower RPM rather than feed when the machine is feed-limited.

### Cited Findings
**Vectric 2D Profile passes and tabs** — [Vectric 2D Profile docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/uiProfileMachineForm/index.html)
- Pass depth may vary "by up to 15% in either direction" to reduce the pass count unless "Maintain Exact Step Depth" is set.
- With a separate last pass, "all but the last pass will be undercut by the specified allowance." Vectric warns if the allowance exceeds one-third of tool diameter and advises keeping it much smaller. "Reverse direction" on the last pass reduces witness marks.
- 3D tabs are triangular: the tool ramps up and down without stopping and runs faster and smoother. 2D tabs stop, lift, cross and plunge.
- "Tab thickness is measured from the bottom of the CUT DEPTH, not the Material bottom."

**Production onion skin (WoodWeb thread)** — [WoodWeb: Tabbing versus onion-skinning for small parts](https://woodweb.com/knowledge_base/Tabbing_Versus_OnionSkinning_for_Small_Parts.html)
- One shop cuts all parts to 0.70" in 0.75" sheet, then runs a full path for the remaining 0.05", cutting small parts first while vacuum is strongest.
- Tabs can be "much stronger" than onion skin. Make them thin enough to cut with a knife; 1/4" tabs only if they are sanded off quickly.
- Another shop runs a 1/2" compression first pass at 0.70" and a 3/8" second pass at 0.75", both at 1,700 IPM, on a 5x12 industrial table with a 40 hp vacuum pump. That is an industrial machine and not comparable to an Avid.
- For small parts: a sharp 1/4" downshear bit, 0.5–0.75" of material frame between parts, and two passes in the same location.

**Other onion-skin values (search snippet, WoodWeb threads)**
- 0.03" skin with the final cutout feed reduced 50%.
- 0.008" skin on small parts.
- 1 mm skin.
- "1/16 or less" skin in chipboard, or 1/8" left for a thicker final cut.
- Sources: [WoodWeb: CNC routing chipboard with two passes](https://woodweb.com/knowledge_base/CNC_Routing_Chipboard_with_Two_Passes.html); [WoodWeb: Problems holding down thin sheet stock](https://woodweb.com/knowledge_base/Problems_Holding_Down_Thin_Sheet_Stock.html)

**Depth derate**
- 2xD: chip load −25%. 3xD: −50%. — [Freud guide](https://www.freudtools.com/public/assets/freud/downloadables/freudtools-router-bit-feed-and-speed-for-cnc-20170822.pdf); [Onsrud via Artisan's Asylum](https://wiki.artisansasylum.com/wiki/ShopBot_Feeds_and_Speeds_and_Chip_Load)
- Freud also recommends starting with shallow test passes at the lower end of the chip-load range. — [Freud guide](https://www.freudtools.com/public/assets/freud/downloadables/freudtools-router-bit-feed-and-speed-for-cnc-20170822.pdf)

**Causes of burning**
- Thin chips do not carry away heat. — [Freud guide](https://www.freudtools.com/public/assets/freud/downloadables/freudtools-router-bit-feed-and-speed-for-cnc-20170822.pdf)
- Downcut chips get recut in deep profiles, adding heat. — [ToolsToday](https://toolstoday.com/learn/downcut-upcut-and-compression-bits)
- In the WoodWeb thread, a dull 3/8" downshear contributed to part movement and poor bottom quality. — [WoodWeb](https://woodweb.com/knowledge_base/Tabbing_Versus_OnionSkinning_for_Small_Parts.html)

**Adaptive clearing in wood**
- Fusion's Optimal Load caps side engagement while running at full-flute depth. Forum users with desktop routers report about 1 mm Optimal Load in hardwood, or 0.040" Optimal Load at 0.75" depth in pine (search snippet). — [Autodesk Adaptive reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUIDA73542E9-ED9C-4BD9-A87D-3A0ECA8BEB41.htm); [Carbide 3D forum](https://community.carbide3d.com/t/recipes-for-adaptive-clearing-in-hardwood-201-endmill/40760)

### Inferences
**Two clearing modes worth offering:**
- *Layered full-width.* A slot or offset pocket with depth per pass of about 0.5–1·D and fixed stepover of 40–50%. It is simple and good for sheet cut-outs.
- *Full-depth light stepover.* An adaptive or trochoidal path at 1–3·D depth with `ae` of 5–15%·D. It uses the whole flute, spreads wear and gives open space for chips to escape.

Mode B depends on the chip-thinning boost (section 1) to keep the chip thick enough not to burn. With the Avid feed cap (section 6) the boost may be clipped, so the RPM must come down (section 6). Without engagement control, an offset pocket has to fall back to mode A.

**Sheet cut-out defaults:**
- Passes: about 1·D per pass; compression bits ≥ `upcutLength` on pass 1.
- Onion skin: default 0.03" (0.8 mm), user-adjustable.
- Skin pass: same XY path, full feed or reduced (one WoodWeb shop used 50%). Optionally use a smaller tool for small parts.
- Tabs: prefer 3D (ramped) over 2D (Vectric's reasoning, which also avoids dwell).
- Final-pass allowance: 0.25–0.5 mm, kept well under D/3. Optionally reverse direction on the finish pass.

**Burn avoidance in the scheduler:**
- Enforce the `F_floor` from section 2.
- Never emit a dwell (G4) in material.
- Avoid stopping at tab boundaries; use 3D tabs.
- Ensure every slowdown also lowers the planned RPM, or warn, so the chip stays above the floor.
- Flag downcut tools in deep slots.

### Gaps
- I found no controlled study of wood burning thresholds (minimum chip load against temperature) for router bits; the guidance is manufacturer rule-of-thumb.
- I found no source quantifying the cycle-time benefit of adaptive versus layered clearing in wood on a gantry router.

---

## 5. Corner handling: inside-corner engagement spikes, arc feed compensation, minimum feeds

### Takeaway
Engagement spikes at inside corners whenever the tool radius is at or near the corner radius. Helical's guidance is to reduce feed 30–50%, or to use a tool smaller than the corner with a sweeping path. G-code feed applies at the tool centre, so on small arcs the cutting edge speed differs. Compensate with `F_centre = F_edge*(D_hole − d)/D_hole` for concave arcs and `F_edge*(D_work + d)/D_work` for convex arcs. On a router the bigger practical risk is that slowing in tight corners, whether by CAM or by the controller's acceleration limits, drops chip load and burns, so a minimum-feed floor is needed.

### Cited Findings
**Helical Solutions: corner engagement (catalog p.103)** — [Helical Solutions, "Corner Engagement" (PDF)](https://cdn.shopify.com/s/files/1/0612/0733/files/Milling-_Corner_Engagement.pdf)
- In an "inside corner" condition the engagement angle "significantly increases." The evidence is chatter, deflection (wall taper), squawking, and breakage or chipping.
- If the part's inside radius equals the tool radius at a 90° direction change, the extra corner material and higher engagement give the "least desirable" condition.
- Even with a sweeping direction change, "the final pass the tool will experience a very high engagement angle." The action is "feed rate may need to be reduced by 30–50% depending on the tool radius-to-part radius ratio."
- Most desirable: a tool smaller than the corner, with a sweeping action.

**Corner sizing rules from other sources (all search snippet)**
- Sandvik suggests a corner radius of about 50% of cutter diameter, programming a radius to reduce arc of engagement. **[metal]** — [Sandvik Coromant, milling inside corners](https://www.sandvik.coromant.com/en-us/knowledge/milling/milling-inside-corners)
- Autodesk suggests a tool radius of about 80% of the minimum concave radius. — [Autodesk blog, machining internal corners](https://www.autodesk.com/products/fusion-360/blog/fusion-360-machine-internal-corners/)
- Vendor blogs give corner radius at 1.5x tool radius, or 10–15% larger than tool radius. These figures conflict. — [Yijin Solution](https://yijinsolution.com/cnc-guides/sharp-inside-corners-cnc-machining/); [Anebon](https://anebonmetal.com/?p=9446)

**Chip thinning and corners**
- Chip thinning compensation "needs to be considerate of drastic tool engagement, angle increases in these areas still apply." — [Helical (PDF p.102)](https://cdn.shopify.com/s/files/1/0961/5830/files/Milling-_Angle_of_Engagement_and_Chip_Thinning.pdf)
- Basic radial chip thinning overloads tools in corners and curves (search snippet). — [CimQuest](https://cimquest-inc.com/?p=7630)

**Arc feed compensation**
- Internal: centreline feed `F2 = F1 x (D − d1)/D`, with `F1` the cutting-edge feed, `D` the workpiece ID and `d1` the cutter diameter (Kennametal, search snippet). — [Kennametal interpolation tech info (PDF)](https://www1.mscdirect.com/images/solutions/kennametal/millingTechInfoInterpolation.pdf)
- CNCCookbook gives the same internal formula. — [CNCCookbook](https://www.cnccookbook.com/helical-interpolation-ramp-angle-calculator-best-ways-to-enter-a-cut)
- Sandvik notes that for external circular milling the tool-centre feed is increased instead of reduced (search snippet). — [Sandvik ramping page](https://www.sandvik.coromant.com/en-gb/knowledge/milling/milling-holes-cavities-pockets/ramping)
- A Fusion idea-station request for "variable feed optimization based on outside/inside arc velocity" suggests Fusion lacks this compensation in general (search snippet). — [Autodesk forum idea](https://forums.autodesk.com/t5/fusion-360-ideastation-archived/variable-feed-optimization-based-on-outside-inside-arc-velocity/idi-p/6771930)

### Inferences
**Derived corner-engagement formulas for NativeCAM's analytic fallback when no stock model exists.**

*Straight cut:* `phi_s = arccos(1 - ae/r)`.

*Sharp toolpath corner* (part corner radius ≤ tool radius, so the tool-centre path has a vertex), turning angle θ, stepover `s` from the previous offset pass:
- Peak engagement on arrival at the vertex: `phi_peak ≈ phi_s + θ`, capped at 180°.
- I derived this by tracing the uncut region of a 90° offset-pocket corner: the uncut arc runs from `−phi_s` to `90° + phi_s`, and the leading half sees `90° + phi_s`.
- Example, 90° corner: s = 10%·D gives `phi_s` = 36.9° and peak about 127°. s = 40%·D gives about 168.5°, nearly a slot.
- So a chip-thinned feed of 1.67x from a 10% stepover becomes a full chip at 1.67x nominal in the corner, an overload of 67% plus more than 3x arc length. This matches Helical's 30–50% reduction advice and is why boosted feeds must drop at corners.

*Concave arc* (tool inside), tool-centre radius ρ, wall radius `Rw = ρ + r`, previous-pass boundary `R0 = Rw − ae`:
- `phi = arccos((R0² − ρ² − r²) / (2ρr))`.
- *Convex arc* (tool outside), `ρ = Rw + r`, `R0 = Rw + ae`: `phi = arccos((ρ² + r² − R0²) / (2ρr))`.
- Both reduce to `arccos(1 − ae/r)` as ρ → ∞, which I checked.
- Concave arcs raise engagement and convex arcs lower it.

**Arc feed compensation (Mach4 feeds the programmed tool-centre path).**
- Concave: `F_centre = F_edge * ρ/(ρ + r)`.
- Convex: `F_centre = F_edge * ρ/(ρ − r)` with `ρ − r = Rw`. Cap the convex boost at about 1.5x and at the machine maximum.
- Apply these only on finishing contours where edge chip load matters. In roughing, the engagement-based law already accounts for this if engagement is measured at the edge.

**Minimum feed.**
- Clamp the result at `F_floor = max(n*z*h_min, k_min*F_ref)`, with `k_min` about 0.3–0.5. Fusion's "Reduced Feedrate" is a single user-set value.
- When the floor binds, warn the user to change the geometry: add a fillet ≥ 1.1–1.25·r, or use a smaller tool or rest machining, as Helical, Fusion and Sandvik recommend.

**Controller physics.**
- Centripetal acceleration on a tight arc is `a = v²/ρ`. At 400 IPM (169 mm/s) on ρ = 3 mm, `a` ≈ 9.5 m/s² (about 1 g). A gantry router very likely cannot reach that, so the controller will slow down regardless.
- NativeCAM should predict this: `v_max_arc = sqrt(a_max*ρ)` with user-set `a_max`. Then schedule a matching RPM reduction or warn, rather than let the controller silently drop the chip load and burn the corner.
- Corner rounding, meaning a small fillet in the tool-centre path at sharp vertices, also helps the controller keep speed.

### Gaps
- I could not find Helical's "excel calculators" for the radius-ratio corner feed reduction, so 30–50% is the only number available.
- I found no wood-specific corner studies; all corner-engagement sources are metal-oriented, though the geometry transfers.
- I found no published Avid PRO acceleration values; see section 6.

---

## 6. Open-source calculators and code (licenses), and what matters on Avid PRO machines

### Takeaway
Several permissive (MIT) projects exist: Kiri:Moto/grid-apps and the Better Tool Library feeds calculator. The engagement-aware open-source code that matters most, FreeCAD CAM Adaptive, is **LGPL-2.1+**, as are the FreeCAD FeedsAndSpeeds add-on and OpenCAMLib. Those should be studied and re-derived, not copied. FSWizard is a closed, proprietary app. On Avid PROs the binding limit is usually the drive system's cut-speed cap (250, 400 or 600 IPM for NEMA 23, NEMA 34 and ClearPath). Chart chip loads at 18k RPM call for more than that on 3/8"–1/2" tools, so RPM, not feed, should be the variable that keeps the chip above the burn floor.

### Cited Findings
**Open-source code and calculators**

| Project | What it is | License |
|---|---|---|
| FreeCAD FeedsAndSpeeds add-on (dubstar-04) | "FreeCAD Feed and Speeds Calculator" | **LGPL-2.1 (FLAG)** |
| FreeCAD CAM Adaptive (libarea Adaptive.hpp/.cpp, Kresimir Tusek) | Engagement-controlled clearing, built on Clipper | **LGPL-2.1-or-later (FLAG)** |
| OpenCAMLib (aewallin) | "open source computer aided manufacturing algorithms library" | **LGPL-2.1 (FLAG)** |
| Better Tool Library (knipknap) | FreeCAD tool-library add-on and CLI; reportedly includes a feeds & speeds calculator | MIT |
| GridSpace grid-apps (Kiri:Moto) | Browser-based slicer, CAM and laser | MIT |
| FSWizard (Zero_Divide) | Proprietary iOS/Android calculator, a pared-down version of the Windows HSMAdvisor app; free and PRO tiers | Proprietary, no code |

Sources:
- FeedsAndSpeeds: [GitHub: dubstar-04/FeedsAndSpeeds](https://github.com/dubstar-04/FeedsAndSpeeds), license per the GitHub API; the FreeCAD add-on list shows LGPL-2.1-or-later ([FreeCAD addons](https://www.freecad.org/addons.php?lang=en)).
- CAM Adaptive: [Adaptive.hpp mirror](https://huggingface.co/AbdulElahGwaith/FreeCAD/blob/main/src/Mod/CAM/libarea/Adaptive.hpp); [FreeCAD wiki](https://wiki.freecad.org/CAM_Adaptive)
- OpenCAMLib: [GitHub: aewallin/opencamlib](https://github.com/aewallin/opencamlib) (GitHub API)
- Better Tool Library: [GitHub: knipknap/better-tool-library](https://github.com/knipknap/better-tool-library) (GitHub API); [libraries.io btl](https://libraries.io/pypi/btl/0.9.9)
- Kiri:Moto: [GitHub: GridSpace/grid-apps](https://github.com/GridSpace/grid-apps) (GitHub API)
- FSWizard: [engineering.com first look](https://www.engineering.com/?p=13359); [App Store FSWizard Lite](https://apps.apple.com/us/app/fswizard-lite/id741521897)

**Avid PRO machines**
- Avid PRO4848 specs by drive:
  - NEMA 23 stepper: cut 250 IPM, rapid 500 IPM.
  - NEMA 34 stepper: cut 400 IPM, rapid 800 IPM.
  - ClearPath servo: cut 600 IPM, rapid 1,200 IPM.
  - Repeatability ±0.002", accuracy ±0.005".
  - Heavy aluminum extrusion and steel plate gantry, profile linear rails, ballscrew Z, PRO rack and pinion.
  - Spindle options: 4 HP Hiteco, 8.7 HP Hiteco, AV40S 4 HP, AV70S 7 HP. The 4 HP Hiteco is said to give "a consistent 4 HP of cutting power across a wide RPM range."
  - No acceleration values are published.
  - Source: [Avid CNC PRO4848 product page](https://www.avidcnc.com/pro4848-4-x-4-cnc-router-machine-p-1335.html)
- A forum post relays Avid support's maximum feeds as 200 for a Benchtop Pro with NEMA 23 and 250 for a PRO4824 with NEMA 23. The post writes "ips," probably meaning IPM (search snippet). — [Avid CNC forum: Maximum Feed Rates](https://forum.avidcnc.com/t/maximum-feed-rates/5983)
- Avid support calls the supplied CAD/CAM values "a good starting point" that may need adjusting (search snippet). — [Avid CNC support, CAD/CAM](https://www.avidcnc.com/support/troubleshooting/benchtopPro/cadCam/)

### Inferences
**The feed cap dominates on Avid (derived from Freud chart and Avid specs).**
- A 1/2" 2-flute bit in MDF at Freud's 0.023–0.027" and 18,000 RPM wants 828–972 IPM. A 3/8" in plywood (0.015–0.018") wants 540–648 IPM. Both are at or above even the ClearPath 600 IPM cut cap, and well above 400 (NEMA 34) or 250 (NEMA 23).
- So NativeCAM should compute `RPM = clamp(F_cap / (z * h_target), RPM_min, RPM_max)`, with `RPM_min` of about 6,000 and `RPM_max` of 24,000 per the user's spindle. For example, 400 IPM / (2 x 0.020") = 10,000 RPM.
- Keep RPM per operation; VFD speed changes take time, so don't vary it per move. Then let feed vary within `[F_floor, F_cap]`.
- Consequence: chip-thinning boosts mostly get clipped by `F_cap` on stepper machines. The main value of engagement scheduling on Avid is therefore:
  1. Slowing where engagement spikes (corners, first slot), which protects bits.
  2. Letting the user run a lower RPM so that light-engagement passes still reach `F_cap` without burning.
  3. Allowing full-depth light-stepover strategies that would burn at fixed feed and RPM.
- **Spindle power at low RPM.** Hiteco claims constant power over a wide range. Typical Chinese air- or water-cooled VFD spindles, likely what the user has at 2.2–4 kW, are generally constant-torque below rated speed, so power drops in proportion to RPM. I did not confirm this with a source. NativeCAM should take `P(RPM)` from the user, with `P_rated*RPM/RPM_rated` below rated speed as the default, and check `MRR * k_c ≤ P(RPM)` once a wood specific-energy value is chosen.
- **What to borrow.** MIT code (grid-apps, BTL) can be copied with attribution. For engagement-controlled clearing, read the FreeCAD Adaptive design (constant cut area, iterative angle search, 5% area tolerance) and re-implement it independently on Clipper2. Do not copy LGPL code into a statically linked Swift app.

### Gaps
- I did not fetch Avid PRO6060 (5x5, the user's machine) specs. I assume the same drive-system cut and rapid table as the PRO4848, which should be verified on the PRO6060 page.
- Avid publishes no acceleration or jerk values, gantry stiffness or deflection data, or feeds and speeds tables of its own, as far as I could find.
- I found no evidence that Kiri:Moto implements engagement-based feed scheduling. I did not inspect its source.
- I did not open the LICENSE files directly for FreeCAD core or libarea; the license comes from the file header mirror and the FreeCAD add-on listing.
- I did not find a "fswizard" open-source project; FSWizard appears to be only the proprietary Zero_Divide app.
- I did not verify whether Mach4 runs in constant-velocity (G64) mode by default or how it blends short segments, which affects corner slowdowns.
