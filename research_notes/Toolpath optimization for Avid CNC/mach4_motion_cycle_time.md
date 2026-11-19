# Mach4 + Ethernet SmoothStepper motion execution, CAM output shaping, and acceleration-aware cycle-time estimation (Avid CNC PRO)

Scope: Mach4 driving an Ethernet SmoothStepper (ESS) on Avid CNC PRO routers, with the user's PRO6060 (5x5) as the reference machine. Items that apply only to Mach3 or to other controllers (Grbl, Klipper, LinuxCNC) are marked. Worked numbers use Avid's reported default X/Y acceleration of 50 in/s² (1270 mm/s²) unless stated otherwise.

## Q1. How do Mach4's trajectory planner and the ESS execute motion (G61/G64, G64 P, look-ahead, CV settings, ESS interaction, Avid defaults, tiny segments vs arcs, limits)?

### Takeaway
Mach4 does all the planning and corner blending. The ESS just buffers a time-sliced velocity stream (1024 slices/s, about 0.18 s FIFO) and turns it into step pulses. Mach4's G64 takes no P tolerance. Cornering is controlled by a 180-entry "CV feedrate per angle" table (filled by the mcCvTuning wizard from a tolerance plus motor acceleration) and by motor acceleration. CV is broken by G0, G31, G4, S, T, most macros, repeated (zero-length) positions, and moves shorter than one ESS time slice. NativeCAM's output should therefore have no duplicate points, no sub-slice moves, no mid-path S words, and tangent-continuous geometry wherever it can.

### Cited Findings
**Planner split between Mach4 and the ESS**
- Mach4 interprets the G-code and does the CV blending. The ESS takes axis commands and turns them into motor pulses. — [Warp9: Setting up the SmoothStepper and Mach4](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4)
- The ESS works in time slices: "The Smooth Stepper has 1024 time slices per second or about 1 ms per time slice." — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4)
- ESS buffer: "Buffer Size (Almost always left at 0.18)". The Warp9 FAQ says "The default buffer depth is 0.18 seconds for the velocity FIFO buffer", so motion runs about 0.18 s behind the planner. A capable PC might run 0.02–0.08 s. A smaller buffer makes feed hold and FRO respond faster but risks starving the FIFO. — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4); [Warp9 FAQ Mach4](https://warp9td.com/index.php/faq/faq-mach4)
- ESS plugin frequency: 40 Hz is recommended. Homing failures were seen at 200 Hz. Elsewhere the FAQ suggests 80–100 Hz on a capable PC, and says the ESS reports status every 25 ms at default. — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4); [Warp9 FAQ Mach4](https://warp9td.com/index.php/faq/faq-mach4)
- The ESS has no lookahead setting of its own in Warp9's setup guide. The only lookahead it documents is Mach4's "lines of look ahead". — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4)

