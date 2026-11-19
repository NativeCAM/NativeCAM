# Machine-description and post-processor file formats (CAM programs and CNC controllers) — import options for NativeCAM

Research date: 2026-11-19. Verification method: vendor docs (docs.vectric.com, help.autodesk.com, cam.autodesk.com, linuxcnc.org, GRBL/grblHAL wikis, docs.masso.com.au, docs.grid.space) plus reading the source files on GitHub directly through the GitHub API (Kiri:Moto profiles and LICENSE, Autodesk's own `cam-posteditor` repo with sample `.mch`/`.cps`, FreeCAD main branch, FluidNC configs, a real Avid Mach4 `Machine.ini`, a Mach3 XML profile, CamBam `.cbpp`, Vectric `.pp`). Field names below are quoted only as short identifiers.

## 1. Vectric post processors (.pp) — VCarve / Aspire / Cut2D

### Takeaway
A Vectric `.pp` is a plain-text, declarative template file: global settings (POST_NAME, FILE_EXTENSION, UNITS, LINE_ENDING...), `VAR` lines that set how each value is formatted, and `begin <BLOCK>` sections holding quoted G-code lines with bracketed tokens such as `[X]` `[F]` `[S]` `[T]`. There is no scripting, so a parser plus template engine is a small job. These files are the most widely distributed "post" for hobby and prosumer routers, because Vectric bundles posts for most vendors and vendors also publish their own. They hold output-format information only: no travel, feed-rate or acceleration limits.

### Cited Findings
**Official documentation.** The editing guide is part of Vectric's online help ("15. Advanced - Post-Processor Editing", V12.5). Older PDF copies, such as the "Guide to editing a Vectric Post Processor" v1.3.0 from June 2018, circulate only as unofficial uploads. — [Vectric V12.5 docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html); [Scribd copy](https://www.scribd.com/document/481924679/Post-Processor-Guide)

**Lexical rules.** Lines starting with `+` or `|` are comments. Global statements are written in upper case as `NAME = value`. Output lines are double-quoted strings inside `begin BLOCK` sections. Special characters are escaped as decimal ASCII in brackets, e.g. `[13][10]`, `[34]`, `[91]`. On a syntax error the software reports the line number at startup and leaves that post out of the list. — [Vectric V12.5 docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html)

**Global statements documented in V12.5:**
- Identity and units: POST_NAME, FILE_EXTENSION, UNITS (`MM` or `INCHES`).
- Output channel: DIRECT_OUTPUT (sends to a controller's document interface) and PRINT_DIRECT.
- Rotary: RAPID_PLUNGE_TO_STARTZ, ROTARY_WRAP_X / ROTARY_WRAP_Y, INVERSE_TIME_MODE, MAXIMUM_ROTATION.
- Spindle: SPINDLE_SPEED_RANGE, which maps RPM onto integer codes.
- Character handling: SUBSTITUTE (swap characters).
- Feature flags: LASER_SUPPORT.
- Arcs: MIN_ARC_RADIUS / MAX_ARC_RADIUS. Arcs outside the range are output as lines.
- Move splitting: MAXIMUM_LENGTH (splits long lines), TAPE_SPLITTING (splits long files).
- Rapids: RAPID_SPEED (a fixed feed for rapids emitted as feed moves).
- Segment control: FIRST_TOOLPATH_NEW_SEGMENT.
- Line format: LINE_ENDING, LINE_NUMBER_START / _INCREMENT / _MAXIMUM.
- Inheritance: POST_BASE is "no longer supported". There is a migration page.

Source: [Vectric V12.5 docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html)

**Variable formatting.** The form is `VAR NAME = [label|when|prefix|format|multiplier]`:
- `when` is `A` (always output) or `C` (only when the value changes).
- `format` holds flags, field width, decimal separator and decimal places. The flags are `-` (left justify), `+` (always show sign), `0` (zero pad) and `#` (always show the decimal point).
- `multiplier` is optional, e.g. 0.01666 to turn per-minute into per-second, or -1 to flip a sign.
- Example: `VAR X_POSITION = [X|C|X|1.4]`.

Source: [Vectric V12.5 docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html); [sample Grbl_mm.pp](https://github.com/fellesverkstedet/fabricatable-machines/blob/HEAD/humphrey-large-format-cnc/Settings_backup/backup/Grbl_mm.pp)

**Tokens available in output lines:**
- Feeds, speeds and tools: `[F] [FC] [FP] [S] [P] [T] [TP] [TOOLNAME] [TDIA] [N] [DWELL] [FI]`.
- Positions: `[X] [Y] [Z] [A]`, home `[XH] [YH] [ZH]`, safe Z `[SAFEZ]`, wrap diameter `[WRAP_DIA]`.
- Arcs: incremental centre `[I] [J]`, absolute centre `[IA] [JA]`, start point `[ArcStartX]`, mid-point `[ArcMidX]`, plus `[Radius]` and `[Angle]`.
- Material block: `[XLENGTH] [XMIN] [XMAX]` and the Y/Z equivalents, `[X_ORIGIN_POS]`, `[Z_ORIGIN]`, `[XY_ORIGIN]`.
- File and job metadata: `[TOOLPATH_NAME] [TP_FILENAME] [PATHNAME] [TOOLS_USED] [FILE_NOTES] [DATE] [TIME] [PRODUCT]`.
- Drill banks: `[DB] [DL] [CD]`.
- Cutter compensation: `[CUTTER_COMP]`.

Source: [Vectric V12.5 docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html)

**Block names.** The block names in the task brief are slightly off: Vectric uses `RAPID_MOVE` (not RAPID_RATE_MOVE) and `CW_ARC_MOVE` / `CCW_ARC_MOVE` (not CW_ARC / CCW_ARC). The documented blocks are:
- Program structure: HEADER, SPINDLE_ON, TOOLCHANGE, NEW_SEGMENT, FOOTER.
- Rapids: INITIAL_RAPID_MOVE, RAPID_MOVE, and the keep-out-zone set INITIAL_ / FIRST_ / STRAIGHT_RAPID_MOVE.
- Feed moves: FIRST_FEED_MOVE, FEED_MOVE, FEED_RATE_CHANGE, FIRST_PLUNGE_MOVE, PLUNGE_MOVE, RETRACT_MOVE, DWELL_MOVE.
- Arcs: FIRST_CW_ARC_MOVE, CW_ARC_MOVE, FIRST_CCW_ARC_MOVE, CCW_ARC_MOVE.
- Helical arcs: CW/CCW_HELICAL_ARC_MOVE, their FIRST_ variants, and FIRST_..._HELICAL_ARC_PLUNGE_MOVE.
- Laser and other "jet" tools: JET_TOOL_ON / OFF / POWER.
- Drill banks: SETUP_DRILL_BANK, DRILL_BANK_PATTERN, DRILL_BANK_EXTEND_DRILL / RETRACT_DRILL, FINAL_DRILL_BANK_ACTION.
- Cutter compensation: CUTTER_COMP_LEFT / RIGHT / OFF.

The V12.5 page itself contains a few typos, e.g. "FIRST_CW _HELICAL_ARC_MOVE", and FINAL_DRILL_BANK_ACTION also appears as DRILL_BANK_FINAL_ACTION. — [Vectric V12.5 docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html)

**Arc output style.** A post chooses its arc style by which tokens it uses: incremental IJ, absolute IJ, or R. A post with no arc blocks gets linearised arcs. For example, Vectric's own Grbl_mm.pp has its arc blocks commented out. Its history notes say arcs were disabled because they "slow GRBL performance". — [sample Grbl_mm.pp](https://github.com/fellesverkstedet/fabricatable-machines/blob/HEAD/humphrey-large-format-cnc/Settings_backup/backup/Grbl_mm.pp)

**Representative excerpt (field names only):**
- `POST_NAME = "Grbl (mm) (*.gcode)"`, `FILE_EXTENSION = "gcode"`, `UNITS = "MM"`
- `begin HEADER` followed by lines such as `"G0[XH][YH][S]M3"`
- `begin FEED_MOVE` followed by `"G1[X][Y][Z]"`

Source: [sample Grbl_mm.pp](https://github.com/fellesverkstedet/fabricatable-machines/blob/HEAD/humphrey-large-format-cnc/Settings_backup/backup/Grbl_mm.pp)

**Version differences.** A developer notes that V11 and V12 posts have extra commands and variables that do not exist in V9. — [Carbide 3D community](https://community.carbide3d.com/t/new-post-processor-for-vectric-software/77335?page=3)

**Where the files live:**
- V5.5 and later: File > Open Application Data Folder > `PostP` holds the stock posts.
- Custom posts go in `My_PostP`. If any `.pp` file is present there, only those posts are listed.
- Older versions kept `PostP` in the program installation directory.

Source: [Vectric V12.5 docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html)

**V12 Post-Processor Management dialog:**
- Lists the posts that Vectric "provides and maintains".
- Each post offers View, Changelog and Customize. Customize creates an editable copy in `My_PostP`.
- Posts can be installed from a file.
- "Update Post-Processor List" fetches the current Vectric-maintained list from the cloud, but needs a V&Co account login.
- A post version can be locked per machine.

Source: [Vectric V12 PP Management](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/form/post-processor-management/index.html)

**Bundled and vendor posts:**
- Cut2D, VCarve and Aspire all ship the same selection of posts. — [Vectric Zendesk (snippet only; page returned 403)](https://vectric.zendesk.com/hc/en-us/articles/30726110295581-Post-Processor)
- Carbide 3D machines have been included since v8.5. — [Carbide 3D community](https://community.carbide3d.com/t/new-post-processor-for-vectric-software/77335?page=3)
- Onefinity says its machines and posts are included from V11. — [Onefinity forum](https://forum.onefinitycnc.com/t/vectric-post-processors-for-10-5-or-older-versions-download-links-included/640/1)
- MASSO publishes Vectric posts for V11 and later, installed through Post-Processor Management. — [MASSO docs](https://docs.masso.com.au/cam-post-processors/vectric-vcarve-and-vectric-aspire)
- Next Wave Automation publishes a compatibility list. — [Next Wave](https://nextwaveautomation.zendesk.com/hc/en-us/articles/360046235651)
- An Avid CNC post is bundled with VCarve 11+. A blogger says the file Avid itself supplied was "not right" and recommends Vectric's Avid post, or the Centroid post for CNC12 users. — [corbinstreehouse blog](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-setup-vectric-vcarve-vectric-aspire)
- An Avid forum user says Avid's website download is only needed if the post is missing from VCarve. — [Avid forum](https://forum.avidcnc.com/t/rhinocam-fusion-360-post-processors/4351)

**`.pp` files on GitHub:**
- Synthetos g2core ships 10 VCarve posts. — [synthetos/g2](https://github.com/synthetos/g2/tree/HEAD/Resources/Post-Processors/VCarve)
- Snapmaker publishes VCarve and Aspire posts. — [Snapmaker repo](https://github.com/Snapmaker/snapmaker_cnc_post_process)
- Handibot/ShopBot posts. — [Handibot repo](https://github.com/Handibot/handibot-hardware)
- Community GRBL tool-change posts. — [neilferreri/V-Carve-PPs](https://github.com/neilferreri/V-Carve-PPs)

**Licensing.** The Vectric-authored sample post examined has a history header but no copyright or licence statement. — [sample Grbl_mm.pp](https://github.com/fellesverkstedet/fabricatable-machines/blob/HEAD/humphrey-large-format-cnc/Settings_backup/backup/Grbl_mm.pp)

### Inferences
- The format is regular enough for a full parser in a few hundred lines of Swift: a line lexer, `VAR` format specs, block-to-line templates, and token substitution with printf-style formatting. Mapping it onto a template-based post engine is natural, because NativeCAM's motion events (rapid, first feed, feed, plunge, CW/CCW arc, helical, tool change, header/footer) map almost one-to-one onto the blocks.
- Supporting `.pp` import would let users take any post their machine vendor or Vectric publishes. Feature coverage needs to include the `FIRST_*` block variants and the "only when changed" modal logic.
- Licensing is unclear: posts shipped inside Vectric's installer are probably covered by Vectric's EULA. NativeCAM should let users import their own `.pp` files, not redistribute Vectric's bundled set.

### Gaps
- No official count of bundled posts was found. The Vectric Zendesk article returned HTTP 403, and no reliable "N posts" figure came up.
- No explicit licence was found for Vectric's bundled posts or for most vendor-published posts.
- The official PDF guide is not on vectric.com, only on unofficial Scribd copies.
- Avid CNC's own post download page was not retrieved directly.
- The exact default Windows path for V12 posts was not confirmed. One search result mentioned a V8-era path (`C:\ProgramData\Vectric\VCarve Pro\V8.0\PostP`), but its source could not be pinned down. Use File > Open Application Data Folder as the authoritative route.

## 2. Vectric "Machine Configuration" (V11/V12 and later)

### Takeaway
Vectric's Machine Configuration links a named machine to one or more posts, with optional version pinning and a default post. It also holds per-axis acceleration used for run-time estimates and a per-machine set of tool cutting data. It is not a documented, standalone, user-exportable file. Machine "packages" are delivered through a V&Co account, and the tool and machine data appear to live in Vectric's SQLite tool database (`.vtdb`).

### Cited Findings
**What a Machine Configuration stores:**
- A name, which must be unique.
- XYZ acceleration, entered in one of six unit options (mm/s², in/s², mm/min², in/min², m/min², ft/min²).
- Rotary acceleration in deg/s² or rad/s².
- Associated post-processors, each set to "Latest" or a pinned version, with one marked as the default for toolpath saving.
- Per-tool cutting data (feeds and speeds) for each machine.

The dialog is opened from the Machines menu, the Tool Database, Toolpath Saving, and the "Estimating Machining Time" form. Packages can be installed with "Install Offline Package" or "Search Machine Online"; they carry pre-associated posts and starter feeds and speeds. No manual export is described. — [Vectric V12.5 Machine Configuration Management](https://docs.vectric.com/docs/V12.5/Cut2DPro/ENU/Help/form/tool-database-machine-management/index.html)

**Tool database format and location:**
- Vectric's tool database uses a custom SQLite-based format with the extension `.vtdb`; the older format was `.tool`. — [Carbide 3D community](https://community.carbide3d.com/t/c3d-tool-database/92817)
- A cross-platform converter from `.vtdb` to JSON is posted on the LightBurn forum. — [LightBurn forum](https://forum.lightburnsoftware.com/t/cross-platform-vectric-to-millmage-tool-database-converter/193422.md)
- The database is reachable via File > Open Application Data Folder > ToolDatabase. — [Vectric V9 FAQ](https://docs.vectric.com/docs/V9.0/VCarveDesktop/ENU/Help/Interface\FAQ\Frequently%20Asked%20Questions.html)
- Users report it under `C:\ProgramData\Vectric`. — [Sienci forum](https://forum.sienci.com/t/vcarve-pro-tool-database/8282)

### Inferences
- The only machine "limit" Vectric stores is acceleration, for time estimates. Bed size is set per job, not per machine; the docs page does not list machine dimensions.
- Importing Vectric machine configurations would mean reverse-engineering an SQLite schema that changes between versions. That is poor value compared with importing the `.pp` file.

### Gaps
- Vectric does not document where machine configurations are stored, or whether bed size, rapid rates or ATC slots are part of them.
- A forum claim that build 12.508 changed the tool database format, so that files would not open in 12.507 and earlier, could not be traced to a confirmable source.

## 3. Autodesk Fusion: machine definitions (.mch) and post processors (.cps)

### Takeaway
A Fusion machine definition (`.mch`) is a JSON document. It holds:
- a kinematic tree with per-axis travel limits
- per-axis maximum feed and rapid speeds
- the spindle RPM range
- tool-changer facts and tool-change time
- the linked post

It is fairly easy to parse, and Autodesk's MIT-licensed `cam-posteditor` repo includes 45 sample `.mch` files. Fusion posts (`.cps`) are JavaScript programs written against Autodesk's proprietary post-engine API. Autodesk's post library is governed by the Autodesk License and Services Agreement and described as compatible only with Fusion, HSMWorks and Inventor CAM. Executing `.cps` files in a third-party app is therefore both a heavy engineering job and legally risky. Reading a handful of declarative header variables from a user's own `.cps` file is feasible.

### Cited Findings
**`.mch` structure.** Read from Autodesk's "Generic 3-axis Router" sample:
- Top-level keys: `general`, `kinematics`, `controller`, `machining`, `tooling`, `post`, `fusion`, `interactions`.
- `general` holds vendor, model, description and minimumRevision.
- `kinematics.default` holds `units` (length in mm, angles in degrees) and a nested `parts` tree. Each linear axis has `id`, `direction`, `min` and `max`; the sample uses X ±1000 and Z −220..0. The head part carries `spindle` with `max_speed`/`min_speed` (24000/0) and a `tool_station` listing coolant types.
- `controller.synced_configuration.parts.<axis>` holds `max_normal_speed` and `max_rapid_speed`; both are 0 (unset) in the generic sample.
- `machining.default` holds `feedrate_ratio` and `tool_change_time` (15).
- `tooling.default` holds `has_tool_changer`, `number_of_tools` and `supports_tool_preload`.
- `post.default.path` points at a `.cps` file.

Source: [Autodesk/cam-posteditor generic router .mch](https://github.com/Autodesk/cam-posteditor/blob/HEAD/vs-code-extension/res/Machines/Milling/autodesk%20generic%20router%20xyz.mch)

**No acceleration field.** A search for acceleration or jerk keys across the milling `.mch` samples in that repo found none. — [Autodesk/cam-posteditor Machines folder](https://github.com/Autodesk/cam-posteditor/tree/HEAD/vs-code-extension/res/Machines)

**Licence and contents of `cam-posteditor`.** The repo is MIT-licensed: "Copyright (c) 2017 by Autodesk, Inc." It contains 45 `.mch` files (milling, additive and others). Its bundled `public/fanuc.cps` still carries the header "Copyright (C) 2012-2021 by Autodesk, Inc. All rights reserved." That is a mixed signal; see Inferences. — [Autodesk/cam-posteditor](https://github.com/Autodesk/cam-posteditor); [LICENSE.txt](https://github.com/Autodesk/cam-posteditor/blob/HEAD/LICENSE.txt); [fanuc.cps](https://github.com/Autodesk/cam-posteditor/blob/HEAD/public/fanuc.cps)

**`.cps` structure:**
- Global declarative variables: `description`, `vendor`, `legal`, `certificationLevel`, `minimumRevision`, `extension`, `capabilities`, `tolerance`.
- Arc settings: `minimumChordLength`, `minimumCircularRadius` / `maximumCircularRadius`, `minimumCircularSweep` / `maximumCircularSweep`, `allowHelicalMoves`, `allowedCircularPlanes`.
- Rapid substitution: `highFeedrate`.
- Entry functions called by Autodesk's engine: `onOpen`, `onSection`, `onRapid`, `onLinear`, `onCircular`, `onCycle`, `onCyclePoint`, `onSectionEnd`, `onClose`, and others.

Source: [fanuc.cps in Autodesk repo](https://github.com/Autodesk/cam-posteditor/blob/HEAD/public/fanuc.cps); [Autodesk post reference: entry functions](https://cam.autodesk.com/posts/reference/entry_functions.html)

**Post library terms.** Autodesk's post library page says use of any post is "governed by the Autodesk License and Services Agreement". It also says the posts are "only compatible with our products Fusion, HSMWorks and Inventor CAM". — [cam.autodesk.com/hsmposts](https://cam.autodesk.com/hsmposts)

**Machine library.** The Machine Library has Fusion Library and My Machines folders, with Cloud and Linked subfolders under My Machines. Definitions can be imported into, and exported from, My Machines with "Export Selected". A machine *model* (a 3D design) can be linked to a definition. — [Fusion help: Machine Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINE-LIBRARY-SELECTION.htm); [Fusion help: Machines](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINES.htm)

**Where posts live:**
- Windows personal posts: `C:\Users\<name>\AppData\Roaming\Autodesk\Fusion CAM\Posts`, per Autodesk help as summarised in search results. — [Fusion help: Manage the Post Library](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-ADD-POST-PROCESSOR-TO-LIBRARY.htm)
- macOS personal posts: `~/Autodesk/Fusion 360 CAM/Posts`, per forum consensus. — [Autodesk forum](https://forums.autodesk.com/t5/fusion-360-manufacture/where-are-the-cps-files-located-on-a-mac/td-p/5762926)
- Cloud posts: Assets > CAMPosts in the Data Panel. — [Autodesk support](https://autodesk.com/support/technical/article/How-to-install-a-cloud-post-in-Fusion-360)

**Vendor-published Fusion files:**
- Tormach publishes Fusion machine definition files, e.g. for the xsTECH router. — [Tormach wiki](https://tormach.atlassian.net/wiki/spaces/XST/pages/1965883568)
- Onefinity publishes a Fusion post and machine. — [Onefinity forum](https://forum.onefinitycnc.com/t/fusion-360-information/10846)

**No converter.** Users have asked for a way to generate a `.cps` from a vendor `.pp`, because some router makers ship only `.pp` files. No tool was offered. — [Autodesk forum idea](https://forums.autodesk.com/t5/hsm-post-processor-ideas/generating-cps-post-processing-file-form-a-pp-file/m-p/11875449)

**Clean-room reimplementation.** An Apache-2.0 "clean room" CAM project, Camcraft, ships its own `.mch`-like JSON machine files with Fusion-style key names (e.g. `max_rapid_speed`). — [NeoTech/Camcraft](https://github.com/NeoTech/Camcraft)

### Inferences
- **Importing `.mch`:** low-to-moderate effort for real value — travel envelope, per-axis feed and rapid caps, spindle range, ATC flag and tool count, and tool-change time (useful for run-time estimates). Users can export their own machine from Fusion. Shipping Autodesk's library machines inside NativeCAM is a separate licensing question. The MIT licence on the sample repo is encouraging but covers only that repo.
- **`.cps`:** do not execute. Reimplementing Autodesk's JavaScript post runtime (format and variable objects, `writeBlock`, section and cycle semantics) is a large job, and the posts' licence terms tie them to Autodesk products.
- **Light extraction from `.cps`:** regex extraction of `extension`, `tolerance`, `maximumCircularSweep`, `allowHelicalMoves` and `highFeedrate` from a user's own file is cheap and legally benign. PureCutCNC does something similar (see Q7).

### Gaps
- No formal `.mch` schema document from Autodesk was found.
- The local on-disk folder for machine definitions on macOS/Windows was not confirmed.
- Whether newer Fusion releases add acceleration or time-estimation fields beyond `feedrate_ratio` and `tool_change_time` was not confirmed.
- The total number of posts and machines in Autodesk's libraries was not obtained.

## 4. Kiri:Moto (GridSpace grid-apps) CNC device profiles

### Takeaway
Kiri:Moto CNC profiles are small JSON files in `src/kiri/dev/cam/`, 28 of them as of 2026-11-19, including 3 generic ones. They contain:
- bed width, depth and height
- maximum spindle RPM
- file extension
- header, footer, tool-change, dwell and spindle G-code templates with `{token}` placeholders
- a few dialect flags

The repo is MIT-licensed, so the profiles can be bundled directly. They contain no feed, rapid or acceleration limits.

### Cited Findings
**Licence.** The licence file (`license.md`) is MIT, per both the GitHub API and the file text. — [GridSpace/grid-apps](https://github.com/GridSpace/grid-apps); [license.md](https://github.com/GridSpace/grid-apps/blob/master/license.md)

**The 28 CNC profiles:**
- Generic: Any.Generic.Grbl, Any.Generic.LinuxCNC, Any.Generic.TinyG.
- Carbide3D: Nomad 883 Pro, Shapeoko 3, XL, XXL.
- Genmitsu: 3018, PROVerXL 4030.
- Inventables: Carvey, X-Carve 500/1000 mm.
- Makera: Carvera, Carvera Air.
- Sienci: AltMill, LongMill, LongMill MK2, Mill One.
- Others: Langmuir MR-1, PrintNC GrblHAL, RatRig StrongHold ONE, Roland MDX-50, ShopBot Basic, Snapmaker Original, Techno Davinci, Tormach 24R, V1Engineering Lowrider3 and MPCNC.

Source: [grid-apps src/kiri/dev/cam](https://github.com/GridSpace/grid-apps/tree/master/src/kiri/dev/cam)

**Two JSON encodings coexist:**
- Legacy keys: `file-ext`, `token-space`, `strip-comments`, `pre`, `post`, `tool-change`, `dwell`, `spindle`, plus `settings.bed_width` / `bed_depth` / `build_height`.
- Newer, already converted keys: `bedWidth`, `bedDepth`, `maxHeight`, `spindleMax`, `originCenter`, `gcodePre`, `gcodePost`, `gcodeChange`, `gcodeDwell`, `gcodeSpindle`, `gcodeResetA`, `gcodeFExt`, `gcodeSpace`, `gcodeStrip`, `useLaser`, `useIndexed`, plus optional embedded process `profiles`.
- The loader function `device_from_code` maps legacy keys to the new ones and treats an `internal` field as "already converted".

Source: [defaults.js](https://github.com/GridSpace/grid-apps/blob/master/src/kiri/app/conf/defaults.js); [ShopBot.Basic.json](https://github.com/GridSpace/grid-apps/blob/master/src/kiri/dev/cam/ShopBot.Basic.json); [Makera.Carvera.json](https://github.com/GridSpace/grid-apps/blob/master/src/kiri/dev/cam/Makera.Carvera.json)

**Template tokens seen in shipped profiles:** `{tool}`, `{tool_name}`, `{time}` (dwell), and `{speed}` or `{spindle}` (spindle RPM). Example tool-change line: `"M6 T{tool} ; change tool to '{tool_name}'"`. — [Any.Generic.Grbl.json](https://github.com/GridSpace/grid-apps/blob/master/src/kiri/dev/cam/Any.Generic.Grbl.json); [Sienci.AltMill.json](https://github.com/GridSpace/grid-apps/blob/master/src/kiri/dev/cam/Sienci.AltMill.json)

**Machine data in the profiles:**
- Sienci AltMill: bed 1260 × 1248, height 170.
- Makera Carvera: 360 × 240, `spindleMax` 20000.
- ShopBot Basic: 2400 × 1200 and `.sbp` output in ShopBot's own command language rather than G-code.

Source: [Sienci.AltMill.json](https://github.com/GridSpace/grid-apps/blob/master/src/kiri/dev/cam/Sienci.AltMill.json); [Makera.Carvera.json](https://github.com/GridSpace/grid-apps/blob/master/src/kiri/dev/cam/Makera.Carvera.json); [ShopBot.Basic.json](https://github.com/GridSpace/grid-apps/blob/master/src/kiri/dev/cam/ShopBot.Basic.json)

**No limit fields.** The CAM device defaults have no feed, rapid or acceleration fields. Arc output (`camArcEnabled`, `camArcTolerance`) is a *process* setting, not a device setting. `gcodeTime` (`time_factor`) is a scalar fudge factor for time estimates. — [defaults.js](https://github.com/GridSpace/grid-apps/blob/master/src/kiri/app/conf/defaults.js)

**Machine Setup tab in the docs:**
- Workspace X/Y/Z and Max Spindle.
- Output options: Strip Comments, Token Spacer, Enable Laser, File Extension.
- Macros: Header, Footer, Tool, Dwell, Spindle.
- A `.rml` extension switches output to the Roland RML dialect.
- Workspaces can be exported as `.kmz` to share.

Source: [Kiri:Moto docs](https://docs.grid.space/kiri-moto/CAM/machines)

**Community contributions.** V1Engineering's community added default Lowrider/MPCNC profiles through a pull request. — [V1E forum](https://forum.v1e.com/t/default-kiri-moto-profile-for-v1e-machines-lowrider-and-mpcnc/39289)

### Inferences
- These profiles are the cleanest legally bundleable seed data: bed sizes, spindle caps and header/footer templates for about 25 popular hobby machines, under MIT with attribution.
- Parsing takes trivial effort with `Codable` handling the two key schemas.
- The profiles must be supplemented with feed, rapid and acceleration values from controller configs or user input.

### Gaps
- No formal schema document exists.
- The full list of template tokens supported by the exporter was not enumerated from source; only those seen in the shipped profiles are listed.

## 5. Carbide Create, Estlcam, FreeCAD CAM, CamBam, SheetCAM, MeshCAM

### Takeaway
These six vary widely:

| Program | Post format | Machine description |
|---|---|---|
| FreeCAD CAM | Python scripts (LGPL) | New JSON machine file (`.fcm`) in the 26.3 release candidate, with per-axis limits and max velocity, plus import from MTConnect |
| CamBam | Simple XML template (`.cbpp`) | Not documented |
| SheetCAM | Lua scripts (`.scpost`) | Not documented |
| Carbide Create Pro | JavaScript `.post` with `onOpen`/`onClose` | Standard Carbide Create: built-in, non-editable post |
| Estlcam, MeshCAM | Not verified | Not verified |

None of them carry acceleration except possibly FreeCAD in future; the FreeCAD model has max velocity but no acceleration.

### Cited Findings
**FreeCAD CAM, posts.** The main branch has 41 `*_post.py` scripts. They include generic, grbl, linuxcnc, mach3_mach4, centroid, masso_g3, opensbp (ShopBot), estlcam, uccnc (legacy), haas, fanuc, heidenhain, marlin and smoothie posts, with many in `_legacy` variants. — [FreeCAD CAM post scripts](https://github.com/FreeCAD/FreeCAD/tree/main/src/Mod/CAM/Path/Post/scripts)

**FreeCAD CAM, new Machine model** (`src/Mod/CAM/Machine/models/machine.py`, LGPL-2.1-or-later):
- `LinearAxis` with `min_limit`, `max_limit`, `max_velocity`, role and direction.
- `RotaryAxis` with limits, `max_velocity`, wrap strategy and rotation preference.
- `Toolhead` with type, `max_rpm`/`min_rpm`, `max_power_kw`, `tool_change` ("manual" by default) and coolant flags.
- Output options: units, header items, comment symbol, line numbers, precision, modal suppression, and G43 after M6.
- Processing options: tool change format, `split_arcs`, `translate_drill_cycles`, and others.
- It is serialised as JSON files with the extension `.fcm` in the CAM asset path's "Machines" folder.
- A text search found no acceleration field.

Source: [machine.py](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/Machine/models/machine.py)

**FreeCAD CAM, MTConnect import.** A companion module builds a Machine from an MTConnect "probe" XML document, reading axis travel, velocity specs and the spindle RPM band. — [mtconnect_import.py](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/Machine/models/mtconnect_import.py)

**FreeCAD release status:**
- The Machine module is present in the `26.3rc2` pre-release tag (2026-10-18).
- It is absent from the `1.1.0` tag. FreeCAD 1.1 was released 2026-03-25; the latest stable is 1.1.4 (2026-09-28).

Source: [FreeCAD releases](https://github.com/FreeCAD/FreeCAD/releases); [26.3rc2](https://github.com/FreeCAD/FreeCAD/releases/tag/26.3rc2); [1.1.0](https://github.com/FreeCAD/FreeCAD/releases/tag/1.1.0)

**CamBam.** A `.cbpp` file is XML with a `<PostProcessor>` root. Element blocks include `PostFile`, `Header`, `Footer`, `ToolChange`, `MOP`, `Drill`, `DrillDwell`, G81/G82/G83, cutter-compensation blocks and `MaximumArcRadius`. Macros are written `{$...}`, e.g. `{$tool.index}`, `{$clearance}`, `{$spindle}`, `{$mop.clearanceplane}`. Example line: `T{$tool.index} M6`. — [GRBLMachine.cbpp](https://github.com/thekroko/GRBLMachinePlugin/blob/HEAD/GRBLMachinePlugin/Resources/GRBLMachine.cbpp); [Estlcam.cbpp](https://github.com/NiklasVoigt/cambam-estlcam-postprocessor)

**SheetCAM, post structure.** Posts are Lua `.scpost` files defining callbacks such as `OnInit`, `OnRapid`, `OnMove`, `OnArc`, `OnPenDown`/`OnPenUp`, `OnDrill` and `OnFinish`. They emit text with `post.Text`, `post.ModalText` and `post.ModalNumber`. — [LinuxCNC forum scpost example](https://forum.linuxcnc.org/media/kunena/attachments/21103/plasmac-3.scpost.txt); [SheetCamEMCPlasma.scpost](https://github.com/araisrobo/linuxcnc/blob/HEAD/configs/plasma-thc/SheetCam/SheetCamEMCPlasma.scpost)

**SheetCAM, installation.** A post is imported via Options > Machine options > Post processor tab. — [MachMotion KB](https://machmotion.gitbooks.io/knowledge-base/sheetcam-post-processor.html)

**Carbide Create Pro.**
- Carbide Create Pro supports a custom JavaScript post with a `.post` extension.
- Start-of-program code lives in `onOpen` and end code in `onClose`; tool-change code can also be edited.
- It is installed via About > Open Data Directory > Posts and re-evaluated on every G-code save.

Source: [Carbide 3D Hub FAQ (search snippet; direct fetch returned 404)](https://carbide3d.com/hub/faq/create-pro-custom-post-processor); [Onefinity CC Pro post](https://forum.onefinitycnc.com/t/carbide-create-pro-post-processor-for-onefinity-m6-tool-change/37317)

**Carbide Create (standard).** Posts are picked under Edit > Select Post Processor. The default "Shapeoko with limit switches" post adds probing code. — [Onefinity forum](https://forum.onefinitycnc.com/t/carbide-create-post-processor-selection/812)

**Estlcam:**
- Its settings define a clearance plane. — [estlcam.de basic settings](https://www.estlcam.de/e2_grundeinstellungen.php)
- Fusion's library has a "generic milling post for Estlcam". — [Fusion post library reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSOR-LIBRARY-REF.htm)
- Community `.pp` files exist for Vectric-to-Estlcam. — [Inventables forum](https://community.inventables.com/t/vcarve-desktop-post-processor-for-estlcam/70310)

**MeshCAM.** Machsupport's Mach3 downloads page lists MeshCAM among CAM post downloads. — [Machsupport Mach3 downloads](https://www.machsupport.com/downloads-updates/mach3-downloads/)

### Inferences
- **CamBam `.cbpp`:** easy to import, since it is XML with `{$macro}` substitution, but CamBam's user base is small.
- **SheetCAM `.scpost`:** importing requires embedding Lua and emulating SheetCAM's `post.*` API. That is moderate-to-high effort for a mainly plasma audience.
- **Carbide Create Pro `.post`:** importing requires a JavaScript runtime and Carbide's API. JavaScriptCore is available on macOS, but the API is undocumented here.
- **FreeCAD `.fcm`:** may become a useful open, LGPL-documented interchange schema. It is JSON with limits and max velocity, but has little real-world install base yet.

### Gaps
- MeshCAM's post file format and folder could not be verified.
- Estlcam's machine or post configuration file format could not be verified; it appears to be configured only through its UI.
- The CamBam documentation site's post-processor page returned "Page Not Found", and its HTTPS certificate had expired.
- No official SheetCAM API reference was retrieved.
- The exact Carbide Create Pro post API was not retrieved.

## 6. Controller configuration files that describe real machine limits (and which carry acceleration)

### Takeaway
The controller-side files are where real kinematic limits live. All of the following carry per-axis acceleration usable for run-time estimation, and all are simple text formats:
- LinuxCNC INI
- GRBL/grblHAL `$$` dumps
- FluidNC `config.yaml`
- Mach4 `Machine.ini`
- Mach3 XML profiles
- UCCNC `.pro` (per community sources)

MASSO stores settings in a proprietary `.htg` file plus a non-loadable "printable" text file. Centroid Acorn uses numbered parameters inside CNC12's `c:\cncm`, a format not well documented publicly.

### Cited Findings
**LinuxCNC INI:**
- `[TRAJ]`: LINEAR_UNITS, MAX_LINEAR_VELOCITY (units/s), MAX_LINEAR_ACCELERATION (units/s²).
- `[AXIS_<L>]`: MIN_LIMIT, MAX_LIMIT, MAX_VELOCITY (units/s), MAX_ACCELERATION (units/s²).
- `[JOINT_<n>]`: TYPE, limits, velocity, acceleration, SCALE.
- `[SPINDLE_n]`: MAX_FORWARD_VELOCITY and MIN_FORWARD_VELOCITY (RPM).
- `[EMCIO]`: TOOL_CHANGE_POSITION.
- `[RS274NGC]`: REMAP.
- INI values are per second; the AXIS GUI displays per minute.

Source: [LinuxCNC INI docs](https://linuxcnc.org/docs/html/config/ini-config.html)

**GRBL v1.1 `$$`.** Output is one `$n=value` line per setting. The machine-relevant ones:

| Settings | Meaning | Units |
|---|---|---|
| $100–$102 | steps per mm | steps/mm |
| $110–$112 | max rate | mm/min |
| $120–$122 | acceleration | mm/s² |
| $130–$132 | max travel | mm |
| $30 / $31 | spindle max / min | RPM |
| $32 | laser mode | boolean |
| $13 | report in inches | boolean |
| $20–$22 | soft limits, hard limits, homing | boolean |
| $11 | junction deviation | mm |
| $12 | arc tolerance | mm |

Source: [GRBL v1.1 configuration wiki](https://github.com/gnea/grbl/wiki/Grbl-v1.1-Configuration)

**GRBL version caveat.** Setting numbers changed after v0.8c, so a parser must know the version. — [GRBL v0.8 wiki](https://github.com/grbl/grbl/wiki/Configuring-Grbl-v0.8/42eaf402ce502001ce8c7887cce33e58080ffb23)

**grblHAL extensions:**
- $32 mode: 0 normal, 1 laser, 2 lathe.
- $340: spindle at-speed tolerance.
- $341: manual tool-change mode. 0 normal, 1 manual touch-off, 2 or 3 touch-off at G59.3, 4 ignore M6.
- $342–$344: tool touch-off probing distance and feeds.
- $44–$49: homing order.
- `$help settings` lists settings, and `$$=<n>` gives help for setting n.

Source: [grblHAL extended settings wiki](https://github.com/grblHAL/core/wiki/Additional-or-extended-settings)

**FluidNC `config.yaml`:**
- An `axes:` map with `x:`, `y:`, `z:` entries. Each has `steps_per_mm`, `max_rate_mm_per_min`, `acceleration_mm_per_sec2`, `max_travel_mm` and `soft_limits`, plus a `homing:` block (`cycle`, `positive_direction`, `mpos_mm`, feed and seek rates) and `motor0:` pin wiring.
- Example line: `acceleration_mm_per_sec2: 100.000`.
- The community config repo (124 YAML files) is GPL-3.0. Its CI validates configs against a JSON Schema and validator kept in the main FluidNC repo's `tools/`.

Source: [FluidNC config example](https://github.com/bdring/fluidnc-config-files/blob/main/contributed/6x_CNC_Controller/6x_XYZABC_Huany.yaml); [validator workflow](https://github.com/bdring/fluidnc-config-files/blob/main/.github/workflows/validate-new-configs.yml); [FluidNC tools](https://github.com/bdring/FluidNC/tree/main/tools)

**Mach4 `Machine.ini`.** The example is a real Avid CNC profile at `Profiles/AvidCNC/Machine.ini`:
- `[Motor0]` holds CountsPerUnit, MaxVelocity, MaxAccel, BacklashAmount, SoftMaxLimit and SoftMinLimit.
- `[Axis0]` maps motors to axes with ChildMotor0, plus homing and soft-limit flags.
- `[SpindleRange0..]` hold minrpm, maxrpm, acceltime and deceltime; the example has maxrpm=18000.
- `[Preferences]` include `unitsmode=G20` and `setupunits`.
- `[ToolChangeSettings]` is present.

Source: [corbinstreehouse/Mach-4-Avid-CNC-Customizations Machine.ini](https://github.com/corbinstreehouse/Mach-4-Avid-CNC-Customizations/blob/HEAD/Profiles/AvidCNC/Machine.ini)

**Mach4 configuration UI.** Motor tuning (counts per unit, velocity, acceleration) is set under Configure > Mach > Motors. — [MachMotion KB](https://support.machmotion.com/books/documentation-artsoft/page/mach4-how-do-i-set-up-counts-per-unit)

**Avid's Mach4 guides.** Avid publishes Mach4 configuration guides. — [Avid Mach4 Configuration Guide 2023Q3](https://www.avidcnc.com/cad/2023Q3/Mach4_Configuration_Guide_v2023Q3_1.pdf)

**Mach3 XML profile.** The root is `<profile><Preferences>`. Per-motor tags are numbered: `<Steps0>`, `<Vel0>`, `<Acc0>`, and so on. There is also `<Units>`. The file is named after the profile with a `.XML` extension. — [Mach3 XML example (LSU.xml)](https://github.com/Cfree1989/Machine-profiles/blob/HEAD/Plasma/vendor/ez-router-cd/Mach%203%20Software/Mach3/LSU.xml); [PlasmaSpider forum](https://www.plasmaspider.com/viewtopic.php?p=184152); [Mach3 install/config manual](https://www.machsupport.com/ftp/Docs/Mach3Mill_Install_Config.pdf)

**UCCNC:**
- Profiles are `.pro` files named after the profile, in `UCCNC/Profiles`.
- They are INI-like text, with per-axis velocity and acceleration, steps per unit, homing and soft-limit keys. A user showed `Velocity=` and `Acceleration=` entries.
- Profile macros live in `Macro_<profile>` folders.

Source: [CNC Drive forum](https://forum.cncdrive.com/viewtopic.php?p=4099); [Stepcraft forum](https://www.stepcraft-systems.com/en/forum/software2/6643-configuration-profile-of-the-stepcraft2-cnc?rCH=2)

**MASSO G3.** F1-Setup > Save & Load Calibration Settings writes `MASSO_Settings.htg` and `MASSO_Tools.htg` to a MASSO folder on a FAT32 USB stick. "Save Printable File" writes a text file that "cannot be loaded" back into a controller. — [MASSO docs: Load/Save calibration](https://docs.masso.com.au/masso-settings/load-save-calibration-settings); [MASSO docs: Save & Load](https://docs.masso.com.au/wiring-and-setup/save-and-load-settings)

**Centroid Acorn.**
- Configuration uses numbered machine parameters. For example, #86 is a rapid/linear vector rate limit, #357–364 are axis drive max RPM, and #37 is spindle deceleration time.
- CNC12 lives under `c:\cncm`.
- Centroid recommends saving a "Create Report" archive after every configuration change.

Source: [Sherline Acorn parameter PDF](https://www.sherline.com/wp-content/uploads/2023/12/acorn_param_settings.pdf); [Acorn install manual (Sherline copy)](https://www.sherline.com/wp-content/uploads/2024/03/centroid_acorn_install_manual.pdf)

### Inferences
- **Mach4 units.** In the Avid `Machine.ini`, the motor values appear to be stored in encoder/step *counts*, not machine units. Dividing by CountsPerUnit for motor 0 gives 10 units/s for MaxVelocity (600 in/min) and 15 units/s² for MaxAccel. The soft-limit spans come to about 49.5 in (X) and 98.5 in (Y), consistent with a 4×8 Avid PRO. An importer should divide by CountsPerUnit and should treat axis↔motor mapping (ChildMotorN, including slaved gantry motors) as required.
- **Mach3 units.** The `Vel`/`Acc` units in Mach3 XML (per second or per minute) are not confirmed. The values in the sample (Vel0=12.5, Acc0=15) suggest units/s and units/s². Validate this against a known machine before relying on it.
- **Acceleration for run-time estimation is available from:** LinuxCNC (per axis and per trajectory), GRBL/grblHAL ($120–$122), FluidNC (acceleration_mm_per_sec2), Mach4 (MaxAccel in counts), Mach3 (Acc0..), UCCNC (Acceleration), and Vectric Machine Configuration (entered in the UI, not file-importable).
- **No acceleration was found in:** Fusion `.mch` (samples examined), FreeCAD `.fcm`, Kiri:Moto profiles, or `.pp`, `.cps`, `.cbpp` and `.scpost` posts.
- **Unclear:** MASSO, whose binary format is unknown, and Centroid, where no per-axis acceleration parameter was located.
- **Tool changers:** controller files rarely state ATC presence directly. Mach4 has `[ToolChangeSettings]` and m6 macro references, LinuxCNC has `[EMCIO]` and REMAP, and grblHAL has $341. A CAM importer still needs a user prompt for tool-change style.

### Gaps
- The exact meaning of Mach4's `setupunits=200` was not verified.
- Mach3 `<SoftMax>`/`<SoftMin>` tag names were not seen in the sample.
- An official UCCNC `.pro` key reference was not found; only forum descriptions.
- Whether MASSO's `.htg` is encrypted or binary is not stated.
- What Centroid's "Create Report" zip contains, and the exact file names (e.g. `cncm.prm`), were not confirmed.
- A FluidNC wiki fetch failed with connection refused, so field semantics come from example configs rather than the wiki.
- The licence of the FluidNC main repo shows as NOASSERTION on GitHub and was not resolved.

## 7. Existing open-source converters between these formats

### Takeaway
The only substantial open-source converter found is in PureCutCNC (Apache-2.0, a 2.5D CAD/CAM app). It converts posts from seven CAM formats into its own JSON machine definition, writing a conversion report with every run:

| Format | Extension |
|---|---|
| Vectric/Estlcam | `.pp` |
| Autodesk | `.cps` |
| SheetCAM | `.scpost` |
| ArtCAM | `.con` |
| ECam | `.xml` |
| Visual Mill | `.spm` |
| Mastercam | `.pst` |

No Vectric `.pp` ↔ Fusion `.cps` converter and no standalone GRBL `$$` parser library turned up.

### Cited Findings
**PureCutCNC `postProcessorConverter`:**
- A CLI, `convert-post-processor --input <file> --output <json>`, auto-detects the format by extension and writes a machine-definition JSON plus a `.report.json`.
- A `--strict` flag refuses output if any unresolved finding would change emitted 3-axis G-code.
- Its test fixtures include `.pp`, `.cps`, `.scpost`, `.con`, `.pst`, `.spm` and ECam XML files.

Source: [PureCutCNC repo (Apache-2.0)](https://github.com/PureCutCNC/purecutcnc); [converter README](https://github.com/PureCutCNC/purecutcnc/blob/HEAD/src/postProcessorConverter/README.md)

**Cut Craft.** This Rust Vectric-Aspire-style app is "source-available (free for noncommercial use)" and ships its own `.pp` posts for grbl and mach3. Its licence is not open source. — [NoobyNull/Cut-Craft](https://github.com/NoobyNull/Cut-Craft)

**Vectric tool database converter.** A `.vtdb` → JSON tool-database converter was posted on the LightBurn forum. — [LightBurn forum](https://forum.lightburnsoftware.com/t/cross-platform-vectric-to-millmage-tool-database-converter/193422.md)

**Demand for `.pp` → `.cps`.** Users ask for `.pp`-to-`.cps` conversion and are directed to manual post edits. — [Autodesk forum idea](https://forums.autodesk.com/t5/hsm-post-processor-ideas/generating-cps-post-processing-file-form-a-pp-file/m-p/11875449); [Autodesk forum (Syntec)](https://forums.autodesk.com/t5/fusion-manufacture-forum/syntec-6mb-controller-cps-file-help/td-p/8430964)

**GRBL settings parsing.** Grbl_Esp32's design notes call GRBL's own `$` parser "an ad-hoc mess"; that was a design proposal, not a library. — [Grbl_Esp32 settings design doc](https://github-wiki-see.page/m/bdring/Grbl_Esp32/wiki/Settings-Improvement---Design-Document)

**FreeCAD MTConnect import.** FreeCAD's new MTConnect importer (LGPL) is effectively a converter from a live controller's probe XML to a FreeCAD machine. — [mtconnect_import.py](https://github.com/FreeCAD/FreeCAD/blob/main/src/Mod/CAM/Machine/models/mtconnect_import.py)

### Inferences
- PureCutCNC's adapter design is directly relevant prior art: a per-format adapter, a common machine model, and a report of unresolved or unsafe fields. NativeCAM could reuse it as a reference under Apache-2.0 terms (keep the NOTICE and attribution) or port the ideas to Swift.
- GitHub repo searches for "grbl settings parser", "pp to cps" and "vectric post processor converter" returned nothing. A `$$` parser is trivial (regex `^\$(\d+)=(.*)$` plus a version-aware number table), so the lack of a library is not a blocker.

### Gaps
- PureCutCNC's adapters were not read in detail. It is unknown how much of `.cps` it actually interprets (likely only declarative globals) or how complete its `.pp` block mapping is.
- G-code senders such as gSender or UGS, which may export and import GRBL settings files, were not investigated.

## 8. Which formats give the most coverage of real machines for the least work?

### Takeaway
The highest return comes from this priority list:
1. Vectric `.pp` import, for G-code dialect and templates.
2. GRBL/grblHAL `$$` paste-in, for limits and acceleration.
3. Bundling Kiri:Moto's MIT profiles as starter machines.
4. Mach4 `Machine.ini`, LinuxCNC INI and FluidNC YAML readers, which are each a small INI or YAML parse and also carry acceleration. Mach4 matters directly for Avid machines.
5. Fusion `.mch` JSON as a secondary limits source.

Avoid executing Fusion `.cps`, SheetCAM Lua or Carbide JavaScript posts, and skip MASSO `.htg` and Centroid parameter imports for now.

### Cited Findings
- `.pp` files are distributed by Vectric for most hobby/prosumer machines (Carbide 3D, Onefinity, Avid, MASSO, Next Wave) and published by vendors on GitHub (Snapmaker, Synthetos, Handibot). — [Carbide 3D community](https://community.carbide3d.com/t/new-post-processor-for-vectric-software/77335?page=3); [Onefinity forum](https://forum.onefinitycnc.com/t/vectric-post-processors-for-10-5-or-older-versions-download-links-included/640/1); [MASSO docs](https://docs.masso.com.au/cam-post-processors/vectric-vcarve-and-vectric-aspire); [Snapmaker repo](https://github.com/Snapmaker/snapmaker_cnc_post_process)
- The `.pp` format is declarative text with a small, documented set of statements, tokens and blocks. — [Vectric V12.5 docs](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html)
- A GRBL `$$` dump carries steps, max rate, acceleration, travel and spindle range in one flat list. — [GRBL v1.1 wiki](https://github.com/gnea/grbl/wiki/Grbl-v1.1-Configuration)
- Kiri:Moto ships 28 MIT-licensed CNC profiles. — [grid-apps](https://github.com/GridSpace/grid-apps/tree/master/src/kiri/dev/cam)
- Mach4, LinuxCNC and FluidNC files carry per-axis velocity and acceleration. — [Avid Mach4 Machine.ini](https://github.com/corbinstreehouse/Mach-4-Avid-CNC-Customizations/blob/HEAD/Profiles/AvidCNC/Machine.ini); [LinuxCNC INI docs](https://linuxcnc.org/docs/html/config/ini-config.html); [FluidNC example](https://github.com/bdring/fluidnc-config-files/blob/main/contributed/6x_CNC_Controller/6x_XYZABC_Huany.yaml)
- Fusion posts are licence-restricted to Autodesk products. — [cam.autodesk.com/hsmposts](https://cam.autodesk.com/hsmposts)

### Inferences
Effort versus coverage, ranked:

| Rank | Format | Effort | Coverage and contents | Licence position |
|---|---|---|---|---|
| 1 | Vectric `.pp` import | Low–moderate | Very high. Covers G-code dialect, header/footer/tool change, arc style, units and extension. No limits. | Users import their own files |
| 2 | GRBL/grblHAL `$$` paste or file | Trivial | Shapeoko, X-Carve, Sienci, Genmitsu, PrintNC and similar machines. Limits, acceleration, travel, spindle, mm units. | Settings are data |
| 3 | Kiri:Moto profiles (bundled) | Trivial | About 25 named hobby machines: bed sizes, spindle caps, starter header/footer. | MIT, attribution required |
| 4 | Mach4 `Machine.ini` (counts→units), LinuxCNC INI, FluidNC YAML | Low each | Real velocity and acceleration for estimation. Mach4 covers Avid machines; LinuxCNC covers PrintNC/Probotix; FluidNC covers many ESP32 builds. | Data |
| 5 | Fusion `.mch` JSON | Low–moderate | Travel, feed/rapid caps, spindle, ATC, tool-change time. Many users already have a Fusion machine they can export. | Only user-exported files |
| 6 | UCCNC `.pro`, Mach3 XML, CamBam `.cbpp` | Low | Smaller audiences | — |
| 7 (defer) | SheetCAM `.scpost` (Lua), Carbide Create Pro `.post` (JS), Fusion `.cps` (JS + Autodesk API) | High: needs an embedded runtime | — | `.cps` restricted to Autodesk products |
| 7 (defer) | MASSO `.htg`, Centroid parameters | High | — | Proprietary or undocumented |

- **Suggested internal model:** a NativeCAM machine schema that merges a "limits" record (travel, per-axis max feed and rapid, acceleration, spindle range, units, ATC) with a "dialect/post" record (templates, arc style, extension). Then each importer fills whichever half its source carries. PureCutCNC and FreeCAD's `.fcm` both follow this pattern.
- **Avid user path:** Vectric's bundled Avid `.pp` (or Avid's own download) plus the Mach4 `Machine.ini` from the Avid profile together cover both halves without any proprietary runtime.

### Gaps
- No market-share data was found to rank the controllers quantitatively. The rankings above are judgement based on which vendors publish which formats.
- Mach4's exact units semantics, MASSO's binary format and Centroid's file layout still need hands-on verification with real files.
