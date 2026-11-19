# G-code dialect differences between CNC router controllers (for post-processor design)

Research date: 2026-11-19. Conventions used in these notes:
- **[V]** means the claim comes from official documentation or the firmware source code, and the citation is inline.
- **[C]** means the claim comes from a community or forum source and is labelled as such.
- **[UNVERIFIED]** means the claim comes from the researcher's prior knowledge and no fetched source confirms it. Check it before relying on it in a post. These items appear only under Inferences or Gaps.
- Several official sources could not be retrieved: the FluidNC wiki (connection refused), the Carbide 3D supported-gcodes FAQ (404 on direct fetch, so only the search snippet is available), the Mach4 Mill PDF (binary that would not parse), the ShopBot ComRef PDF (TLS or host error), and the UCCNC, Centroid CNC12 and NcStudio manuals (PDF, 403 or 404). The coverage for those controllers is thinner and is flagged.

---

## Q0. Core comparison (summary table and per-controller notes)

### Takeaway
The controllers fall into four families:
1. **Grbl-lineage firmware: GRBL 1.1, grblHAL, FluidNC, and Carbide Motion on GRBL.** These are strict. Unknown words cause errors, there is no G64, no G90.1, and no G43 H. The base firmware has no canned cycles; grblHAL is the exception and adds them. Line buffers are small, and M6 needs a sender or firmware feature.
2. **LinuxCNC/RS274NGC-like interpreters: LinuxCNC/PathPilot, Buildbotics (CAMotics interpreter), and PlanetCNC.** These accept a rich dialect: G64 P, G90.1, canned cycles, G43 H, and G4 P in seconds.
3. **Fanuc-flavoured PC controls: Mach3, Mach4, UCCNC, Masso and Centroid CNC12.** These support canned cycles and macro-driven M6. **G4 P units differ between them**: Masso uses milliseconds, Mach4 depends on the decimal point, and Mach3 is configurable.
4. **Proprietary or DSP controls: ShopBot OpenSBP, RichAuto/Weihong (Axiom), and the new Onefinity Redline/RealTime RTX.** For these the vendor's own post processor is effectively the specification.

The user's premise that "Onefinity's current controller is FluidNC" is **not supported**. Onefinity moved from Buildbotics (2020–2025) to Masso G3 (Elite 2023) and then to its **Redline** HMI with **RealTime RTX-1/RTX-2** motion controllers (2025+).

### Cited Findings

#### Summary table
In the table, "—" means not supported or rejected, and "?" means not found in any fetched source (see Gaps).

| Controller (version basis) | IJ mode | G90.1 | R arcs | G61 / G64 | Canned G81–83 | M6 | Tool length | G4 P units | Max line | Unknown M-code |
|---|---|---|---|---|---|---|---|---|---|---|
| GRBL 1.1 (gnea, final 1.1 branch) | Incremental only (G91.1 no-op) [V] | Rejected, error 20 [V] | Yes; R full circle not supported [V] | G61 accepted but no effect; G61.1 and G64 rejected [V] | — (only G80) [V] | **error:20** [V] | G43.1 / G49 only [V] | seconds? (see Gaps) | 80 chars default (`LINE_BUFFER_SIZE`); error 11 [V] | error:20 [V] |
| grblHAL (build 20261117) | Incremental (G91.1) [V] | Not listed [V] | ? | G61 listed; G64 not listed [V] | **Yes**: G73, G81, G82, G83, G85, G86, G89, G98/G99 [V] | Config-dependent: `$341` modes 0–4 + ATC [V] | G43, G43.2 (config) + G43.1, G49 [V] | ? | ? | ? |
| FluidNC (main-branch source) | Incremental (G91.1 accepted) [V] | Rejected [V] | Yes (Grbl code) [V] | G61 accepted; G61.1 and G64 unsupported [V] | — (only G80) [V] | ATC or M6 macro, otherwise only records the tool [V] | G43.1 / G49; G43 rejected [V] | ? | **127 chars** [V] | Error [V] |
| Carbide Motion (GRBL-based) | ? | ? | G2/G3 supported [V-snippet] | ? | ? | Implemented for the Nomad tool length sensor (T/M6 trigger home + probe) [V-snippet][C] | G43/G49 accepted but **ignored** [V-snippet] | ? | ? | ? |
| Buildbotics / Onefinity BB (CAMotics interpreter) | IJ inc/abs listed (G90.1/G91.1) [V-CAMotics] | Listed [V-CAMotics] | ? | G61, G61.1, G64 P Q listed [V-CAMotics] | Listed, but the CAMotics "missing" list includes G73, G76, G83, G84 (**conflicting**) [V-CAMotics] | Listed [V-CAMotics] | G43 / G43.1 / G43.2 listed [V-CAMotics] | ? | ? | M101–M199 user codes listed [V-CAMotics] |
| Mach3 | ? (setting; see Gaps) | ? | ? | ? | ? | Macro [UNVERIFIED] | ? | **Configurable**: seconds or ms [V-snippet][C] | ? | ? |
| Mach4 (Mill) | Set by G90.1/G91.1, independent of G90/G91 [V] | Yes [V] | Yes, ±R [V] | G61 exact stop; G64 constant velocity ("For most milling jobs use G64") [V] | Yes: G73, G74, G76, G80–G89, G98/G99 (some config-dependent) [V] | M06 Txx [V]; macro-driven [UNVERIFIED] | G43 H / G49 [V] | **Conflict**: official PDF says seconds; MachMotion says ms without a decimal point and seconds with one [V] | ? | ? |
| LinuxCNC 2.9 / PathPilot base | Incremental default [V] | Yes [V] | Yes, ±R [V] | G61, G61.1, G64 P Q [V] | G73, G74, G76, G81–G86, G89 (not G87/G88) [V] | hal_manualtoolchange prompt; T must precede or accompany it; does not change TLO [V] | G43 [H], G43.1, G43.2 [V] | **seconds (float)** [V] | 256 chars [V] | "Unknown M-code used" error [V] |
| UCCNC | ? | ? | ? | ? | ? | Macro; **M6 macro processing must be enabled** (default does nothing) [C] | ? | ? | ? | ? |
| Masso G3 | ? | Not found in docs nav [V] | ? | G61/G64 not found in docs nav [V] | G81, G82, G83 [V] | M06, M06.1 (unload) [V] | G43 not in nav [V] | **milliseconds** [V] | ? | ? |
| Centroid Acorn/AcornSix (CNC12) | ? | ? | ? | ? | ? | M-functions have default actions, customisable as macros [C/secondary] | G43 H used in Avid/Centroid post [C] | ? | ? | ? |
| PlanetCNC TNG | ? | ? | ? | ? | ? | M6 runs a user-editable M6.gcode script [secondary] | ? | **seconds** [secondary] | ? | ? |
| ShopBot (SB3/SB4) | OpenSBP native; also "reads standard g-code" [V-snippet] | ? | ? | ? | ? | ? | ? | ? | ? | Not every G-code is recognised [C] |
| RichAuto DSP (A11/A18; Axiom) | "supports standard G-code" [secondary] | ? | ? | ? | ? | Most such machines have no ATC [C] | ? | ? | ? | ? |
| Weihong NcStudio | "can directly support G code and PLT" [V] | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| Onefinity Redline (RealTime RTX) | Dialect undocumented in fetched sources | ? | ? | ? | ? | ? | ? | ? | ? | ? |

#### Per-controller notes