**G61 / G64 / G09 semantics (official Mach4 Mill manual)**
- G61 (Exact Stop Mode): "the machine will decelerate to a complete stop at the end of each commanded move". The manual warns it gives "jerky motion and witness marks" on complex code and arcs, and says "For most milling jobs use G64." — [Mach4 Mill G-code Manual (Newfangled/machsupport)](https://www.machsupport.com/wp-content/uploads/2014/05/Mach4%20Mill%20GCode%20Manual.pdf)
- G64 (Constant Velocity Mode): "Mach will try to maintain feedrate even around sharp corners… sharp corners will be slightly rounded and the machine may never reach the programmed point before a direction change. The magnitude of these position errors will be determined by the acceleration capability of the machine and the programmed feedrate." The manual defines no tolerance word. — [Mach4 Mill G-code Manual](https://www.machsupport.com/wp-content/uploads/2014/05/Mach4%20Mill%20GCode%20Manual.pdf)
- G09 is a non-modal exact stop. The axes decelerate to the end point and the position is checked before the next block. — [Mach4 Mill G-code Manual](https://www.machsupport.com/wp-content/uploads/2014/05/Mach4%20Mill%20GCode%20Manual.pdf)
- G64 has no P (or Q) in Mach4. A frequent Mach4 forum answerer (Chaoticone) said: "There are no P or Q parameters for G64 in Mach so be sure to clean those up in your Gcode." Users noted that P/Q works in LinuxCNC but not Mach4. — [Machsupport: Mach4 – Constant Velocity & Exact Stop](https://www.machsupport.com/forum/index.php?topic=35121.0)
- On an Avid machine, a forum user (jjneeb) found that setting Exact Stop in Mach4's Defaults tab had no effect. Only a G61 in the G-code file changed the behaviour. — [Avid forum: Mach4 CV Tuning Wizard](https://forum.avidcnc.com/t/mach4-cv-tuning-wizard/3205)

**Mach4 CV configuration: the CV feedrate table and wizards**
- Mach4 has no Mach3-style "CV Dist Tolerance" or "Stop CV on angles". A user moving from Mach3 could not find them and was pointed to the mcCvTuningWizard. — [Machsupport topic 35121](https://www.machsupport.com/forum/index.php?topic=35121.0)
- Instead, Mach4 stores a maximum feed for every direction-change angle from 0° to 179° (0 ≈ straight, 179 ≈ reversal). Setting angles above 90° to 0 emulates "Stop CV on angle". The newer wizard "is smart enough to set the feed rate for angles to maintain a tolerance you enter in the wizard." — [Machsupport: Stop CV on Angles?](https://www.machsupport.com/forum/index.php?topic=35872.0)
- The current mcCvTuning wizard builds the table from the axes you pick, your tolerance, and the motor-tuning acceleration. Warp9 says: "If you ever change your motor tuning, you should rerun the CV (Constant Velocity) tuning wizard." It also says "The lower your motor acceleration, the poorer the CV results will be." — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4); [Avid forum CV wizard thread](https://forum.avidcnc.com/t/mach4-cv-tuning-wizard/3205)
- The table values are maximums. An older two-slider wizard sets only a max feed and a stop angle (e.g. 300 and 179). — [Avid forum CV wizard thread](https://forum.avidcnc.com/t/mach4-cv-tuning-wizard/3205); [Machsupport: Mach4 and Constant velocity](https://www.machsupport.com/forum/index.php?topic=38272.0)
- One user reports that CV setting changes only take effect after closing and reopening Mach4. — [Search summary of machsupport CV threads](https://www.machsupport.com/forum/index.php?topic=35121.0) *(stated in search results; not confirmed in the fetched page text)*

**Look-ahead**
- Warp9: "In Mach4 if you leave your lines of look ahead set to 20, it will not interfere with CV". Setting it lower "may start to impact CV performance." — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4)
- The Warp9 FAQ also calls Mach4's look-ahead "the next 20 lines (lookahead buffer)", in the context of a probe-freeze bug. — [Warp9 FAQ Mach4](https://warp9td.com/index.php/faq/faq-mach4)
- Practitioner values vary. A plasma-forum post suggests about 200 lines to keep a motion controller's buffer full. An older Mach (Mach3-era) answer says "if its hundreds of very small segments, then 50 would be good, if its only moves greater than the acceleration distance, then 2 is fine." — [PlasmaSpider: Another Constant Velocity Question](https://plasmaspider.com/viewtopic.php?p=189926); [Machsupport old thread (search summary)](https://www.machsupport.com/forum/index.php?topic=60.0)

**What breaks CV (Mach4 + ESS)**
- "G00 … is always in exact stop mode, so it will always break the constant velocity chain of motion." Likewise G31 (probe), "A G04 pause will break (stop) CV", "S (spindle Speed change) commands will break CV", "T (tool change) commands will break CV", and "All other macros WILL break CV". Only "M62, M63, M64, M65 and M67 will NOT break CV." — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4)
- Repeated positions: "Those repeated positions will kill the CV chain and either result in a slowdown, stall or a stop of motion." — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4)
- Sub-slice moves: "if the commanded moves are smaller than the time slice (… 1024 time slices per second or about 1 ms per time slice) … that will also prevent the commanded moves from chaining together with the desired constant velocity." — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4)
- Small moves need high acceleration: "your smaller moves will require a faster acceleration rate". Warp9 ties this to jerky motion and stalls and recommends acceleration "about 10% lower than where you start getting stalls." — [Warp9 FAQ Mach4](https://warp9td.com/index.php/faq/faq-mach4)
- "No, never set your feed rate override (FRO) above 100%". Mach4 will try to go faster than the G-code feed rate. — [Warp9 FAQ Mach4](https://warp9td.com/index.php/faq/faq-mach4)
- *(Mach3 only)* One report says CV only works at FRO = 100% and otherwise behaves like exact stop. This came from a Mach3 setup and is not confirmed for Mach4. — [Search summary, CNCzone/Machsupport](https://www.machsupport.com/forum/index.php?topic=9438.0)

**Practitioner reports on smoothness (Avid forum)**
- An oval from VCarve made of many short segments ran rough on an Avid machine. Neither CV wizard setup fixed it, and G61 looked best, "though visual and audio smoothness were not clearly better, and possibly worse" (jjneeb). jjneeb also reports that NFS changed CV behaviour in the Mach4 5000-series builds and that the on-screen toolpath trace sometimes doesn't match the actual path. — [Avid forum CV wizard thread](https://forum.avidcnc.com/t/mach4-cv-tuning-wizard/3205)
- One user had lost steps on a 3D toolpath until they set Fusion 360 tolerance to .001" with smoothing on. After running mcCvTuning, arcs slowed "almost" like exact stop. The older two-slider wizard (300 / 179) gave smoother curves. "Avid never asked users to run the CV wizards" (KDRusty). — [Avid forum CV wizard thread](https://forum.avidcnc.com/t/mach4-cv-tuning-wizard/3205)
- jjneeb "played with this a bunch" and saw little effect from the CV wizards unless acceleration was very low. — [Avid forum CV wizard thread](https://forum.avidcnc.com/t/mach4-cv-tuning-wizard/3205)
- Avid users report vibration and shaking on direction changes at the default acceleration and lower it for V-carving and fine 3D work. Details are under Q2. One user argues the roughness comes mostly from CAM ramp and lead-in feeds far below cut feed, and recommends lead-ins, ramps and helicals within about 15% of cut feed (subnoize). — [Avid forum: Mach 4 Acceleration/Deceleration](https://forum.avidcnc.com/t/mach-4-acceleration-deceleration/1123)
- *(Mach3 only)* In Mach3, a 0.1 mm CV Dist Tolerance gave stop-start motion and turned a 6–8 h job into 20 h. "large arcs made of many lines performed poorly." Mach3's author (ART) said corner error "is a function of both acceleration and feedrate", that Mach4 uses a modified planner whose internals he doesn't know, and that jerk limiting "typically adds about 15% to run time." — [Machsupport: Constant Velocity settings worked out](https://www.machsupport.com/forum/index.php?topic=33990.0)

### Inferences
- **The ESS does not re-plan.** Mach4's planner is the one that matters for estimation. The ESS adds a fixed latency of about 0.18 s but does not change the time profile. Model Mach4 (accel-limited, look-ahead-window-limited, CV-table-limited corners), not the ESS.
- **Minimum segment length.** Distance per ESS slice is F/1024 s: 0.041 mm at 100 IPM, 0.083 mm at 200 IPM, 0.165 mm at 400 IPM, 0.33 mm at 800 IPM. NativeCAM should merge, refit or drop moves shorter than about 2–3 slices at the programmed feed, so roughly L_min ≈ F·(2.5/1024 s), or about 0.2–0.4 mm at typical 200–400 IPM router feeds. Warp9 only states that sub-slice moves break CV, so the 2–3 slice margin is my judgement.
- **No duplicate points after quantization.** Two points that differ before formatting can print identically at 4 decimals (inch) or 3 decimals (mm). The poster should compare the formatted coordinates and suppress zero-length blocks, including G1 blocks that repeat only F.
- **Avoid emitting S, T, M (other than M62–65/M67) or G4 inside a toolpath.** Emit S once per tool before motion. Emit G64 explicitly in the header and after each tool change, since the Defaults-tab setting was unreliable on Avid.
- **Look-ahead caps feed on dense segments.** A planner with a finite look-ahead must be able to stop within the distance it can see. With N look-ahead lines of average length L, v_max ≤ √(2·a·N·L). With N = 20 and a = 1270 mm/s²: 0.1 mm segments cap feed near 71 mm/s (168 IPM), 0.5 mm segments near 159 mm/s (376 IPM), and 1.0 mm segments near 225 mm/s (532 IPM). This is the general behaviour of look-ahead planners (LinuxCNC/Grbl-style). That Mach4 behaves this way is my inference and needs a timing test. Either way, longer segments (arcs) and fewer of them help.
- **Arcs are better than many G1s on Mach4/ESS.** Every G2/G3 is one block of many slices with no internal "angles", so neither the CV table nor look-ahead depth limits it. A run of tiny G1s hits the per-angle table at every vertex and the look-ahead stopping-distance limit. NativeCAM's arc fitting already helps. Extending it to biarcs or larger tolerances (Q3) is the main lever.

### Gaps
- No official Newfangled Solutions documentation was found for the Mach4 planner internals: how the CV table is applied, whether arc speed is capped by centripetal acceleration, the look-ahead stopping rule, or whether F-word changes break CV.
- No published maximum block or segment rate for Mach4 + ESS was found. The only hard numbers are 1024 ESS slices per second and the 0.18 s FIFO.
- Avid's shipped values for look-ahead lines, the CV_Feedrate table, and default motion mode (G64 vs G61) were not found. Avid's own Mach4 configuration page and guides contain none of them. A forum user asked for the default CV table and got no answer. — [Avid Mach4 Configuration](https://www.avidcnc.com/support/instructions/software/mach4Configuration/); [Avid forum CV wizard thread](https://forum.avidcnc.com/t/mach4-cv-tuning-wizard/3205)
- Helical arcs: no Mach4- or ESS-specific smoothness report was found. Feed semantics are covered in Q5.

## Q2. What are the Avid CNC PRO machine dynamics (velocity, acceleration, rapids) and what does Avid's Mach4 configuration ship with?

### Takeaway
On the current PRO6060 page Avid lists rapids of 500 / 800 / 1200 IPM and cut speeds of 250 / 400 / 600 IPM for NEMA 23 / NEMA 34 / ClearPath servo. Older or other Avid pages give higher NEMA 34 figures (1000+ IPM rapids). Avid publishes no acceleration figure, but several sources agree the shipped Mach4 X/Y motor acceleration is 50 in/s² (about 1270 mm/s², 0.13 g). Users often lower it to 15–35 for V-carve or 3D finish work.

### Cited Findings
- PRO6060 router (current product page): cut speed 250 IPM (NEMA 23), 400 IPM (NEMA 34), 600 IPM (ClearPath servo). Rapids 500, 800 and 1200 IPM. Repeatability ±0.002" (0.05 mm), accuracy ±0.005". Rack-and-pinion X/Y, ballscrew Z. Work area 61-3/8" × 61-3/8" × 8" Z (12" optional). Machine weight 403–411 lb. — [Avid PRO6060 router kit](https://www.avidcnc.com/pro6060-5-x-5-cnc-router-kit-p-634.html)
- Conflicting figures exist. Search snippets of an Avid page and older RSS mirrors list NEMA 34 at "500 IPM+" cutting and 1000 IPM (or 1200 IPM+) rapids, and NEMA 23 at 250 / 500. Avid's FAQ (per search snippet) says 600 IPM+ rapids for some NEMA 23 systems and 1000 IPM+ for NEMA 34 "due to gearing". Treat the current product page (800 IPM for NEMA 34) as authoritative. — [Avid FAQ (search snippet)](https://www.avidcnc.com/support/faq/); [RSS mirror of Avid listing](https://cncrouterparts2.rssing.com/chan-10558629/all_p10.html); contradicted by [current PRO6060 page](https://www.avidcnc.com/pro6060-5-x-5-cnc-router-kit-p-634.html)
- The PRO6060 plasma machine page uses the same 250/400/600 cut and 500/800/1200 rapid table (mild steel). — [Avid PRO6060 plasma](https://www.avidcnc.com/pro6060-5-x-5-cnc-plasma-machine-p-1342.html) *(via search summary)*
- Default acceleration: the author of a Mach4 accel macro says `M4001` "resets acceleration to the Avid CNC default of 50 units/(sec²)". Users repeatedly cite 50 i/s² as the Avid default. — [Avid forum: Mach4-Motor-Accel macro](https://forum.avidcnc.com/t/mach4-motor-accel-a-macro-and-post-combo/2505); [Avid forum: Mach 4 Acceleration/Deceleration](https://forum.avidcnc.com/t/mach-4-acceleration-deceleration/1123)
- ClearPath: one user on Avid's ClearPath tuning thread says the Avid default for NEMA 34 steppers was 50 and they chose 100 for ClearPath servos. — [Avid forum: ClearPath motor tuning (search summary)](https://forum.avidcnc.com/t/clearpath-motor-tuning/1342)
- Values users actually run:
  - jjneeb: X/Y about 15 normally, 5–10 on Y for laser rastering. V-carve quality improved going from 50 to 25. With 15 he reports much less vibration and "negligible runtime difference between 15 and 25" for V-carve.
  - ebeeks: 50 → 35 fixed shaking on a 60x120 PRO. He runs a 1/8" end mill at 200 IPM.
  - subnoize: Avid's settings are "the maximum the machine is capable of", and he never changed them on six machines.
  - Sources: [Avid forum: Mach 4 Acceleration/Deceleration](https://forum.avidcnc.com/t/mach-4-acceleration-deceleration/1123); [Avid forum: accel macro thread](https://forum.avidcnc.com/t/mach4-motor-accel-a-macro-and-post-combo/2505)
- Acceleration is set only in Mach4 motor tuning (Configure > Control > Motors). It "cannot be changed with a G-code command" except through a custom M-macro. The macro author warns: "Changes to motor acceleration are not fully accounted for by the Mach4 motion planner." His macro changes motors 0, 1 and 3 (X, Y1, Y2) and leaves Z alone. — [Avid forum: Accel/Decel](https://forum.avidcnc.com/t/mach-4-acceleration-deceleration/1123); [Avid forum: accel macro](https://forum.avidcnc.com/t/mach4-motor-accel-a-macro-and-post-combo/2505)
- Mach4 motor tuning fields are Counts Per Unit, Max Velocity and Max Acceleration only. Avid's configuration page lists no jerk parameter. — [Avid Mach4 Configuration](https://www.avidcnc.com/support/instructions/software/mach4Configuration/); [Avid Mach4 Configuration Guide v2021Q4.1](https://www.avidcnc.com/cad/2021Q4/Mach4_Configuration_Guide_v2021Q4_1.pdf)
- "Jog Rate and Rapid Rate are limited to 100%, which is the maximum velocity based on motor tuning." So G0 runs at the motor-tuning max velocity scaled by the rapid-rate override. Feed hold stops "on the programmed path at the set maximum deceleration of the motors." — [Avid Mach4 Users Guide v2023Q1.1](https://www.avidcnc.com/cad/2023Q1/Mach4_Users_Guide_v2023Q1_1.pdf)
- Generic guidance (non-Avid): a Machsupport moderator (ger21) calls 400 mm/s² "very underpowered" and recommends "at least 1000-1500mm/sec/sec". — [Machsupport: Mach4 and Constant velocity](https://www.machsupport.com/forum/index.php?topic=38272.0)

### Inferences
- **Defaults for NativeCAM's PRO6060 NEMA 34 profile:**
  - X/Y acceleration 50 in/s² (1270 mm/s²).
  - Rapid / max velocity 800 IPM (338.7 mm/s), per the current spec page. Expose it as editable, since Mach4's actual max velocity comes from the user's motor tuning and older Avid material says 1000 IPM.
  - Z acceleration and velocity are unknown (see Gaps). Use a conservative placeholder, e.g. the same 50 in/s², with rapid below the X/Y value.
- **Acceleration distances at 50 in/s²** (d = v²/2a, t = v/a):
  - 100 IPM: 0.71 mm, 0.033 s
  - 200 IPM: 2.8 mm, 0.067 s
  - 400 IPM: 11.3 mm, 0.133 s
  - 800 IPM rapid: 45 mm (1.78"), 0.267 s
- **Implications for estimation:**
  - A full stop and restart costs about v/a extra versus cruising through: +0.067 s per corner at 200 IPM, +0.133 s at 400 IPM. 10,000 stops at 200 IPM add about 11 minutes.
  - A 1" rapid takes about 0.28 s versus 0.075 s naive (3.8x). A 10" rapid takes about 1.02 s versus 0.75 s naive.
  - This alone explains most of why distance ÷ feed runs short.
- **Allow per-job acceleration overrides.** Many Avid users lower acceleration to 15–35 for V-carve and 3D work, so the estimator should take the acceleration as a per-machine and per-job input rather than a hard-coded 50.

### Gaps
- No Avid-published acceleration or velocity value per axis, per model (PRO4848 / PRO4896 / PRO6060) or per drive (NEMA 23 / NEMA 34 / ClearPath) was found. Avid's configurator generates the profile and its values are not documented publicly. Exporting the user's Machine.ini, or reading Configure > Control > Motors on their machine, is the reliable way to get Counts/Unit, Max Velocity and Max Accel per motor, including Z.
- The PRO4848 and PRO4896 product pages were not checked. They likely share the PRO drivetrain specs, but this is not verified.
- Gantry mass and the rack-and-pinion reduction ratio are not published on the PRO6060 page.

## Q3. What corner smoothing and blending can CAM apply itself, and what are the accuracy trade-offs?

### Takeaway
Because Mach4's G64 has no tolerance word and the Avid CV table is untuned and unknown, the deterministic option is to do the blending in NativeCAM. Round sharp corners with tangent fillet arcs of a bounded deviation e. Refit dense polylines into arcs or biarcs within a tolerance. Merge near-collinear moves, as LinuxCNC's naive-CAM detector does. On 2.5D offset paths, fillets that cut sharp corners stay gouge-free and leave at most e of extra material.

### Cited Findings
- LinuxCNC's G64 shows the controller-side equivalent. `G64 P- Q-`: "P is the motion blending tolerance". The path stays within P of the programmed endpoint and feed is reduced to hold it. "Q is the naive CAM tolerance", which merges nearly collinear XYZ feed moves at the same feed. On XY arcs whose deviation from a straight line is below P, the arc is split into two lines that are then subject to naive CAM. *(LinuxCNC, not Mach4)* — [LinuxCNC G-code docs](https://linuxcnc.org/docs/html/gcode/g-code.html)
- LinuxCNC TP (`src/emc/tp/tp.c`, **GPL v2**) compares parabolic, tangent-segment and arc blends and picks the arc blend only if it gives the highest blend velocity. The tolerance-limited blend velocity is `tblend_vel = 2.0 * sqrt(acc_this * tc->tolerance / cos_theta)`. A backward pass sets each segment's final velocity as `vs_back = sqrt(finalvel² + 2·acc·target)`, and segment velocity is capped at `target / (cycleTime * TP_MIN_SEGMENT_CYCLES)`. — [LinuxCNC tp.c](https://raw.githubusercontent.com/LinuxCNC/linuxcnc/master/src/emc/tp/tp.c)
- Fusion 360: "The total tolerance of an operation is given by the machining tolerance plus the smoothing tolerance when the smoothing filter is enabled". Smoothing "will allow a series of lines to be converted into an arc if the lines fit within the tolerance."
  - Forum advice conflicts on the ratio. Some say smoothing must exceed the regular tolerance. Others say tolerance should be at least the smoothing tolerance, and that "arc fitting works better when the original toolpath tolerance is smaller."
  - Sources: [Autodesk Fusion Smoothing reference (search snippet)](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID5A951723-4797-4F5F-A7A3-45DCBCA2D26F.htm); [Autodesk forum: Smooth finish (Arc fitting)](https://forums.autodesk.com/t5/fusion-360-manufacture/smooth-finish-arc-fitting/td-p/5435205); [Autodesk forum: micro-segments on older CNC](https://forums.autodesk.com/t5/fusion-manufacture-forum/excessive-micro-segments-causing-jerky-motion-on-older-cnc-num/m-p/14177353/highlight/true)
- On an Avid machine, Fusion tolerance .001" with smoothing on stopped lost steps on a 3D toolpath. — [Avid forum CV wizard thread](https://forum.avidcnc.com/t/mach4-cv-tuning-wizard/3205)
- Arc and biarc fitting references:
  - **arcfinder** (Rust per Cargo.toml) finds runs of G1s that form arcs and replaces them with G2/G3. Defaults: at least 4 segments, max RMS error 0.01 mm, max bridged angle 40° (keeps 45°/90° corners sharp), max deviation of the original long lines 0.1 mm. It outputs R by default and centres with `-c`. **License not stated, so treat as all rights reserved.** — [arcfinder on GitHub](https://github.com/orjanekeberg/arcfinder)
  - **Gribov (arXiv 1604.07476)**: optimal compression of a polyline into segments and arcs within a tolerance. It starts from a least-squares arc fit, then checks the tolerance, and notes that verifying the arc stays within tolerance is the main complexity. It is a paper, so you can implement the algorithm from it. — [arXiv 1604.07476](https://arxiv.org/pdf/1604.07476)
  - **FreeCAD `BSplineCurveBiArcs.cpp`** (from HeeksCAD, reported as BSD-style) does B-spline to biarc conversion. It was seen only via a mirror, so verify the license in the FreeCAD repo. FreeCAD as a whole is LGPL. — [Hugging Face mirror of FreeCAD source](https://huggingface.co/AbdulElahGwaith/FreeCAD/blob/main/src/Mod/Part/App/BSplineCurveBiArcs.cpp)
  - **juicy-gcode** (Haskell) converts SVG Béziers to biarcs (G2/G3) with a `--tolerance` option. Its license was not checked. — [juicy-gcode on Hackage](https://hackage-origin.haskell.org/package/juicy-gcode-0.3.0.0)
- *(Mach3)* Mach3's CV Dist Tolerance is "the distance from the end of the line… to where the arc starts rounding", not a maximum path deviation. — [Machsupport topic 33990](https://www.machsupport.com/forum/index.php?topic=33990.0)

### Inferences
- **Corner fillet geometry (implementation-ready).** At a vertex where direction turns by α (0° = straight), a tangent fillet of radius r:
  - deviates from the vertex by e = r·(1/cos(α/2) − 1)
  - starts and ends t = r·tan(α/2) from the vertex
  - so for an allowed deviation e: r = e·cos(α/2)/(1 − cos(α/2))
  - For a 90° turn: r = 2.414·e and t = r. With e = 0.05 mm this gives r = 0.12 mm and needs ≥ 0.12 mm of segment on each side. Clamp t to ≤ about 0.5 × the shorter adjacent segment.
- **The fillet radius is the same circle as Grbl's junction-deviation circle**, R = δ·sinθ/2/(1−sinθ/2) with θ the interior angle (θ = 180° − α). So "CAM-side fillet of deviation e" and "controller junction deviation δ" are the same accuracy budget. A fillet you insert has an explicit, inspectable error. Mach4's internal G64 rounding does not.
- **Gouge safety on offset paths.** A sharp corner in an exact offset path, such as Clipper2 inward offsets or outward offsets at concave part corners, is where the tool touches two boundary elements. Locally, the feasible tool-centre region is the intersection of two half-planes, which is convex, so a fillet inside the turn stays in the feasible region.
  - Result: no gouge, and at most e of material left in that corner.
  - Rounding is not gouge-safe for corners where the turn's inside faces material, such as non-offset linking moves or sharp corners on tool paths that were not offset-generated. Run a collision or offset check there.
  - Outward offsets with round joins already have arcs at convex corners. Keep round joins, since they are native G2/G3 for Mach4.
- **Speed through a fillet** is limited by centripetal acceleration: v ≤ √(a·r). At a = 1270 mm/s²:
  - 90° corner, e = 0.01 / 0.05 / 0.127 mm: about 13 / 29 / 47 IPM
  - 45° corner, same e values: about 29 / 66 / 105 IPM
  - Sub-millimetre fillets do not let a 400 IPM path keep its feed through 90° corners. They mainly avoid a full stop and the resulting witness mark and lost time. A larger allowed e (e.g. 0.1–0.25 mm on roughing passes), or a deliberate trochoidal or "racetrack" corner in roughing, buys real speed.
  - Finishing passes should keep e small, or use G61/G09 at critical corners. This mirrors Fusion's approach of using smoothing on roughing but not on finishing.
- **Segment simplification and refit pipeline**, in order:
  1. Dedupe points after quantization.
  2. Ramer–Douglas–Peucker (or a naive-CAM collinear merge à la LinuxCNC Q) at tolerance ≤ 0.5 × user tolerance.
  3. Arc or biarc fit on the remainder at the leftover tolerance budget. Keep total error ≤ the user tolerance, the same budget model as Fusion's "machining + smoothing".
  4. Enforce the minimum segment length from Q1.
  - NativeCAM's existing 0.01 mm arc tolerance is tight for wood. Expose an arc and smoothing tolerance (e.g. default 0.025–0.05 mm for roughing) separately from the geometric tolerance.
  - Biarcs give G1-tangent-continuous output (no angle at joins), which is the ideal case for Mach4's per-angle CV table.
- **Splines are not an output option.** Mach4 has no documented spline or NURBS G-code (the Mill manual's G-code list has none). Splines may be used internally for smoothing, but output must be G1/G2/G3.

### Gaps
- No source was found describing Vectric (VCarve/Aspire) arc fitting or smoothing options, or what Avid's Vectric post emits.
- No source quantified Mach4's own G64 rounding deviation for a given acceleration and feed.
- The licenses of juicy-gcode and arcfinder were not confirmed.

## Q4. How should NativeCAM estimate cycle time with acceleration (velocity profiles, junction models, look-ahead algorithms, accuracy, open-source code and licenses)?

### Takeaway
Replace distance ÷ feed with a block-level planner simulation:
- trapezoidal velocity profile per block (Mach4 exposes only velocity and acceleration, no jerk)
- per-block speed caps (feed, per-axis velocity and acceleration projected onto the move direction, √(a·R) on arcs)
- junction speed caps (angle-based, like Mach4's CV table or a Grbl/Klipper-style junction deviation), forced zero at CV breakers (G0, S, T, M, G4, G61)
- a Grbl-style backward then forward pass over a finite look-ahead window, plus fixed overheads

In the literature, controller-aware estimators reach about 5–10% error versus 30–51% for path ÷ feed. Calibrate on the user's PRO6060 with timing test files.

### Cited Findings
**Accuracy of naive vs controller-aware estimation**
- Saito, Aoyama, Sano (IJAT Vol.10 No.3, 2016): commercial CAM "estimate cutting time by dividing tool path length by the programmed feed rate", and "the actual cutting time generally exceeds the estimated cutting time for curved surfaces." On two NC machines the commercial CAM estimate was off by **51%**; their control-principle model by **7%**. — [IJAT 2016, Saito et al.](https://www.fujipress.jp/ijat/au/ijate001000030429/)
- Ward, Sencer, Jones, Ozturk (arXiv 2102.02062, 2021) model interpolator dynamics with FIR filters and corner blending in nonstop linear interpolation. They compute the minimum cornering feed analytically and predict cycle time with ">90 percent accuracy", which "greatly outperform[s] CAM-based predictions." — [arXiv 2102.02062](https://arxiv.org/abs/2102.02062)
- Yamamoto, Aoyama, Sano (JAMDSM 2017): conventional CAM error about **30%**, DNN-based estimate within 5%. *(from search snippet; PDF not read)* — [JAMDSM 2017](https://www.jstage.jst.go.jp/article/jamdsm/11/4/11_2017jamdsm0049/_pdf)
- A 1999 NC program evaluator paper notes that methods ignoring toolpath geometry and tolerance "underestimate the machining cycle times considerably". Its estimator reported about 10% mean error. *(search snippet)* — [ScienceDirect 1999](https://www.sciencedirect.com/science/article/abs/pii/S0890695599000140)
- A Fusion user measured actual cycle time a little over 27% longer than the setup estimate. *(forum anecdote via search snippet)* — [Autodesk forum: Machining time estimates are junk](https://forums.autodesk.com/t5/fusion-manufacture-forum/machining-time-estimates-are-junk/td-p/7035875)

**Grbl (GPL v3 or later; `grbl/planner.c`, © Sungeun K. Jeon / Gnea Research)**
- Junction model: `sin_theta_d2 = sqrt(0.5*(1.0-junction_cos_theta))`; `max_junction_speed_sqr = max(MIN_JUNCTION_SPEED², (junction_acceleration * junction_deviation * sin_theta_d2)/(1.0 - sin_theta_d2))`. Here junction_cos_theta = −(prev_unit · unit), so a straight line gives sin=1, i.e. unlimited speed.
- Max entry speed = min(neighbouring nominal speeds, junction limit).
- The planner recalculates with a reverse pass (decelerate-to-stop from the last block, which "starts from a complete stop", `entry_speed_sqr = min(max_entry_speed_sqr, 2*acceleration*millimeters)`) and then a forward pass that "dial[s] down junction speed values".
- Source: [Grbl planner.c](https://raw.githubusercontent.com/gnea/grbl/master/grbl/planner.c)

**Klipper (GPL v3; `klippy/toolhead.py`)**
- Constant-acceleration trapezoids, look-ahead using `end_velocity^2 = start_velocity^2 + 2*accel*move_distance`, and junction speeds via "approximated centripetal acceleration". — [Klipper Kinematics doc](https://www.klipper3d.org/Kinematics.html)
- Code details:
  - `junction_deviation = scv² * (sqrt(2) - 1) / max_accel` (from `square_corner_velocity`).
  - A per-move centripetal limit `move_centripetal_v2 = delta_v2 * quarter_tan_theta_d2`, i.e. `0.5 * move_d * accel * tan(θ/2)`.
  - `max_start_v2 = min(..., move_jd_v2, pmove_jd_v2, move_centripetal_v2, pmove_centripetal_v2)`.
  - Phase times: `accel_t = accel_d / ((start_v + cruise_v)/2)`, `cruise_t = cruise_d / cruise_v`, `decel_t = decel_d/((end_v+cruise_v)/2)`.
  - `minimum_cruise_ratio` defaults to 0.5. It limits a move's top speed to what it can reach at the pseudo-acceleration `max_accel*(1-min_cruise_ratio)` (`delta_v2 = 2*move_d*pseudo_accel`).
  - Source: [Klipper toolhead.py](https://raw.githubusercontent.com/Klipper3d/klipper/master/klippy/toolhead.py)

**LinuxCNC TP (GPL v2; `src/emc/tp/tp.c`)**
- Look-ahead depth is the config value `arcBlendOptDepth`. The backward pass uses `vs_back = sqrt(finalvel² + 2·acc·target)` (S-curve variant: `findSCurveMaxStartSpeed`). The G64 P blend velocity is `2·sqrt(a·tol/cosθ)`. Velocity per segment is capped so each segment lasts ≥ `TP_MIN_SEGMENT_CYCLES` servo cycles. — [LinuxCNC tp.c](https://raw.githubusercontent.com/LinuxCNC/linuxcnc/master/src/emc/tp/tp.c)

**Ruckig (MIT, community version; C++20, Python bindings)**
- Time-optimal jerk-limited state-to-state trajectories. Local intermediate-waypoint calculation is **Pro-only** (commercial). The community version offers waypoints only through a cloud API. — [Ruckig GitHub](https://github.com/pantor/ruckig)

**Mach4-specific inputs**
- Motor tuning exposes only velocity and acceleration, with no jerk. — [Avid Mach4 Configuration](https://www.avidcnc.com/support/instructions/software/mach4Configuration/)
- G0 always exact-stops. S, T, G4 and macros break CV. Look-ahead is about 20 lines. — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4)
- *(Mach3, ART)* Jerk limiting "typically adds about 15% to run time". — [Machsupport topic 33990](https://www.machsupport.com/forum/index.php?topic=33990.0)

### Inferences
**Recommended estimator design for NativeCAM (Swift; implement from equations, not by porting GPL code):**
1. **Run on the posted blocks.** Simulate after formatting and quantization, so duplicates and the minimum segment length match what Mach4 sees.
2. **Per-block cruise cap v_c:**
   - For G1: v_c = min(F, min_i(Vmax_i/|u_i|)), where u is the unit direction.
   - For G0: v_c = min_i(Vmax_i/|u_i|) × rapid override. Mach4 rapids at the motor max velocity.
   - Path acceleration a_p = min_i(Amax_i/|u_i|). This is the standard way to project per-axis limits. Mach4's exact projection is unconfirmed.
   - For G2/G3: add v_c ≤ √(a_xy·R). Use a_xy = min(A_x, A_y) to be conservative. A helix adds a Z component.
3. **Junction cap v_j:**
   - v_j = 0 at G0 start and end, at G1↔G0 transitions, and around S/T/M (except M62–65/M67), G4, G61/G09, zero-length blocks, and blocks shorter than about one ESS slice at F.
   - Otherwise v_j = min(v_c,prev, v_c,next, f(θ)). For f(θ), use either (a) a user-importable copy of the Mach4 CV_Feedrate table (180 entries) or (b) the Grbl formula with a tunable δ, defaulting to about 0.02–0.05 mm and calibrated (see 6).
   - Add Klipper's centripetal term 0.5·L·a·tan(θ/2) for dense polylines, so tiny-segment "curves" are not over-estimated.
4. **Look-ahead window.** Run Grbl's reverse and forward passes, but only over a sliding window of N blocks (default 20, configurable), assuming v = 0 at the window end. This captures Mach4's stopping-distance limit on dense code (v ≤ √(2·a·ΣL)). If calibration shows Mach4 effectively looks further, raise N.
5. **Block times.** Use Klipper's three-phase formulas. When cruise can't be reached, the triangle peak is v_p = √((2aL + v_s² + v_e²)/2). Add the ESS FIFO latency once per program start or feed hold (about 0.18 s, negligible). Add fixed overheads: tool change with manual M6 and touch-plate probing, spindle spin-up dwell (G4 or macro), Z homing and retract macros. Make these per-machine settings measured on the PRO6060.
6. **Calibration loop.** Ship a set of timing test programs and fit δ (or the CV table), effective acceleration and look-ahead N by least squares against stopwatch or Mach4 run times. Suggested set:
   - long straight line
   - square at 3 feeds
   - circle at 5 radii (to check whether Mach4 caps arcs at √(aR))
   - zigzag with 0.1/0.5/2 mm segments (look-ahead limit)
   - 1/5/20-inch rapids (rapid acceleration)
   - a helix
7. **Expected accuracy.** Literature controller models achieve about 5–10% error (Saito 7%, Ward >90%) versus 30–51% for path ÷ feed. Trapezoid-only may run slightly short if Mach4 does any smoothing. ART's "jerk limiting adds about 15%" is a Mach3-era upper bound for jerk effects. Calibration absorbs this.
8. **Licensing.**
   - Grbl (GPL v3+), Klipper (GPL v3) and LinuxCNC TP (GPL v2) are all GPL. Do not copy code into a closed or differently licensed Swift app. The equations (junction deviation, trapezoid, reverse/forward pass) are standard and can be reimplemented independently from the published formulas.
   - Ruckig community (MIT) is safe to link, but it only adds value if NativeCAM wants jerk-limited S-curve modelling. Mach4 has no jerk parameter, so it is not needed for v1.

### Gaps
- No independent measurement of Mach4 + ESS cycle time versus a planner model was found, so error figures for this controller are unknown until calibrated.
- Open-source "G-code time estimator" projects (e.g. klipper_estimator, slicer estimators) were not researched. Their licenses are unknown here.
- How Mach4 projects per-axis limits onto a multi-axis move, and whether it caps arc speed by centripetal acceleration, is undocumented. The calibration tests in step 6 are designed to reveal both.
- The "0.22%–54.99% CAM error" range that appeared in a search summary could not be traced to a source and is excluded.

## Q5. What arc and word formats are safest on Mach4, and which Mach4 behaviours commonly bite CAM authors?

### Takeaway
Use I/J (centre format), not R. Always state the arc-centre mode explicitly (G91.1 incremental), because Mach4 lets the profile's General tab override it. Keep arcs under 360° (NativeCAM's under-180° split is safe and conservative). Emit helices as G2/G3 with a Z word. Emit a full modal safe-start line, including G64, after every tool change. Avoid duplicate points, sub-slice moves, mid-path S words and FRO above 100%.

### Cited Findings
- Mach4: "A more accurate and reliable way to define an arc is by specifying the center point" (I/J/K) rather than R. R > 0 gives a sweep under 180°; R < 0 gives a sweep over 180°. — [Mach4 Mill G-code Manual](https://www.machsupport.com/wp-content/uploads/2014/05/Mach4%20Mill%20GCode%20Manual.pdf)
- Mach4 arc-centre mode: "Mach has two settings for how I, J, and K should be specified, absolute and incremental. This setting can be changed by G code, G90.1 and G91.1, or in the general tab in the Mach configuration. This setting is independent of the G90/G91 setting." In incremental mode I/J/K are the offset from start to centre. In absolute mode they are the centre's position in the user coordinate system. — [Mach4 Mill G-code Manual](https://www.machsupport.com/wp-content/uploads/2014/05/Mach4%20Mill%20GCode%20Manual.pdf)
- Helix: "Adding in the third point will create a helical interpolation." Format `G17 G02/03 X Y Z I J F`, e.g. `G2 X-.5 Y0.0 Z-1.0 I0.0 J-.5 F10.0`. — [Mach4 Mill G-code Manual](https://www.machsupport.com/wp-content/uploads/2014/05/Mach4%20Mill%20GCode%20Manual.pdf)
- Helical feed basis:
  - *(Mach3)* "In the case of helical motion, the rate is applied along the helix", with a warning that "other interpretations are used on other systems."
  - *(Fanuc, vendor blog)* The default applies feed along the projected XY circle.
  - Mach4 is unconfirmed.
  - Sources: [Mach3 G-code Language Reference (MachMotion)](https://machmotion.com/documentation/gcode/Mach3-GCode-Language-Reference.pdf) *(search snippet)*; [Fanuc helical feed article](https://industrialmonitordirect.com/blogs/knowledgebase/fanuc-0i-mf-helical-interpolation-feed-rate-reduction-fix)
- *(LinuxCNC, as a conservative reference for tolerances)*:
  - Start and end radius must match within "(.05 inch/.5 mm) OR ((.0005 inch/.005mm) AND .1% of radius)".
  - Use at least 4 decimal places in inch and 3 in mm.
  - Radius-format arcs near full circles or semicircles are discouraged: a 1% endpoint change on a 180° arc shifted the 90° point by 7%.
  - Full circles use I/J with no axis words.
  - Very small helix pitches may be converted to a line.
  - Source: [LinuxCNC G-code docs](https://linuxcnc.org/docs/html/gcode/g-code.html)
- Some controls reject 360° arcs, so posts often split full circles into two arcs. Some Fusion posts restrict arcs to the XY plane, and very small arcs can raise radius errors on some controllers. — [Search summary of Autodesk/OpenBuilds post-processor threads](https://forums.autodesk.com/t5/hsm-post-processor-forum/linuxcnc-post-for-lathe-ijk-absolute-or-incremental/m-p/8588064/highlight/true); [OpenBuilds Fusion post thread](https://openbuilds.com/threads/fusion360-postprocessor-v1-0-36-released.20622)
- When using I and J, G91.1 is needed to state whether they are absolute or relative. In a Mach3 thread, one user suspected G91.1 in the header of causing trouble. — [Autodesk HSM post forum: CAM G-code issue with Mach3 post](https://forums.autodesk.com/t5/hsm-post-processor-forum/cam-g-code-issue-with-mach3-post-processor/m-p/7682236)
- Other CV-related gotchas (repeated positions, sub-slice moves, S/T/G4/macros, G0 exact stop, FRO > 100%) are cited in Q1. — [Warp9 getting started](https://warp9td.com/index.php/gettingstarted/setting-up-the-smoothstepper-and-mach4); [Warp9 FAQ Mach4](https://warp9td.com/index.php/faq/faq-mach4)
- Exact Stop set in Avid's Mach4 Defaults tab did not take effect; G61 in the file did. — [Avid forum CV wizard thread](https://forum.avidcnc.com/t/mach4-cv-tuning-wizard/3205)
- M62–M65/M67 must be followed by a motion block that produces "at least 1 step of motion", or Mach4 ignores them. This matters for laser and plasma, and for any synchronized output. — [Warp9 FAQ Mach4](https://warp9td.com/index.php/faq/faq-mach4)
- On Avid, ramp and lead-in feeds far below cut feed cause jerky motion. Keep ramps, lead-ins and helicals within about 15% of cut feed (practitioner opinion). — [Avid forum: Accel/Decel](https://forum.avidcnc.com/t/mach-4-acceleration-deceleration/1123)

### Inferences
- **Recommended NativeCAM .tap conventions for Mach4/Avid:**
  - **Header:** `G90 G94 G17 G40 G49 G80 G91.1 G64` plus units (G20/G21). Repeat the modal line, or at least G64 and G91.1, after each tool change and macro call. Never depend on the profile's General-tab arc mode.
  - **Arcs:**
    - I/J incremental.
    - Under 180° (current behaviour) is the most robust choice. Going up to under 360° per block is fine with I/J, but there is no evidence it helps. Never use R for arcs near 180°.
    - Emit enough decimals: 4 for inch (0.0001") and 3 for mm.
    - Verify after rounding that |r_start − r_end| ≤ 0.0005" / 0.005 mm. If not, fall back to G1 or adjust the endpoint.
    - Drop arcs whose chord or radius rounds to near zero, i.e. below the minimum segment length.
  - **Helices:** emit G2/G3 with Z for helical ramp entry and bores. Split into under-180° pieces, each with its proportional Z, which matches NativeCAM's current arc rule. For time estimation, use helix length √((Rφ)² + Δz²) as the feed path, the Mach3 convention, until a test on the PRO6060 confirms Mach4 behaviour.
  - **Feeds and words:** emit F only when it changes. Emit S only at spindle start, never per-move. No G4 inside contours. Avoid M-macros mid-path.
  - **Rapids:** each G0 implies stops at both ends. Combine "retract, traverse, plunge" sequences with G1 at high feed where safe, to keep CV across short hops. For example, a short lateral link at clearance height can be a G1 at max feed. This is a cycle-time optimization option, not a default.
- **Arc points per segment** (chord sagitta e = R(1−cos(φ/2)), L ≈ √(8Re)): R = 10 mm at e = 0.01 mm gives a 0.89 mm chord, and R = 2 mm at e = 0.005 mm gives 0.28 mm. That is close to the 0.17 mm ESS slice distance at 400 IPM. Linearized small-radius curves are therefore right at the CV-breaking threshold, which is one more reason to keep emitting true G2/G3.

### Gaps
- No Mach4-specific statement was found on full 360° I/J circles (allowed or not), on helical feed basis, or on Mach4's arc radius-mismatch tolerance and its error behaviour.
- The header Avid's own Fusion and Vectric posts emit (G64? G91.1?) was not found. Downloading Avid's posts from their support downloads page would settle what Avid users' Mach4 profiles expect.
- Whether Mach4 G0 is a coordinated straight line or independent per-axis ("dogleg") moves is not confirmed. This affects rapid time and collision checks.