**GRBL 1.1 (gnea/grbl).** Applies to Shapeoko through Carbide Motion, older X-Carve, Sienci LongMill MK1/MK2 with gSender, and UGS or CNCjs on GRBL.
- Complete supported list (README) [V] — [gnea/grbl README](https://github.com/gnea/grbl):
  - Non-modal: G4, G10L2, G10L20, G28, G30, G28.1, G30.1, G53, G92, G92.1.
  - Motion: G0, G1, G2, G3, G38.2–G38.5, G80. Feed: G93, G94. Units: G20, G21. Distance: G90, G91. Arc IJK: **G91.1 only**. Plane: G17, G18, G19.
  - TLO: **G43.1, G49**. Cutter comp: **G40 only**. WCS: G54–G59. Control: **G61** only.
  - Program flow: M0, M1, M2, M30. Coolant: M7*, M8, M9. Spindle: M3, M4, M5.
  - Valid words: F, I, J, K, L, N, P, R, S, T, X, Y, Z.
- Parser source [V] — [grbl gcode.c](https://github.com/gnea/grbl/blob/master/grbl/gcode.c):
  - The M-code `default:` branch is `FAIL(STATUS_GCODE_UNSUPPORTED_COMMAND)`, so **M6, or any other unlisted M-code, raises error:20**.
  - T is tracked only ("Select tool: NOT SUPPORTED. Only tracks value"). `MAX_TOOL_NUMBER` is 255, and exceeding it raises error 38.
  - G61 is accepted but its mode assignment is commented out. G61.1 is rejected and G64 falls to default, raising error 20.
  - G90.1 is rejected ("[G90.1 not supported]") and G91.1 is accepted as a no-op.
- Error codes [V] — [grbl interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md):
  - 11: max characters per line exceeded. 20: unsupported command. 21: two codes from the same modal group. 22: feed rate undefined. 24/25: axis-word conflicts or a repeated word. 27: N outside 1–9,999,999. 29: G59.1–G59.3 unsupported. 30: G53 needs G0 or G1.
  - 33: invalid target. 34: R-arc math error ("split the arc into semicircles or quadrants, or use the offset definition"). 35: missing IJK. **36: unused leftover words**. 37: G43.1 on the wrong axis. 38: tool number too high.
  - A block with an error is purged and not executed. During character-counting streaming, lines already in the RX buffer keep executing after an error. The doc recommends `$C` check mode.
- Buffers [V] — [grbl config.h](https://github.com/gnea/grbl/blob/master/grbl/config.h); [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md):
  - `LINE_BUFFER_SIZE` defaults to 80. The override in config.h is commented out ("override default in protocol.h").
  - The serial RX buffer is 128 characters (127 usable).
  - The planner look-ahead is 16 blocks.
- Compile-time options [V] — [config.h](https://github.com/gnea/grbl/blob/master/grbl/config.h):
  - `ENABLE_M7` is disabled by default, so stock GRBL accepts only **M8** for coolant (in practice the dust-collector relay).
  - Parking (`PARKING_ENABLE`) and M56 are disabled by default.
- M2 and M30 restore modal defaults and print `[MSG:Pgm End]` [V] — [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).

**grblHAL (core build 20261117).** [V] — [grblHAL/core README](https://github.com/grblHAL/core)
- Adds canned cycles G73, G81, G82, G83, G85, G86, G89 with G98/G99. G76 depends on the driver.
- G43 and G43.2 depend on the driver or configuration; G43.1 and G49 are always available.
- G65/G66/G67 and M99 require the keypad-macros or SD-card plugin.
- M62–M68 I/O counts depend on the driver.
- Valid words are A–Z, including D, E, H, O, Q, U, V, W.
- G90.1 and G64 are **not** in the list.
- M6 depends on the driver or configuration and has a manual mode and an ATC mode. Manual mode "requires compatible GCode sender due to protocol extensions, new state and RT command".
- Builds before 20241208 reset settings on update.
- Tool change modes [V] — [grblHAL tool change wiki](https://github.com/grblHAL/core/wiki/Manual,-semi-automatic-and-automatic-tool-change):
  - `$341` = 0: Normal (fully manual; the program must stop spindle and coolant and move).
  - 1: Manual touch-off (moves to home; `$TPW` touch-off).
  - 2: Manual touch-off at G59.3.
  - 3: Automatic touch-off on a tool sensor at G59.3.
  - **4: "Record the tool number and ignore M6"**.
  - ATC is "fully transparent to the sender".
  - Modes 1–3 exist from build 20200805 and mode 4 from 20200929. `$342`–`$344` set probing distance and feeds. `$TLR` sets the reference tool length.

**FluidNC (ESP32).** [V] — [FluidNC GCode.cpp](https://github.com/bdring/FluidNC/blob/main/FluidNC/src/GCode.cpp)
- The parser is Grbl-derived, with these differences:
  - Line limit **127 chars** (`LineLengthExceeded`).
  - Accepts G54–**G59.3**.
  - M1 is parsed as a **no-op** ("Optional Stop not supported").
  - M4 requires a reversible spindle or laser mode.
  - Adds M7.1/M8.1, M56, M61 (Q), M62–M65 (digital out), M66 (wait on input), M67/M68 (analog out), and M70–M73.
  - Unsupported M-codes return `GcodeUnsupportedCommand`.
  - G43 is rejected (only G43.1). G64, G81–G83 and G90.1 are unsupported. G41/G42 are not supported. G40 is a no-op.
  - The max line number constant is 10,000,000.
- **M6** calls `spindle->tool_change()`, which uses a configured ATC or an M6 macro. If neither exists, it sets `current_tool` and the change does nothing physical.
- The old GitHub wiki says the official wiki moved to wiki.fluidnc.com [V] — [FluidNC GitHub wiki](https://github.com/bdring/FluidNC/wiki). That site refused connections during this research.
- Community: a FluidNC user reported the board "ignores the tool change codes", and was referred to the ATC docs [C] — [V1E forum](https://forum.v1e.com/t/tool-change-m06/41944).

**Carbide Motion (Shapeoko / Nomad).**
- The official FAQ (search snippet only; the page returned 404 when fetched) [V-snippet] — [Carbide 3D Hub FAQ](https://carbide3d.com/hub/faq/supported-gcodes):
  - Lists G0, G1, G2/G3, G4, M0, M1, M2, M3.
  - "M6 — Tool change — this is implemented in Carbide Motion to facilitate the Nomad tool length sensor".
  - G40, G43 and G49 are **accepted but ignored**.
  - **G54–G59 are accepted but ignored**, because Carbide Motion uses its own internal work coordinate systems.
- Community user: on a Nomad, "T[#] and M6 commands both prompt the Nomad to home and probe. The M6 will ask for a tool change then probe again". A community member (not labelled as staff) said "CM's behavior is not configurable" [C] — [Carbide 3D community](https://community.carbide3d.com/t/list-of-supported-g-codes-carbide-motion-and-nomad/22903).

**Senders on GRBL: gSender, CNCjs, UGS, Easel.**
- gSender options are under Config → Tool Changing: **Ignore** M6, **Pause**, or a **Wizard** such as Fixed Tool Sensor [V] — [Sienci gSender Tool Changing](https://resources.sienci.com/view/gs-tool-changing/). A "Code" option that runs custom code blocks is reported by users [C].
  - Users report soft-limit alarms on resume and a greyed-out "Probe Changed Tool" button with the Fixed Tool Sensor wizard (Edge 4/5) [C] — [Sienci forum](https://forum.sienci.com/t/fixed-location-tool-change-issue-soft-limits/9421); [Sienci forum](https://forum.sienci.com/t/fixed-tool-sensor-probe-changed-tool-button-permanently-greyed-out-edge-4-grbl-macos/26385).
  - A GitHub issue argues that Ignore should warn that results after an ignored M6 are undefined [C] — [gsender issue #515](https://github.com/Sienci-Labs/gsender/issues/515).
- CNCjs: tool change is available from **CNCjs 1.9.11**. M6 pauses the program and runs a tool-change macro. The TLO variant does G49, then `G38.2 Z-[dist] F[feed]`, then `G43.1 Z[posz - TOUCH_PLATE_HEIGHT]` [V] — [CNCjs wiki Tool Change](https://github.com/cncjs/cncjs/wiki/Tool-Change).
- UGS and Easel: no primary source was fetched (see Gaps). The Fusion library has "Easel by Inventables" and "X-Carve by Inventables" posts [V] — [Fusion Post Library reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).

**Onefinity: which controller.** [V] — [Onefinity: Which controller does my machine use](https://www.onefinitycnc.com/post/which-controller-does-my-onefinity-machine-use)
- Gen 1 Original (2020) and Gen 1 Pro (2022) used the **BB Buildbotics Controller**, discontinued in 2025.
- Gen 1 Elite (2023) used the **Masso G3 Touch**.
- Gen 2 Elite (2025) uses the **closed-loop RTX-2** and the Apprentice uses the **open-loop RTX-1**. Gen 1 Elite Redline uses RTX-1; the page text and image caption conflict on this. All of these pair with the Redline 15" HMI, which forms the "Redline Control System".
- Redline upgrade kits exist for Buildbotics and Masso machines [V] — [Onefinity Redline upgrade kits](https://www.onefinitycnc.com/post/redline-upgrade-kits-for-all-onefinity-cnc-machines-are-here).
- **No evidence links Onefinity to FluidNC.**

**Onefinity Redline / RealTime CNC RTX.**
- Posts are published by RealTime CNC [V] — [realtimecnc.com/postp](https://realtimecnc.com/postp/):
  - Vectric Metric, Imperial, Rotary Metric and Rotary Imperial (`.pp`, v2 2026-4-15).
  - Fusion 360 (`.cps`, v2 2026-4-19).
  - Carveco (`.con`).
  - FreeCAD (`.py`, v1 2026-5-22).
- In Vectric the posts come from Vectric's cloud database as "Onefinity Redline/Realtime (inch)/(mm)" [V] — [Onefinity Vectric Redline guide](https://www.onefinitycnc.com/post/setup-a-post-processor-exporting-gcode-for-vectric-with-the-redline-motion-control-system).
- Community: the "Realtime RTSX" post emitted M3/M5 around every laser power change, which stalled the laser; fixed by a corrected post [C] — [Onefinity forum](https://forum.onefinitycnc.com/t/redline-j-tech-laser-issue-solved-post-processor-issue/39509).
- The fetched sources do not document the dialect.

**Buildbotics (and Onefinity BB).**
- A community user said Buildbotics "mostly implements linuxcnc's gcode conventions" (Jan 2026) [C] — [Onefinity forum](https://forum.onefinitycnc.com/t/listing-of-programming-codes-for-buildbotics-controllers/37222).
- Community users point to the CAMotics G-code page as "Controller support for gcode" [C] — [Onefinity forum](https://forum.onefinitycnc.com/t/m-codes-does-buildbotics-support-m-codes-macros/1100).
- The CAMotics page lists the following [V for CAMotics; applicability to the controller is C]:
  - Motion and arcs: G5/G5.1/G5.2 and G90.1/G91.1.
  - Path and offsets: G61/G61.1/G64, G43/G43.1/G43.2, G54–G59.3, G28/G30, and G53.
  - M-codes: M6/M61, M62–M68, M70–M73, and M101–M199.
  - Program control: O-codes (sub, while, if, repeat).
  - Canned cycles: G73, G76, G80–G89, G98/G99.
  - Its own "Missing G-codes" section contradicts this. It lists G73, G76, G83, G84, G87, G88, G93, G95, cutter comp and splines as "not yet implemented", and says the list "is probably incomplete" — [CAMotics G-code](https://camotics.org/gcode.html).
- Onefinity maintains a Buildbotics-derived firmware fork [V] — [OneFinityCNC/onefinity-firmware releases](https://github.com/OneFinityCNC/onefinity-firmware/releases).
- Fusion library posts: "Buildbotics 4-Axis CNC Controller" and "Onefinity BB Buildbotics" [V] — [Fusion Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).

**Mach3.**
- The G4 dwell unit is a Mach3 setting (seconds or milliseconds) [C] — [mycncuk G4 thread](https://www.mycncuk.com/threads/2968-G4-Dwell-parameters).
- A SheetCam post always emitted seconds ("because that's the standard Mach3 install"), which caused pierce-delay errors on machines set to milliseconds [C] — [Langmuir forum](https://forum.langmuirsystems.com/t/mach3-pierce-delay-issue/3542/9).
- Fusion library posts: "Mach3Mill" and "CNC Router Parts (Mach3Mill)" [V] — [Fusion Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).

**Mach4 (including Avid CNC).**
- The official Mach4 Mill G-code manual says G04 P is in **seconds** (search snippet of the PDF) [V-snippet] — [Mach4 Mill GCode Manual](https://www.machsupport.com/wp-content/uploads/2014/05/Mach4%20Mill%20GCode%20Manual.pdf).
- MachMotion's Mach4 reference gives a different rule [V-vendor] — [MachMotion Mach4 G/M-code reference](https://support.machmotion.com/books/software/page/mach4-g-code-and-m-code-reference):
  - "The duration of the dwell is specified by P in milliseconds with no decimal point". With a decimal point, P is seconds ("G04 P5." is 5 s). The dwell must be greater than 1 ms.
  - G90.1/G91.1 are independent of G90/G91. A positive R gives a sweep under 180°, a negative R over 180°.
  - G61 is exact stop and G64 is constant velocity ("For most milling jobs use G64").
  - Canned cycles: G73, G74, G76, G80–G89 (incl. G84.2/G84.3) with G98/G99. Asterisked cycles depend on machine configuration.
  - G28 is non-modal. G30 takes P2–P4. G53 is non-modal. G43 H and G49 are supported.
  - Usage example "M06 T01". The end of program is "most commonly M30".
  - MachMotion is a Mach4 integrator, so its build may differ from stock Mach4 Hobby. This is a **conflict** with the official PDF.
- Avid CNC posts:
  - Stock Vectric post "Avid CNC (inch) (*.tap).pp", bundled with VCarve 11+. Corbin's ATC version adds `T[T]M6` and `G43 H[T]` to the header and `M5` / `(Change to Tool: [TOOLNAME])` / `T[T]M6` / `G43 H[T]` to TOOLCHANGE. He warns "The one provided by Avid is not right!" for ATC use [C] — [Corbin's Treehouse: Avid ATC Vectric](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-setup-vectric-vcarve-vectric-aspire).
  - Fusion library: "Avid CNC" and "Avid CNC Plasma" [V] — [Fusion Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).
  - For Fusion ATC: check "Use M6" and enable "G28 Safe Retracts". An update says the current Avid posts now work with an ATC. Free or personal Fusion is limited to one tool change per file [C] — [Corbin's Treehouse: Avid Fusion](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-for-fusion-360/).
  - A community-enhanced Avid Fusion post exists (GitHub berrianmtn/avid-fusion-post-processor) [C] — [Avid forum](https://forum.avidcnc.com/t/enhanced-avid-post-processor-for-fusion-360/5049).
- Vectric documentation shows an Avid rotary post named `AvidCNC_WrapX2A_G93_inch.pp`, which uses inverse-time feed for wrapped rotary [V] — [Vectric post-processor editing docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html).
- **Avid now also ships the "EX" controller, which runs Centroid CNC12 rather than Mach4.**
  - Trade notice: "Avid CNC… has chosen Centroid CNC technology to power its next generation EX CNC controllers", for new kits and as an upgrade [V-trade press] — [MFG News](https://www.mfgnewsweb.com/archives/4/67461/Controls-dec24/ad_info.aspx).
  - Users say "the guts of the system is still Centroid CNC12" [C] — [Avid forum](https://forum.avidcnc.com/t/new-controls-unofficial-launch/3567).
  - Users report the touch-plate sequence differs from Mach4 [C] — [Avid forum](https://forum.avidcnc.com/t/migrating-challenge-from-mach4-to-ex-controller/3891).
  - EX posts: Vectric "Avid EX Control ATC (Inch) (*.cnc).pp" [C] — [Corbin's Treehouse](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-setup-vectric-vcarve-vectric-aspire); Fusion "Avid CNC EX Router V2.cps" [C] — [Avid forum](https://forum.avidcnc.com/t/centroid-feature-request-issues/3755).

**LinuxCNC (2.9 docs) and PathPilot.**
- Syntax and file rules [V] — [LinuxCNC G-code overview](https://linuxcnc.org/docs/html/gcode/overview.html):
  - Max line length 256 characters.
  - Comments use `( )` inline or `;` to end of line.
  - `%` wrapping is optional when M2/M30 is present and required otherwise ("File ended with no percent sign or program end").
  - Input is case-insensitive outside comments. Spaces are allowed anywhere. Leading and trailing zeros are optional.
  - "Any input not explicitly allowed is illegal and causes the Interpreter to signal an error".
  - N numbers may be skipped or repeated but must be in the proper place. Best practice is not to use them.
- G-code behaviour [V] — [LinuxCNC G-codes](https://linuxcnc.org/docs/html/gcode/g-code.html):
  - G4 P is seconds (float).
  - Incremental IJ is the default; G90.1/G91.1 are supported.
  - Full circles use offsets only, with P turns (an integer).
  - Center-format error tolerance is "(.05 inch/.5 mm) OR ((.0005 inch/.005mm) AND .1% of radius)".
  - G61 is exact path, G61.1 exact stop, and G64 P (tolerance) Q (naive-CAM tolerance).
  - Canned cycles: G73, G74, G76, G81–G86, G89. G87/G88 are not implemented.
  - G28/G30 use parameters 5161+/5181+ and go to the machine origin if never set. G53 is non-modal.
  - G43 [Hn], G43.1, G43.2, G38.2–.5, G93/G94/G95.
- M-code behaviour [V] — [LinuxCNC M-codes](https://linuxcnc.org/docs/html/gcode/m-code.html):
  - With hal_manualtoolchange, M6 stops the spindle and prompts for the last T. "The tool length offset is not changed by M6", so posts must follow it with G43.
  - M0 pauses. M1 pauses only if the optional-stop switch is on. M2/M30 end the program (M30 also exchanges pallets).
  - M7 is mist and M8 is flood; both must be connected in HAL.
  - M100–M199 run user programs. A missing one raises "Unknown M-code used".
- PathPilot: Tormach publishes "PathPilot post processor guidelines" (not fetched, see Gaps). The Fusion library has a "Tormach PathPilot" post [V] — [Fusion Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).

**UCCNC (CNC Drive).**
- The user manual has a "Supported codes" chapter split into G-codes, M-codes and other codes, plus a macro chapter. Only the table of contents was visible [secondary] — [UCCNC manual on Scribd](https://es.scribd.com/document/361829095/UCCNC-usersmanual).
- M6 macro processing must be enabled in Settings, because "the default is to do nothing" [C] — [cncdrive forum](https://forum.cncdrive.com/viewtopic.php?p=33541).
- The macro that is actually used lives in the **profile's** Macro folder [C] — [Stepcraft forum](https://www.stepcraft-systems.com/forum/accessories/3288-help-with-m6-macro).
- UCCNC can be set to ignore M6 [C] — [cncdrive forum](https://forum.cncdrive.com/viewtopic.php?p=14596).
- A T word must not by itself start a tool change; only M6 should. One forum problem turned out to be the post processor [C] — same thread family.
- Fusion library posts: "UCCNC" and "STEPCRAFT UCCNC" [V] — [Fusion Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).

**Masso G3.**
- **G04 P is milliseconds**. The docs give the example `N10 G04 P2000` = 2 s [V] — [Masso G04](https://docs.masso.com.au/supported-g-codes/g04-dwell?ln=en).
- The docs navigation lists G81/G82/G83, G28, G30 ("move to parking position"), G53, M06, M06.1 (tool unload), M07/M08/M09 and M98/M99. G43, G61, G64 and G90.1/G91.1 were **not** seen in the navigation [V] — same source.
- Tool select is "T (the desired tool number) M06" [secondary, Sherline] — [Sherline Masso codes](https://sherline.com/?p=64254).
- Fusion library posts: "MASSO" and "Onefinity Masso" [V] — [Fusion Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).

**Centroid Acorn / AcornSix (CNC12).**
- "Most of the CNC12 M-Functions have default actions as described in the Mill and Lathe operators manuals, but can also be customized", and "most all CNC12 G&M codes can be used in a macro" [secondary] — [Centroid macro programming (Scribd)](https://www.scribd.com/document/756016457/centroid-cnc-macro-programming).
- On Acorn, M6 calls a main tool-change macro, and a drawbar relay is wired to an Acorn output [C] — [Corbin's Treehouse](https://www.corbinstreehouse.com/blog/wp-json/wp/v2/pages/8120).
- The Avid/Centroid ATC Vectric post uses the `.cnc` extension. Its tool block is M5, a comment, `T[T]M6`, then a G43 line [C] — [Corbin's Treehouse](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-setup-vectric-vcarve-vectric-aspire).
- Fusion library posts: "CENTROID" and "Centroid Turning" [V] — [Fusion Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).

**PlanetCNC (TNG).**
- "G04 P – Delays execution for duration P seconds". M6 runs a customisable `M6.gcode` script. This comes from an unofficial Scribd copy of the TNG G-code reference [secondary] — [PlanetCNC TNG GCode (Scribd)](https://www.scribd.com/document/605207632/PlanetCNC-TNG-GCode).
- Fusion library posts: "PlanetCNC" and "PlanetCNC Turning" [V] — [Fusion Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).

**ShopBot.**
- The OpenSBP Command Reference says ShopBot "also reads standard g-code… We favor OpenSBP because it is easier and more human readable" [V-snippet] — [ShopBot ComRef](https://support.shopbottools.com/ShopBotDocs/files/ComRef.pdf); [Make, 2009](https://makezine.com/2009/04/13/shopbot-open-sources-their-code/).
- A 2008 TalkShopBot thread lists G-code types "*.gcc, *.tap, *.nc, *.agc". It notes that ShopBot "does not recognize all the g-code commands" CAM wizards emit [C, old] — [TalkShopBot archive](https://talkshopbot.com/forum/archive/index.php/t-9096.html). (This was a search snippet; the exact thread was not re-verified.)
- DeskProto says SB3 "cannot handle a feedrate that changes all the time". It also claims ShopBot does not use G-code, which **contradicts** ShopBot's own documentation [secondary] — [DeskProto ShopBot tips](https://www.deskproto.com/support-tips-tricks/dp-tips-shopbot.php).
- The HMC machine shop says ShopBot runs a "specific flavor" of G-code and recommends an Autodesk ShopBot post [C] — [HMC ShopBot tutorials](https://sites.google.com/g.hmc.edu/hmc-machine-shop/tutorials/woodshop-tutorials/shopbot-tutorials).
- Fusion library post: "ShopBot OpenSBP" [V] — [Fusion Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).

**RichAuto DSP / Weihong NcStudio / Axiom.**
- The A11 manual listing says the system "supports standard G-code and CAM file formats" [secondary] — [RichAuto A11 manual (SlideShare)](https://www.slideshare.net/slideshow/dsp-controller-a11-manual/56113711).
- NcStudio V10 "can directly support G code and PLT code format files" [V] — [Weihong NcStudio V10 manual](https://www.weihong.com.cn/en/uploads/soft/160816/1-160Q6111A5.pdf).
- Axiom controllers are reported as RichAuto A11/A81 and A18S [C] — [Vectric forum](https://forum.vectric.com/viewtopic.php?p=190173); [Grid.Space forum](https://forum.grid.space/t/output-for-an-axiom-cnc-using-richauto-b11/1225).
- The Vectric Axiom post is "Axiom HHC CNC (mm) (*.mmg)". A community user says the Axiom controller "knows nothing about Imperial", so use mm [C] — [Vectric forum](https://forum.vectric.com/viewtopic.php?p=190173).
- A community user says most RichAuto machines (Axiom, Powermatic, some Laguna) "do not actually support swapping out tools", that is, they have no ATC [C] — same source.
- Fusion library posts: "RichAuto DSP" and "NcStudio Programming System" [V] — [Fusion Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm).

### Inferences
- **NativeCAM's priority, the user's Avid Mach4 machine, is in the well-documented Fanuc/Mach4 family.** The user's existing Mach4 profile macros, such as `m6` in the profile's Macros folder, are the ground truth for M6 behaviour on their machine. Avid's newer EX controller is Centroid CNC12, so an "Avid" post must ask Mach4 or EX.
- The Grbl family (GRBL, FluidNC, and Carbide Motion's GRBL base) shares the same parser skeleton and the same arc tolerance code. One "Grbl-strict" emitter with per-firmware flags would serve GRBL, grblHAL, FluidNC and Carbide Motion:
  - max line length;
  - M6 allowed;
  - canned cycles allowed (grblHAL only);
  - G59.x allowed (FluidNC);
  - M7 allowed;
  - G43 H allowed (grblHAL only, configuration-dependent).
- For Redline/RTX, ShopBot and RichAuto, the safe engineering choice is to treat the vendor's published post (RealTime's `.pp`/`.cps`, Fusion "ShopBot OpenSBP" and "RichAuto DSP") as the specification. Mirror its output conservatively and test on hardware.

### Gaps
- **GRBL 1.1 G4 P units.** The fetched sources do not state them. config.h's `DWELL_TIME_STEP 50` (ms) is only the internal dwell-check resolution. [UNVERIFIED] GRBL treats G4 P as **seconds** (float), following LinuxCNC; this is widely relied on by grbl posts. Confirm from `mc_dwell()` in motion_control.c or the grbl wiki before shipping.
- **FluidNC.** The official wiki (wiki.fluidnc.com) was unreachable, so the documented ATC/M6 macro config syntax, G4 units and laser-mode details are unconfirmed. Only parser source was read, and the last ~19 KB of GCode.cpp was not.
- **grblHAL.** Line length, G4 units and R-arc behaviour were not stated on the fetched page. [UNVERIFIED] grblHAL inherits Grbl's G4 seconds and arc checks.
- **Carbide Motion.** The FAQ could not be fetched (404). It is unknown which Carbide Motion version (v5 or v6) the snippet describes, whether CM rejects unknown codes or passes them to GRBL, and how the BitSetter workflow interacts with M6.
- **Buildbotics.** The Buildbotics controller's own G-code list was not found. CAMotics is the simulator and interpreter project, and its page self-contradicts on canned cycles. [UNVERIFIED] Buildbotics firmware has configurable "program start", "tool change" and "program end" G-code snippets in Settings, with the tool change defaulting to a pause.
- **Redline/RTX.** Dialect, M6 support, arc format, G4 units and file extension are all undocumented in fetched sources. The next step is to download RealTime's Vectric `.pp` or Fusion `.cps` from realtimecnc.com/postp and read its output blocks.
- **Mach3.** [UNVERIFIED] Mach3 has a General Config "IJ Mode" (Absolute/Incremental) setting. Vectric's "Mach2/3 Arcs" posts assume incremental IJ. M6 is executed via the `M6Start.m1s` / `M6End.m1s` macros. Not confirmed from a fetched source.
- **Mach4.** The official manual could not be parsed (binary PDF). The seconds-vs-ms rule conflict between the official manual and MachMotion is unresolved. Unknown-M-code behaviour and the custom M-code macro range were not confirmed.
- **Avid Mach4 profile.** The exact M6 macro behaviour (Z retract to machine top, spindle stop, prompt, optional touch-plate or tool-setter routine) was not found in a fetched source. Inspect the user's own profile macros.
- **UCCNC, Centroid CNC12 and PlanetCNC.** Official manuals were not retrieved. G4 units for UCCNC and CNC12, canned-cycle lists, comment syntax and line limits are unconfirmed. [UNVERIFIED] CNC12 G4 P is seconds and CNC12 runs M6 via a `mfunc6.mac` macro.
- **ShopBot OpenSBP syntax.** The ComRef could not be fetched. [UNVERIFIED, prior knowledge] The essentials are:
  - `'` starts a comment.
  - `MS,xy,z` sets move speed in **units per second**, not per minute.
  - `JS` sets jog speed.
  - `M2`/`M3` are feed moves and `J2`/`J3` are rapids.
  - `CG,...` is the arc command.
  - `SA`/`SR` set absolute/relative.
  - `SO,n,1/0` switches outputs (spindle relay) and `TR,rpm` sets spindle RPM.
  - `C9` is the tool-change macro, driven by the `&Tool` variable.
  - `PAUSE`.
  - The file extension is `.sbp`.
  Verify all of this against ComRef before writing an OpenSBP emitter.
- **RichAuto/NcStudio.** Format restrictions were not confirmed: comment acceptance, I/J vs R, maximum arc sweep, M6, file-size or memory limits, and the extensions (.nc, .tap, .mmg, .u00). The Autodesk RichAuto forum thread returned 403.
- **UGS and Easel.** No fetched source on how they handle M6 or unsupported codes.
- **PathPilot.** The Tormach post guidelines were not fetched; see knowledgebase.tormach.com "PathPilot post processor guidelines".

---

## Q1. Arcs: G2/G3, IJ absolute vs incremental, R format, helical, max sweep, arc tolerance errors

### Takeaway
Always emit **incremental I/J (center offsets) and never emit G90.1** unless the target is known to accept it (LinuxCNC, Mach4 and CAMotics/Buildbotics do; GRBL and FluidNC reject it). Avoid R-format arcs, especially full circles. Keep the end-point radius mismatch well under **0.005 mm**. GRBL, FluidNC and LinuxCNC all reject arcs whose start and end radii differ by more than 0.5 mm, or by more than both 0.005 mm and 0.1% of the radius.

### Cited Findings
- **GRBL 1.1**
  - Supports only G91.1 (incremental IJK) [V] — [gnea/grbl README](https://github.com/gnea/grbl).
  - G90.1 is explicitly rejected ("[G90.1 not supported]") [V] — [gcode.c](https://github.com/gnea/grbl/blob/master/grbl/gcode.c).
  - Offset-format tolerance [V] — [gcode.c](https://github.com/gnea/grbl/blob/master/grbl/gcode.c): `delta_r = fabs(target_r - r)`. If `delta_r > 0.005`, it fails with `STATUS_GCODE_INVALID_TARGET` (**error 33**) when `delta_r > 0.5` or when `delta_r > 0.001*r`.
  - R-format: a negative R selects the >180° arc. R fails with error 34 if the radius is too small for the chord. A target equal to the current position fails (error 33), so **R-format full circles are impossible** [V] — [gcode.c](https://github.com/gnea/grbl/blob/master/grbl/gcode.c); [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).
  - Error 32: G2/G3 with no axis words in the selected plane. Error 35: offset-format arc missing its IJK word in the plane [V] — [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).
  - Arcs are segmented in firmware, with `N_ARC_CORRECTION 12`. `ARC_ANGULAR_TRAVEL_EPSILON 5E-7` rad is the full-circle detection cutoff, which implies IJ full circles are handled [V] — [config.h](https://github.com/gnea/grbl/blob/master/grbl/config.h).
- **FluidNC** uses the identical tolerance code (`> 0.5mm`; `> 0.005mm AND 0.1% radius`). It rejects G90.1 and accepts G91.1 [V] — [FluidNC GCode.cpp](https://github.com/bdring/FluidNC/blob/main/FluidNC/src/GCode.cpp).
- **grblHAL** lists G91.1 only under Arc IJK Distance Modes. G90.1 is not listed [V] — [grblHAL core README](https://github.com/grblHAL/core).
- **LinuxCNC** [V] — [LinuxCNC G-codes](https://linuxcnc.org/docs/html/gcode/g-code.html):
  - "Incremental Arc Distance Mode is default". G90.1 and G91.1 are supported.
  - Helix: add the axis perpendicular to the plane.
  - Full circles: offsets with no axis words, or P turns. P must be an integer.
  - R-format: nearly full circles and semicircles are "discouraged".
  - Tolerance: "(.05 inch/.5 mm) OR ((.0005 inch/.005mm) AND .1% of radius)".
- **Mach4**: IJ mode is set by G90.1/G91.1 "independent of the G90/G91 setting". ±R chooses a sweep under or over 180° [V-vendor] — [MachMotion Mach4 reference](https://support.machmotion.com/books/software/page/mach4-g-code-and-m-code-reference).
- **CAMotics/Buildbotics** lists G90.1/G91.1 as supported [V for CAMotics] — [CAMotics G-code](https://camotics.org/gcode.html).
- **Carbide Motion** lists G2/G3 as supported [V-snippet] — [Carbide 3D Hub FAQ](https://carbide3d.com/hub/faq/supported-gcodes).

### Inferences
- With mm output at 3 decimals, coordinate rounding is at most 0.0005 mm per word. With inch output at 4 decimals it is at most 0.00005" (0.00127 mm). Both stay well inside GRBL's 0.005 mm floor. Fewer decimals (for example 2 in mm) risk error 33 on small arcs. **Recommend ≥3 decimals in mm and ≥4 in inch**, and compute I/J from the *rounded* start point.
- Emit arcs only in G17 (XY) for 2.5D router work. Helical ramps are accepted by GRBL, FluidNC and LinuxCNC. [UNVERIFIED] Grbl's arc code supports a linear axis component, and helical G2/G3 is routinely used on Shapeokos. Fall back to linearisation for controllers with unknown arc support (RichAuto, Redline) until tested.
- To be safe on all controllers, split arcs at 180°. Some posts split at quadrants (90°) for DSP controllers [UNVERIFIED]. This also sidesteps R-format ambiguity.

### Gaps
- Maximum arc sweep and full-circle handling for Masso, UCCNC, Centroid, PlanetCNC, RichAuto, NcStudio and Redline were not found.
- [UNVERIFIED] Mach3 has an "IJ mode" setting in General Config. A mismatch between that setting and the post's IJ style produces wild arcs. This is a classic Mach3 failure, but no fetched citation confirms it.
- Whether Vectric's stock "Grbl" post linearises arcs versus the "Grbl Arcs" variant was not confirmed. [UNVERIFIED] The names are "Grbl (mm) (*.gcode)" and "Grbl Arcs (mm) (*.gcode)".

---

## Q2. Path blending: G61/G64 and exact-stop defaults

### Takeaway
**Never emit G64 to Grbl-family firmware.** GRBL and FluidNC reject it with error 20, and grblHAL does not list it. GRBL-family firmware always blends using its own junction-deviation planner, and G61 there is accepted but has no effect. LinuxCNC (G64 P Q) and Mach4 (G64) support blending control. Emitting `G64 P<tol>` is valuable on LinuxCNC/PathPilot and possibly Buildbotics.

### Cited Findings
- GRBL: "Control Modes: G61" only [V] — [gnea/grbl README](https://github.com/gnea/grbl).
- GRBL source: the G61 mode assignment is commented out, so it has no effect. G61.1 is rejected and G64 falls to default (unsupported command, error 20) [V] — [gcode.c](https://github.com/gnea/grbl/blob/master/grbl/gcode.c).
- FluidNC: G61 is accepted, G61.1 is not supported, and G64 is not in the switch, so it returns `GcodeUnsupportedCommand` [V] — [FluidNC GCode.cpp](https://github.com/bdring/FluidNC/blob/main/FluidNC/src/GCode.cpp).
- grblHAL lists G61 under Control Modes. G64 is not listed [V] — [grblHAL core README](https://github.com/grblHAL/core).
- LinuxCNC [V] — [LinuxCNC G-codes](https://linuxcnc.org/docs/html/gcode/g-code.html):
  - G61 is exact path and G61.1 is exact stop.
  - G64 without P keeps the "best possible speed".
  - With P, "the actual path will be no more than P- away from the programmed endpoint". Q is the naive-CAM collinear-merge tolerance, and Q0 disables it.
  - The page does not state the startup default.
- Mach4: G61 is modal exact stop and G64 is constant velocity. "For most milling jobs use G64." The power-on default is not stated [V-vendor] — [MachMotion Mach4 reference](https://support.machmotion.com/books/software/page/mach4-g-code-and-m-code-reference).
- CAMotics/Buildbotics lists G61, G61.1 and G64 (P, Q) [V for CAMotics] — [CAMotics G-code](https://camotics.org/gcode.html).

### Inferences
- Implement blending as a per-controller "path mode" option:
  - **GRBL/FluidNC/grblHAL**: emit nothing.
  - **LinuxCNC/PathPilot**: `G64 P0.05` (mm) or similar, user-configurable.
  - **Mach4**: `G64` (P support unconfirmed).
  - **Masso, UCCNC, Centroid**: emit nothing until verified.
- Because GRBL rejects G64, a post that emits a LinuxCNC-style safety line (G17 G21 G40 G49 G64 G80 G90 G94) will alarm a Shapeoko on line 1. Tailor safety lines per controller. G40, G49 and G80 are accepted by GRBL per the README.

### Gaps
- [UNVERIFIED] The LinuxCNC startup default blending mode is commonly G64 with no tolerance, configurable via `RS274NGC_STARTUP_CODE`. Not confirmed in a fetched source.
- Blending support was not found for Masso, UCCNC, CNC12, PlanetCNC, RichAuto, ShopBot or Redline. [UNVERIFIED] CNC12 and UCCNC accept G61/G64. Mach3 accepts G61/G64 (with "Constant Velocity" also a config toggle).

---

## Q3. Tool changes: M6, T words, manual workflows, TLO (G43/G43.1), probing, unknown M-codes

### Takeaway
Tool-change handling is the single biggest dialect split.
- **GRBL 1.1 rejects M6 (error:20)**, so the sender must intercept it. CNCjs, gSender, UGS [UNVERIFIED] and Carbide Motion do this, or the post must emit M0 or split files.
- **grblHAL** has native M6 modes (`$341`).
- **FluidNC** routes M6 to an ATC or macro, and otherwise silently records the tool.
- **LinuxCNC, Mach3/4, UCCNC, Masso, CNC12 and PlanetCNC** run M6 as a macro or prompt.
- Tool length offset syntax differs: GRBL and FluidNC only allow **G43.1 Z<value>** (dynamic), while the PC controls use **G43 H<n>**. LinuxCNC explicitly does *not* apply TLO on M6, so G43 must follow.

### Cited Findings
- **GRBL**
  - The M-code default branch fails with `STATUS_GCODE_UNSUPPORTED_COMMAND`, so M6 and any unknown M-code give error 20 [V] — [gcode.c](https://github.com/gnea/grbl/blob/master/grbl/gcode.c).
  - T is "only tracked", max 255, error 38 above that [V] — same.
  - Error 20 is "Unsupported or invalid g-code command found in block" [V] — [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).
  - Only G43.1 (dynamic TLO) and G49 are supported. G43.1 on another axis gives error 37 [V] — [README](https://github.com/gnea/grbl); [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).
  - G38.2–G38.5 probing is supported [V] — [README](https://github.com/gnea/grbl).
- **grblHAL**: `$341` mode 0 is manual (the program must handle the spindle and moves). 1 is manual touch-off, 2 is touch-off at G59.3, 3 is automatic touch-off at G59.3, and 4 is "Record the tool number and ignore M6". ATC is transparent. Manual modes need a sender supporting the tool-change protocol extension [V] — [grblHAL tool change wiki](https://github.com/grblHAL/core/wiki/Manual,-semi-automatic-and-automatic-tool-change); [grblHAL core README](https://github.com/grblHAL/core).
- **FluidNC**: M6 runs `spindle->tool_change()` (ATC or M6 macro). With neither configured, it sets the current tool only. M61 Q sets the tool number. Plain G43 is unsupported (only G43.1). Unknown M-codes give `GcodeUnsupportedCommand` [V] — [FluidNC GCode.cpp](https://github.com/bdring/FluidNC/blob/main/FluidNC/src/GCode.cpp).
- **CNCjs (≥1.9.11)**: M6 pauses for a manual change. The macro TLO pattern is `G49` → `G38.2 Z-… F…` → `G43.1 Z[posz − plate]` [V] — [CNCjs Tool Change](https://github.com/cncjs/cncjs/wiki/Tool-Change).
- **gSender**: Ignore / Pause / Wizard (Fixed Tool Sensor) options [V] — [Sienci gSender Tool Changing](https://resources.sienci.com/view/gs-tool-changing/). Users report fixed-sensor-wizard bugs [C] — [Sienci forum](https://forum.sienci.com/t/fixed-location-tool-change-issue-soft-limits/9421).
- **Carbide Motion**: M6 is implemented for the Nomad tool length sensor [V-snippet] — [Carbide 3D Hub FAQ](https://carbide3d.com/hub/faq/supported-gcodes). T and M6 both trigger home and probe on a Nomad [C] — [Carbide 3D community](https://community.carbide3d.com/t/list-of-supported-g-codes-carbide-motion-and-nomad/22903).
- **Carbide Create output** (community report): tool changes exported as `M0 ;T302` with no M6 [C] — [Onefinity forum](https://forum.onefinitycnc.com/t/gcode-where-is-m6-tool-change/14739).
- **LinuxCNC** [V] — [LinuxCNC M-codes](https://linuxcnc.org/docs/html/gcode/m-code.html):
  - M6 with hal_manualtoolchange "will stop the spindle and prompt the user to change the tool based on the last T- number programmed".
  - "The tool length offset is not changed by M6", so issue G43 afterwards.
  - Missing user M1xx files give "Unknown M-code used".
  - G43 Hn, G43.1 (replace) and G43.2 (add) are all available [V] — [LinuxCNC G-codes](https://linuxcnc.org/docs/html/gcode/g-code.html).
- **Mach4**: example "M06 T01"; G43 "Activates a tool length offset selected with H"; G49 cancels [V-vendor] — [MachMotion Mach4 reference](https://support.machmotion.com/books/software/page/mach4-g-code-and-m-code-reference).
- **Avid on Mach4 (Vectric ATC edit)**: `M5` / `(Change to Tool: [TOOLNAME])` / `T[T]M6` / `G43 H[T]` [C] — [Corbin's Treehouse](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-setup-vectric-vcarve-vectric-aspire). For Fusion: "Use M6" plus "G28 Safe Retracts". Personal-use Fusion is limited to one tool change per file [C] — [Corbin's Treehouse Fusion](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-for-fusion-360/).
- **UCCNC**:
  - The M6 macro must be enabled in Settings, because the default does nothing [C] — [cncdrive forum](https://forum.cncdrive.com/viewtopic.php?p=33541).
  - UCCNC can be set to ignore M6 [C] — [cncdrive forum](https://forum.cncdrive.com/viewtopic.php?p=14596).
  - One post developer used M0 instead of M6 as a workaround [C] — [itch.io UCCNC post thread](https://itch.io/t/1838537/uccnc-post-processor).
- **Masso**: M06 tool change and M06.1 tool unload exist [V] — [Masso G04 page navigation](https://docs.masso.com.au/supported-g-codes/g04-dwell?ln=en). The form is "T… M06" [secondary] — [Sherline Masso codes](https://sherline.com/?p=64254).
- **Centroid CNC12**: M-functions have default actions and can be customised via macros [secondary] — [Centroid macro programming](https://www.scribd.com/document/756016457/centroid-cnc-macro-programming). On Acorn, M6 calls a tool-change macro [C] — [Corbin's Treehouse](https://www.corbinstreehouse.com/blog/wp-json/wp/v2/pages/8120).
- **PlanetCNC**: M6 behaviour is set by the user-editable `M6.gcode` script [secondary] — [PlanetCNC TNG GCode](https://www.scribd.com/document/605207632/PlanetCNC-TNG-GCode).
- **RichAuto/Axiom**: most RichAuto machines (Axiom and others) have only a collet and no ATC [C] — [Vectric forum](https://forum.vectric.com/viewtopic.php?p=190173).

### Inferences
- NativeCAM needs a per-controller **tool-change strategy enum**:
  - (a) emit `T<n> M6` and let the controller or sender handle it: Mach4/Avid, LinuxCNC, UCCNC (if enabled), Masso, CNC12, PlanetCNC, grblHAL (`$341`), gSender/CNCjs on GRBL, and Carbide Motion.
  - (b) emit `M5` + retract + `M0` + comment, for raw GRBL with dumb senders, UCCNC with M6 disabled, and FluidNC without a macro.
  - (c) **split into one file per tool**, for RichAuto/NcStudio DSPs, Easel, and as a universal fallback.
  - (d) emit nothing (single-tool jobs).
- Apply tool length offsets per family:
  - Emit `G43 H<n>` right after M6 for LinuxCNC/Mach4/CNC12 (and probably UCCNC/Masso [UNVERIFIED]).
  - **Never emit G43 H to GRBL or FluidNC**; it is rejected. TLO there is the sender's job (G43.1 inside its macro).
  - grblHAL accepts G43 only when configured, so don't rely on it.
- Raw GRBL streaming has a hazard. If a sender doesn't intercept M6, GRBL returns error 20 for that line and continues streaming the next tool's toolpath with the old bit. In character-counting mode the following buffered lines run regardless [V for the streaming behaviour, per [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md)]. This is why Carbide Create outputs M0 rather than M6 [C].
- For the user's Avid Mach4 machine (manual change + touch plate), the expected emission is `M5`, a safe Z (G53 G0 Z0 or the macro's own retract), `T<n> M6`, `G43 H<n>` (if the profile uses tool-table offsets), then `S… M3` and a dwell. Whether `G43 H` is needed depends on how the Avid M6 macro and touch-plate script set offsets, which is unverified (see Gaps).

### Gaps
- [UNVERIFIED] Avid's Mach4 profile M6 macro behaviour: retracts Z, stops the spindle, prompts, then optionally runs a touch-plate or tool-setter routine. Whether it sets a WCS Z or a tool table H offset decides whether G43 H must follow. Read the user's `Profiles/<AvidProfile>/Macros/m6.mcs`.
- [UNVERIFIED] UGS M6 handling: it is believed to have a "manual tool change" pause option in newer versions. Easel's handling of imported multi-tool G-code is also unknown.
- [UNVERIFIED] Buildbotics M6 executes a configurable "tool-change" G-code snippet, with a pause by default.
- Unknown-M-code behaviour for Mach3/Mach4/UCCNC/Masso/CNC12/PlanetCNC/RichAuto was not documented in fetched sources. [UNVERIFIED] Mach3 is believed to silently ignore unknown M-codes unless a macro file exists; Mach4 reports an error or ignores depending on version.

---

## Q4. Canned cycles (G81–G83) and G28/G30/G53 machine-coordinate moves and parking

### Takeaway
Canned cycles are **not available on GRBL 1.1 or FluidNC** (only G80 cancel). They are available on grblHAL, LinuxCNC, Mach4, Masso, and nominally Buildbotics (conflicting docs). Posts should expand drilling into G0/G1 moves for Grbl-family targets and unknown DSPs. G53 is widely supported but must be on a G0/G1 line. **G28 semantics differ**: in GRBL and LinuxCNC it goes to the stored G28.1 position, or to the machine origin in LinuxCNC if none is stored, *not necessarily* home.

### Cited Findings
- GRBL motion modes: G0, G1, G2, G3, G38.2–G38.5, G80 only. G28/G30, G28.1/G30.1 and G53 are non-modal [V] — [gnea/grbl README](https://github.com/gnea/grbl).
- GRBL error 30: G53 needs G0 or G1 active. Error 31: unused axis words while G80 is active [V] — [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).
- GRBL parking (`PARKING_ENABLE`) is disabled by default, with a target of −5 mm Z [V] — [config.h](https://github.com/gnea/grbl/blob/master/grbl/config.h).
- FluidNC has no G81–G83 cases (unsupported). It supports G28/G28.1, G30/G30.1, and G53 with G0/G1 or probe motion only [V] — [FluidNC GCode.cpp](https://github.com/bdring/FluidNC/blob/main/FluidNC/src/GCode.cpp).
- grblHAL: G73, G81, G82, G83, G85, G86, G89, G98, G99 are supported [V] — [grblHAL core README](https://github.com/grblHAL/core).
- LinuxCNC [V] — [LinuxCNC G-codes](https://linuxcnc.org/docs/html/gcode/g-code.html):
  - Canned cycles: G73, G74, G76, G81–G86, G89. G87/G88 are not implemented.
  - G98 returns to the prior Z if it is above R; G99 returns to R.
  - G28 rapids to the position stored in parameters 5161+. "If no positions are stored with G28.1 then all axes will go to the machine origin." G30 uses parameters 5181+.
  - "G53 is not modal and must be programmed on each line."
- Mach4: G73, G74, G76, G80–G89 and G98/G99, with some configuration-dependent. G28 is non-modal. G30 takes P2–P4 for the 2nd–4th reference point. G53 is non-modal [V-vendor] — [MachMotion Mach4 reference](https://support.machmotion.com/books/software/page/mach4-g-code-and-m-code-reference).
- Masso: G81, G82, G83, G28 ("return to machine home"), G30 ("move to parking position"), G53 [V] — [Masso docs navigation](https://docs.masso.com.au/supported-g-codes/g04-dwell?ln=en).
- CAMotics/Buildbotics: lists G73, G76, G80–G89, G98, G99 as supported, but the "Missing" section lists G73, G76, G83, G84, G87, G88 as not yet implemented [V for CAMotics; conflicting] — [CAMotics G-code](https://camotics.org/gcode.html).
- Carbide Motion: G54–G59 are accepted but ignored [V-snippet] — [Carbide 3D Hub FAQ](https://carbide3d.com/hub/faq/supported-gcodes).

### Inferences
- **Default to expanded drilling** (G0 to clearance, G1 plunge, peck retracts as G0/G1). Treat canned cycles as an opt-in per controller: LinuxCNC/PathPilot, Mach4, Masso, grblHAL, and probably UCCNC/CNC12/PlanetCNC.
- For end-of-program parking, `G53 G0 Z<top>` followed by `G53 G0 X.. Y..` is portable across GRBL, FluidNC, LinuxCNC, Mach4 and Masso. G28 is less portable because the stored-position semantics differ: Masso labels G28 as "return to machine home".
- Avoid G59.1–G59.3 for GRBL (error 29). FluidNC and LinuxCNC accept them.
- Carbide Motion ignores G54–G59 in the file, so a post for CM should not rely on WCS selection to place work.

### Gaps
- UCCNC, CNC12, PlanetCNC, RichAuto, NcStudio, ShopBot and Redline canned-cycle support was not confirmed. [UNVERIFIED] UCCNC and CNC12 support G73/G81–G89; RichAuto DSPs generally do not.
- Masso's G28/G30 parameter semantics (stored position vs fixed) were not read in detail.

---

## Q5. Spindle and accessories: S, M3/M4/M5, spin-up dwell (G4 seconds vs ms), coolant as dust/vacuum, laser modes

### Takeaway
**Dwell units are the most dangerous silent difference.**

| Controller | G4 P units |
|---|---|
| LinuxCNC | seconds |
| PlanetCNC | seconds (secondary source) |
| Masso | milliseconds |
| Mach3 | configurable |
| Mach4 | seconds per the official manual; ms-without-decimal per the MachMotion reference |
| GRBL family | seconds [UNVERIFIED] |

A spin-up dwell of `G4 P5` is 5 s on LinuxCNC but 5 ms on Masso. `G4 P5000` is 5 s on Masso but 83 minutes on LinuxCNC. Coolant mapping also differs: stock GRBL has only M8 (M7 is compiled out), which is why router posts tie dust collection to M8.

### Cited Findings
- **LinuxCNC**: G4 P is seconds, floating point. Negative or missing P is an error [V] — [LinuxCNC G-codes](https://linuxcnc.org/docs/html/gcode/g-code.html). M3/M4 run at S speed. M7 is mist (iocontrol.0.coolant-mist), M8 is flood, M9 turns both off. The coolant pins must be connected in HAL [V] — [LinuxCNC M-codes](https://linuxcnc.org/docs/html/gcode/m-code.html).
- **Masso**: "Dwell time in milliseconds". `N10 G04 P2000` pauses 2 seconds [V] — [Masso G04](https://docs.masso.com.au/supported-g-codes/g04-dwell?ln=en).
- **Mach4**:
  - The official Mill manual says P gives the dwell in seconds [V-snippet] — [Mach4 Mill GCode Manual PDF](https://www.machsupport.com/wp-content/uploads/2014/05/Mach4%20Mill%20GCode%20Manual.pdf).
  - The MachMotion Mach4 reference says "P in milliseconds with no decimal point". With a decimal, P is seconds ("G04 P5." = 5 s) [V-vendor] — [MachMotion Mach4 reference](https://support.machmotion.com/books/software/page/mach4-g-code-and-m-code-reference).
  - **These conflict.**
- **Mach3**: dwell units are seconds or milliseconds, chosen in configuration [C] — [mycncuk](https://www.mycncuk.com/threads/2968-G4-Dwell-parameters). A SheetCam post assumed seconds, causing problems on millisecond-configured machines [C] — [Langmuir forum](https://forum.langmuirsystems.com/t/mach3-pierce-delay-issue/3542/9).
- **PlanetCNC**: "G04 P – Delays execution for duration P seconds" [secondary] — [PlanetCNC TNG GCode (Scribd)](https://www.scribd.com/document/605207632/PlanetCNC-TNG-GCode).
- **Haas** (context only, not a router target): "G04 P10." is 10 s and "G04 P10" is 10 ms. This is the Fanuc-style decimal rule that MachMotion's Mach4 description mirrors [V, context] — [Haas G04](https://www.haascnc.com/service/codes-settings.type=gcode.machine=mill.value=G04.html).
- **GRBL**
  - Spindle M3, M4, M5. Coolant M7*, M8, M9 [V] — [README](https://github.com/gnea/grbl).
  - `ENABLE_M7` is disabled by default (the mist pin is optional) [V] — [config.h](https://github.com/gnea/grbl/blob/master/grbl/config.h).
  - A dwell with no P fails with "value word missing". P is passed straight to `mc_dwell` [V] — [gcode.c](https://github.com/gnea/grbl/blob/master/grbl/gcode.c).
  - Error 17: "Laser mode disabled. Requires PWM output" [V] — [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).
- **FluidNC**: M4 requires a reversible spindle or laser mode, otherwise it is unsupported. M7/M8 depend on the configured pins (`hasMist`/`hasFlood`). M62–M68 give digital and analog outputs [V] — [FluidNC GCode.cpp](https://github.com/bdring/FluidNC/blob/main/FluidNC/src/GCode.cpp).
- **grblHAL**: M62–M68 output control, dependent on the driver [V] — [grblHAL core README](https://github.com/grblHAL/core).
- **Carbide Motion**: lists M3 (and M0–M2); the snippet does not show M5, M7 or M8 [V-snippet] — [Carbide 3D Hub FAQ](https://carbide3d.com/hub/faq/supported-gcodes).
- **Onefinity Redline laser** (community): the Realtime RTSX post's M3/M5 around each power change stalled the laser; fixed by a corrected post [C] — [Onefinity forum](https://forum.onefinitycnc.com/t/redline-j-tech-laser-issue-solved-post-processor-issue/39509).

### Inferences
- NativeCAM must hold a **per-controller dwell unit** (seconds or ms) and a decimal-point policy:
  - For Mach4, emit P **with a decimal point**, for example `G4 P3.0`. Under both readings (official manual: seconds; MachMotion rule: decimal means seconds) this is 3 s, which resolves the conflict safely.
  - For Masso, emit an integer number of ms (`G4 P3000`).
  - For LinuxCNC, PlanetCNC and GRBL, emit seconds.
  - For Mach3, expose a user setting that mirrors their Mach3 config.
- For the dust collector or vacuum, map an "accessory on" event to M8 by default for GRBL-family targets, since M7 is compiled out on stock GRBL. Make it configurable (M7, M8, or M62 P<n> on FluidNC/grblHAL/LinuxCNC).
- For lasers on GRBL-family targets, M4 (dynamic power) needs laser mode, and FluidNC rejects M4 without a reversible spindle or laser. [UNVERIFIED] GRBL `$32=1` laser mode makes M4 scale power with speed and lets moves pass without stopping on S changes. Laser support is out of NativeCAM's 2.5D-router scope initially.

### Gaps
- GRBL, grblHAL and FluidNC G4 units are not confirmed by fetched docs (believed seconds, [UNVERIFIED]).
- UCCNC and CNC12 G4 units are unconfirmed.
- S-word ranges (RPM vs PWM 0–1000, and `$30`/`$31` on GRBL) were not researched in depth. [UNVERIFIED] GRBL maps S linearly between `$31` (min) and `$30` (max RPM). Mach4 and Avid map S directly to VFD RPM.
- Whether Carbide Motion honours M5/M8/M9 was not shown in the snippet.

---

## Q6. Units and modes, formatting: G20/G21, G17, G90/G91, G93/G94, N numbers, comments, line length, decimals, %, M2/M30, file extensions

### Takeaway
A safe common core is: G17, G20/G21, G90, G94, G0/G1/G2/G3 with incremental IJ, `( )` comments, no N numbers, 3–4 decimals, and M30 at the end. Line length is the binding limit for Grbl targets: **80 characters (GRBL default) and 127 (FluidNC)**, versus 256 for LinuxCNC. LinuxCNC requires `%` delimiters if there is no M2/M30.

### Cited Findings
- **GRBL**
  - Modal groups: G20/G21 (G21 default), G90/G91 (G90 default), G93/G94 (G94 default), G17 default [V] — [GRBL v1.1 Commands wiki](https://github.com/gnea/grbl/wiki/Grbl-v1.1-Commands).
  - Valid words: F, I, J, K, L, N, P, R, S, T, X, Y, Z [V] — [README](https://github.com/gnea/grbl).
  - N must be 1–9,999,999 (error 27) [V] — [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).
  - Error 11: line too long (`LINE_BUFFER_SIZE` 80 default) [V] — [config.h](https://github.com/gnea/grbl/blob/master/grbl/config.h).
  - Spaces and comments are removed by the pre-parser (stated for jog commands) [V] — [GRBL v1.1 Commands wiki](https://github.com/gnea/grbl/wiki/Grbl-v1.1-Commands).
- **FluidNC**: line limit 127 chars. The max line number constant is 10,000,000 [V] — [FluidNC GCode.cpp](https://github.com/bdring/FluidNC/blob/main/FluidNC/src/GCode.cpp).
- **LinuxCNC** [V] — [LinuxCNC overview](https://linuxcnc.org/docs/html/gcode/overview.html):
  - 256 characters max.
  - `( )` and `;` comments.
  - `%` is optional with M2/M30 and required otherwise; text after the second `%` is ignored.
  - Case-insensitive. Leading and trailing zeros are optional. An N word must be in the proper place.
  - `.ngc` is used in examples, not mandated.
  - G93 needs F on every G1/G2/G3 line [V] — [LinuxCNC G-codes](https://linuxcnc.org/docs/html/gcode/g-code.html).
- **Mach4**: comments are shown in parentheses. "The final block in a program is a program end code, most commonly M30" [V-vendor] — [MachMotion Mach4 reference](https://support.machmotion.com/books/software/page/mach4-g-code-and-m-code-reference).
- **CAMotics/Buildbotics**: `;` and `( )` comments, `(MSG,…)`, `(DEBUG,…)`, `(PRINT,…)`, and O-codes [V for CAMotics] — [CAMotics G-code](https://camotics.org/gcode.html).
- **File extensions seen in vendor posts and docs:**
  - Avid Mach4 `.tap`; Corbin advises against `.txt` [C] — [Corbin's Treehouse](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-setup-vectric-vcarve-vectric-aspire).
  - Avid EX/Centroid `.cnc` [C] — same.
  - Axiom/RichAuto `.mmg` [C] — [Vectric forum](https://forum.vectric.com/viewtopic.php?p=190173).
  - ShopBot accepts G-code as `*.gcc, *.tap, *.nc, *.agc`, with OpenSBP native [C, 2008] — [TalkShopBot](https://talkshopbot.com/forum/archive/index.php/t-9096.html).
  - Vectric "Mach2/3 (inch)" uses `.tap` [weak secondary] — [IndustrialMonitorDirect](https://industrialmonitordirect.com/blogs/knowledgebase/configuring-vcarve-pro-post-processor-for-mach3-cnc).
- **Axiom**: the controller reportedly "knows nothing about Imperial", so posts use mm [C] — [Vectric forum](https://forum.vectric.com/viewtopic.php?p=190173).
- **Carbide Motion**: G54–G59 are accepted but ignored [V-snippet] — [Carbide 3D Hub FAQ](https://carbide3d.com/hub/faq/supported-gcodes).
- **GRBL**: M2/M30 reset modal state [V] — [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).

### Inferences
- **Omit N numbers by default.** GRBL caps them, LinuxCNC discourages them, and they cost line length on 80-character GRBL.
- Keep lines short for GRBL: one motion per line, axis words only when they change, and no inline comments on motion lines.
- Use `( )` comments for maximum portability. LinuxCNC, CAMotics and Mach4 accept them. [UNVERIFIED] GRBL strips both `( )` and `;` comments. Strip comments entirely for RichAuto/NcStudio until confirmed.
- Emit `%` lines only for LinuxCNC-family targets when there is no M30. Since NativeCAM will always emit M30, `%` is unnecessary.
- Per-controller default extensions:

| Controller | Extension |
|---|---|
| GRBL / Carbide Motion / gSender | .nc or .gcode |
| Mach3 / Mach4 / Avid | .tap |
| LinuxCNC | .ngc |
| Centroid / Avid EX | .cnc |
| ShopBot | .sbp (or .nc G-code) |
| RichAuto / Axiom | .nc or .mmg |
| Masso | .nc [UNVERIFIED] |

### Gaps
- [UNVERIFIED] GRBL's handling of `%` lines is unknown; many senders strip them, so don't emit.
- Line length limits are unconfirmed for Mach3/4, UCCNC, Masso, CNC12, RichAuto and NcStudio.
- [UNVERIFIED] RichAuto file-size or memory limits, and whether it accepts comments and leading-zero formats such as `G00` vs `G0`.
- Carbide Motion's accepted extensions are unconfirmed. [UNVERIFIED] Carbide Create exports `.nc`.

---

## Q7. Things that commonly break

### Takeaway
The common failures are:
- On GRBL: unsupported words (error 20/36), over-long lines (error 11), arc radius mismatch (error 33), M6 on raw GRBL, G43 H or G64 in safety lines, and G59.x (error 29).
- On PC controls: dwell-unit mismatches (Masso ms vs seconds elsewhere) and IJ-mode mismatches (Mach3 setting).
- On DSPs and proprietary controls: anything beyond basic G0/G1/G2/G3 (comments, inch units on Axiom, tool changes).
- On Carbide Motion: G54–G59 silently ignored.

### Cited Findings
- **GRBL error behaviour**: an errored block is purged and not executed. During character-counting streaming, lines already in the RX buffer keep executing after an error, and the GUI cannot stop them; use `$C` check mode [V] — [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).
- **GRBL errors most relevant to posts** [V] — [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md):
  - 11: line too long. 20: unsupported command (M6, G64, G90.1, G81, G43 H). 21: modal group conflict.
  - 22: no feed rate. 24/25: duplicate or conflicting words. 26: missing axis words.
  - 29: G59.x. 30: G53 without G0/G1. 33: arc tolerance. 34: R arc geometry.
  - **36: leftover unused words**, for example an I/J on a G1 line or a stray H.
  - 38: T > 255.
- **GRBL planner**: 16 blocks look-ahead and a 128-byte RX buffer [V] — [interface.md](https://github.com/gnea/grbl/blob/master/doc/markdown/interface.md).
- **Masso ms dwell** vs **LinuxCNC seconds dwell** [V] — [Masso G04](https://docs.masso.com.au/supported-g-codes/g04-dwell?ln=en); [LinuxCNC G-codes](https://linuxcnc.org/docs/html/gcode/g-code.html).
- **Mach3 dwell-unit misconfiguration** caused pierce-delay errors with a seconds-based post [C] — [Langmuir forum](https://forum.langmuirsystems.com/t/mach3-pierce-delay-issue/3542/9).
- **ShopBot**: SB3 reportedly "cannot handle a feedrate that changes all the time" [secondary] — [DeskProto ShopBot tips](https://www.deskproto.com/support-tips-tricks/dp-tips-shopbot.php). ShopBot "does not recognize all the g-code commands" CAM emits [C] — [TalkShopBot](https://talkshopbot.com/forum/archive/index.php/t-9096.html).
- **Redline laser**: M3/M5 per power change breaks laser motion [C] — [Onefinity forum](https://forum.onefinitycnc.com/t/redline-j-tech-laser-issue-solved-post-processor-issue/39509).
- **gSender Fixed Tool Sensor** causes soft-limit alarms on resume [C] — [Sienci forum](https://forum.sienci.com/t/fixed-location-tool-change-issue-soft-limits/9421).
- **Carbide Motion ignores G54–G59** in files [V-snippet] — [Carbide 3D Hub FAQ](https://carbide3d.com/hub/faq/supported-gcodes).
- **Mach4 → Centroid migration** on Avid: the touch-plate sequence differs and the bit wanders off the piece [C] — [Avid forum](https://forum.avidcnc.com/t/migrating-challenge-from-mach4-to-ex-controller/3891).
- **Free Fusion** limits tool changes (one per file), pushing users to split files [C] — [Corbin's Treehouse Fusion](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-for-fusion-360/).

### Inferences
- Build a **post-time validator** per controller profile: max line length, allowed G/M/word set, dwell unit, and IJ mode. Run it on emitted output, mirroring GRBL's `$C` check, so incompatible files are caught before they reach the machine. GRBL's error list gives a ready-made rule set.
- Never put I/J/K/R on non-arc lines, and never put H on non-G43 lines. This avoids GRBL error 36.
- Always output an F word before the first G1/G2/G3 (GRBL error 22), and after any switch to G93.

### Gaps
- No fetched source documents RichAuto/NcStudio error behaviour or memory limits, or UCCNC/Masso/CNC12 unknown-word behaviour.

---

## Q8. How CAM vendors differ in their posts for the same controller (example post names)

### Takeaway
The same controller often has several posts that differ in arcs (on or off), tool change (M6 vs M0 vs none), TLO (G43 H vs none) and units. Fusion's library has controller-named posts (Grbl, Carbide 3D (Grbl), Mach4Mill, Avid CNC, LinuxCNC (EMC2), MASSO, CENTROID, PlanetCNC, UCCNC, ShopBot OpenSBP, RichAuto DSP, NcStudio, Onefinity BB Buildbotics/Masso). Vectric ships vendor-named posts (Avid CNC (inch) (*.tap), Axiom HHC CNC (mm) (*.mmg), Onefinity Redline/Realtime). Carbide Create embeds its own GRBL output with M0-style tool changes.

### Cited Findings
- **Fusion library display names** [V] — [Fusion Post Library reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm):

| Controller | Fusion library post names |
|---|---|
| Grbl | "Grbl", "Grbl Laser", "Grbl Turning" |
| Carbide 3D | "Carbide 3D (Grbl)" |
| Onefinity | "Onefinity BB Buildbotics", "Onefinity Masso" |
| Buildbotics | "Buildbotics 4-Axis CNC Controller" |
| Mach3 | "Mach3Mill", "CNC Router Parts (Mach3Mill)" |
| Mach4 | "Mach4Mill" |
| Avid | "Avid CNC", "Avid CNC Plasma" |
| LinuxCNC | "LinuxCNC (EMC2)", "Enhanced Machine Controller (EMC)" |
| Tormach | "Tormach PathPilot" |
| UCCNC | "UCCNC", "STEPCRAFT UCCNC" |
| Masso | "MASSO", "Masso Plasma" |
| Centroid | "CENTROID" |
| PlanetCNC | "PlanetCNC" |
| ShopBot | "ShopBot OpenSBP" |
| RichAuto | "RichAuto DSP" |
| NcStudio | "NcStudio Programming System" |
| Inventables | "X-Carve by Inventables", "Easel by Inventables" |

  The library has **no grblHAL, FluidNC or Sienci-named entries**.
- **Vectric / Avid**:
  - The stock "Avid CNC (inch) (*.tap)" post ships with VCarve 11+. For ATC, it had to be edited to add `T[T]M6` and `G43 H[T]` ("The one provided by Avid is not right!").
  - Centroid/EX uses a separate "Avid EX Control ATC (Inch) (*.cnc)" post [C] — [Corbin's Treehouse](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-setup-vectric-vcarve-vectric-aspire).
  - Vectric docs example: `AvidCNC_WrapX2A_G93_inch.pp` (rotary wrap with inverse-time G93) [V] — [Vectric post-processor editing](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html).
- **Fusion / Avid**: "Use M6" and "G28 Safe Retracts" properties [C] — [Corbin's Treehouse Fusion](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-for-fusion-360/). Community-enhanced Avid Fusion post [C] — [Avid forum](https://forum.avidcnc.com/t/enhanced-avid-post-processor-for-fusion-360/5049). "Avid CNC EX Router V2.cps" for Centroid [C] — [Avid forum](https://forum.avidcnc.com/t/centroid-feature-request-issues/3755).
- **Vectric / Onefinity Redline**: "Onefinity Redline/Realtime (inch)/(mm)" from the Vectric cloud database [V] — [Onefinity Vectric Redline guide](https://www.onefinitycnc.com/post/setup-a-post-processor-exporting-gcode-for-vectric-with-the-redline-motion-control-system). RealTime CNC also publishes Vectric, Fusion, Carveco and FreeCAD posts (versions dated Apr–May 2026) [V] — [realtimecnc.com/postp](https://realtimecnc.com/postp/). A "Realtime RTSX" post has the laser M3/M5 issue [C] — [Onefinity forum](https://forum.onefinitycnc.com/t/redline-j-tech-laser-issue-solved-post-processor-issue/39509).
- **Vectric / Axiom (RichAuto)**: "Axiom HHC CNC (mm) (*.mmg)" [C] — [Vectric forum](https://forum.vectric.com/viewtopic.php?p=190173).
- **Vectric / Mach3**: "Mach2/3 (inch)" and "Mach2/3 (mm)", both `.tap` [weak secondary] — [IndustrialMonitorDirect](https://industrialmonitordirect.com/blogs/knowledgebase/configuring-vcarve-pro-post-processor-for-mach3-cnc).
- **Carbide Create → GRBL**: tool changes emitted as `M0 ;T302`, with no M6 (community report) [C] — [Onefinity forum](https://forum.onefinitycnc.com/t/gcode-where-is-m6-tool-change/14739). A related thread title shows users seeking a "Carbide Create Pro Post Processor for Onefinity (M6 Tool Change)" [C] — [Onefinity forum](https://forum.onefinitycnc.com/t/carbide-create-pro-post-processor-for-onefinity-m6-tool-change/37317).
- **Carveco / Avid EX**: users note Avid had updated posts for Vectric and Fusion. One user tried a "basic G code mm (tap*)" post [C] — [Carveco community](https://support.carveco.com/hc/en-gb/community/posts/16130145812892/comments/16138649565852).

### Inferences
- The axes along which vendor posts for the same controller differ are:
  1. arcs emitted or linearised;
  2. tool-change form (`T M6` / `M0` / split files / none);
  3. TLO line (`G43 H` / none);
  4. dwell after M3 (present or absent, and its units);
  5. units and extension;
  6. safe-retract style (G28 vs G53 Z).
  
  NativeCAM's controller profiles should expose exactly these as settings, defaulting to what the vendor-blessed post does.
- Fusion, a large vendor, ships controller-named posts for nearly every target here except grblHAL and FluidNC. Users of those two typically fall back to the "Grbl" post, so NativeCAM's GRBL profile should be conservative enough for both.

### Gaps
- The exact Vectric names of the stock GRBL posts, and whether they linearise arcs, are unconfirmed. [UNVERIFIED] "Grbl (mm) (*.gcode)", "Grbl Arcs (mm) (*.gcode)", "Grbl (inch)…", and Sienci/gSender-specific Vectric posts.
- The Sienci post-processor page (resources.sienci.com/view/cnc-post-processors) returned 403, so the names of Sienci's recommended posts are not captured.
- Carbide Create's current (v7/v8) tool-change output was not verified against a primary source.
- The output blocks of the RealTime Redline posts were not inspected (they would reveal the Redline dialect).
