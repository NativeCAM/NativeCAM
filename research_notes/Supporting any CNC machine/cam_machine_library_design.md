# CAM Machine Libraries, Post-Processor Libraries and Machine Selection: Architecture, Pain Points, and Best Practices for a Native macOS CAM App

Scope note: research done 2026-11-19. Primary sources are vendor docs (Vectric V12/V12.5 help, Autodesk Fusion help, Kiri:Moto docs, FreeCAD developer wiki, LightBurn docs, Grbl wiki). Forum material is labelled **[anecdotal]**. Several vendor pages could not be fetched directly (FreeCAD wiki blocked by a bot wall, Easel support 403, CamBam docs had an expired TLS certificate, Carbide 3D custom-post FAQ returned 404). Where a claim rests only on a search-result excerpt rather than a page I read in full, it is marked **(search excerpt)**. Version context: Vectric docs are V12.0/V12.5; Fusion docs are the current "cloudhelp" pages; FreeCAD machine configuration is a 1.2-development-cycle feature.

## 1. How does each product separate machine (kinematics, limits) from post (G-code dialect) and from tool library? Can one machine have several posts?

### Takeaway
The mature products (Vectric, Fusion, FreeCAD 1.2) all treat Machine, Post and Tool/cutting data as separate objects, with the machine holding a link to one or more posts. Vectric explicitly allows several associated posts per machine, each pinned to a version, with one marked default. The hobby tools (Carbide Create, Easel, Estlcam, Kiri:Moto, LightBurn) merge machine and post into one "device/machine profile" made of a few GUI fields and free-text G-code snippets. The industry is moving post settings *out* of post code and *into* the machine record (FreeCAD 1.2 says so explicitly; Fusion links posts to machine definitions).

### Cited Findings

**Vectric (VCarve/Aspire V12.x)**
- Vectric describes correct setup as "two elements": tool settings in the tool database, plus the post-processor. Running setup creates a default tool database with starting feeds, and Vectric warns not to use those defaults without checking them against the machine maker's recommendations — [Vectric V12 User Guide](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/page/user-guide/index.html)
- Machine Configuration Management "manages the machines in the tool database and associates post-processors with them for Toolpath Saving". In the Tool Database, the active machine (and its material) sets which cutting data the tools use, so feeds and speeds are keyed by tool + machine + material — [Vectric V12.5 Machine Configuration Management](https://docs.vectric.com/docs/V12.5/Cut2DPro/ENU/Help/form/tool-database-machine-management/index.html)
- A machine configuration has a unique name ("Two machines cannot have the same name"). Everything else is optional, including axis acceleration (XYZ and rotary). Vectric says acceleration values "will not impact the GCode output of toolpaths and are only used to estimate toolpath times" — [Vectric V12.5 Machine Configuration Management](https://docs.vectric.com/docs/V12.5/Cut2DPro/ENU/Help/form/tool-database-machine-management/index.html)
- **Several posts per machine:** "Associated Post-Processors" is a list. Each entry is set either to "Latest (Vn)", which takes future updates automatically, or to a fixed "Vn". A right-click "Make Default" picks the default for Toolpath Saving. Removing an association does not delete the post file — [Vectric V12.5 Machine Configuration Management](https://docs.vectric.com/docs/V12.5/Cut2DPro/ENU/Help/form/tool-database-machine-management/index.html)
- In the Save Toolpaths form, you pick a Machine and then a Post-Processor. The post list "is updated to only show those relevant for the selected machine". You can add more posts with an "<Add Post-Processors>" entry in the drop-down — [Vectric V12.5 Save Toolpaths](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/Save%20Toolpaths/index.html)
- Vectric ships separate post files per variant, not one post with options. Examples: "Shapeoko (mm)" and "Shapeoko (in)" **[anecdotal]** — [Carbide 3D community, "What is the proper post processor"](https://community.carbide3d.com/t/what-is-the-proper-post-processor/72101) (search excerpt). Also "Masso ATC Arcs (inch)" and "Masso ATC Arcs (mm)" **[anecdotal]** — [Onefinity forum, Vectric post update 5/30/25](https://forum.onefinitycnc.com/t/vectric-post-processor-update-for-all-machine-types-info-5-30-25/33564)
- Units belong to the post. The post's metric/imperial output "must typically match the units mode you have set on your CNC machine's controller". Design units don't matter because conversion happens at save time — [Vectric V12 User Guide](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/page/user-guide/index.html)

**Autodesk Fusion**
- A machine definition is "a collection of settings that describe the physical and operational characteristics of a CNC machine": capabilities and kinematics. For 4+ axis machines it also has retract/reconfigure settings that handle "overtravels that occur when the machine goes beyond its physical limits" — [Fusion help: Machines for manufacturing](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINES.htm)
- The Machine Library has a read-only "Fusion Library" of predefined machines that you copy, plus "My Machines" subfolders (local or cloud). A machine definition is optional for milling setups but required for additive — [Fusion help: Machines for manufacturing](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINES.htm)
- You link a post to a machine on the machine definition's "Post Processing" page. Afterwards "the machine definition is now linked to a post processor" — [Fusion help: Link a post processor to a machine definition](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINE-LINK-POST.htm). The help page describes linking a single post. I found no documentation of several linked posts per machine.
- Fusion handles dialect variants through **post properties** (per-post options set at post time), not separate files. Examples from forum fixes: `useToolChanger`, tool preload on/off, `useM6` **[anecdotal]** — [Autodesk forum: UCCNC tool change doesn't stop spindle](https://forums.autodesk.com/t5/fusion-manufacture/uccnc-post-processor-tool-change-doesn-t-stop-spindle/m-p/8129742); [Autodesk forum: strange tool change (preload)](https://forums.autodesk.com/t5/fusion-manufacture/strange-tool-change/m-p/12905554)
- Linking a machine model enables full machine simulation. Without a model, Fusion "uses information from the machine definition and post processor but does not show the CNC machine" — [Fusion help: Machines for manufacturing](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINES.htm)

**FreeCAD CAM (1.2 development cycle)**
- In the new Machine model, linear axes have direction vectors, min/max limits and max velocity. Rotary axes have limits and max RPM. Spindles have a type (rotary, laser, waterjet, plasma), power, min/max RPM, a tool change method, coolant and a spindle-wait delay. The machine *also* holds post settings: output units, tool-length offset, header, comment/precision/duplicate suppression, arc splitting, rapid handling, tool-change control, the post file name, and a `postprocessor_properties` dictionary — [FreeCAD dev wiki: Machines](https://github-wiki-see.page/m/sliptonic/FreeCAD/wiki/Machines)
- FreeCAD states the direction outright: "configuration is moving out of the postprocessor"; "it should be a rare occurrence to write a new postprocessor"; "Legacy command-line arguments are deprecated in favor of machine configuration" — [FreeCAD dev wiki: Machines](https://github-wiki-see.page/m/sliptonic/FreeCAD/wiki/Machines)
- Machine configs are saved as `.fcm` files and are "suitable for version control". Jobs reference machines by name. The API is "considered unstable" — [FreeCAD dev wiki: Machines](https://github-wiki-see.page/m/sliptonic/FreeCAD/wiki/Machines)
- In the new flow, a job's main configuration choice is its target machine. User preferences only set the default output location and which posts are available — [FreeCAD dev wiki: Postprocessing](https://github-wiki-see.page/m/sliptonic/FreeCAD/wiki/Postprocessing)

**Hobby tools: machine + post merged into one profile**
- **Kiri:Moto:** "Machine Setup" holds workspace X/Y/Z, Max Spindle (clamps generated S values), output options (strip comments, token spacer, laser, file extension), and G-code macros for Header, Footer, Tool, Dwell and Spindle. Setting the extension to `.rml` switches to Roland RML. The docs advise entering actual usable travel, not marketing specs — [Kiri:Moto docs: Machines](https://docs.grid.space/kiri-moto/CAM/machines)
- **Carbide Create:** The Job Setup "Machine Type" field is largely vestigial. A Carbide 3D staff reply says it dates from when Create limited stock size and calculated chip loads by machine, and no longer does either **[anecdotal]** — [Carbide 3D community: Carbide Create on OpenBuilds Lead 1010](https://community.carbide3d.com/t/can-i-use-carbide-create-with-a-openbuilds-lead-1010-cnc/46231) (search excerpt; the exact thread attribution is uncertain). You pick the post separately under Edit > Post Processor. The default "Shapeoko with limit switches" adds probing code **[anecdotal]** — [Onefinity forum: Carbide Create post processor selection](https://forum.onefinitycnc.com/t/carbide-create-post-processor-selection/812)
- **Estlcam:** Dialect is set under Setup > CNC Programs, with a Presets tab (controller presets) and a Texts tab (start, end and tool-change G-code). A common user error is putting tool-change code in the start text **[anecdotal]** — [davelers.com Estlcam setup](https://davelers.com/Workshop/CNC/Estlcam/Setup/); [V1 Engineering forum: tool change routine](https://forum.v1engineering.com/t/tool-change-routine-for-dummies/22814)
- **Easel:** Machine setup is tied to the controller. Easel reportedly edits GRBL `$` settings on the controller "ONLY IF an X-Carve is selected during the machine setup process". Third-party GRBL machines (Grbl 0.8c–1.1h) are supported, and a Machine Inspector exposes firmware settings — [Easel support article](https://support.easel.com/hc/en-us/articles/360012642474) (search excerpt; page returned 403 when fetched). A Shapeoko 3 user reported settings being overwritten after picking the wrong machine type **[anecdotal]** — [Easel forum: Can Easel be used on a Shapeoko3](https://forum.easel.com/t/can-easel-be-used-on-a-shapeoko3/23552?page=2) (search excerpt)
- **LightBurn (laser, for the "device profile" pattern):** A device profile (`.lbdev`) holds the device-specific information needed to recreate a machine profile, including camera calibration and scanning offsets. LightBurn 2.x Import accepts `.lbzip`, `.lbdev` or `.lbvendor` files with one or more devices. Importing a conflicting device creates a duplicate and keeps the existing one — [LightBurn 2.1 docs: Devices](https://docs.lightburnsoftware.com/2.1/Reference/Devices/); [Thunder Laser: backing up settings](https://support.thunderlaserusa.com/portal/en/kb/articles/backing-up-machine-and-lightburn-settings)
- **SheetCAM:** The manual has separate sections for the post processor tab, Machine options and the Tool table. Posts are Lua scripts (`.scpost`) that can define custom options (`post.DefineCustomOption`) and read per-tool parameters from the tool table — [SheetCAM TNG manual](https://PureLogic.ru/docs/soft_dlya_chpu/SheetCam_TNG_manual_en.pdf); [Example Lua post (LinuxCNC PlasmaC)](https://www.forum.linuxcnc.org/media/kunena/attachments/20660/SpaceShipPlasma-rev6-plasmac.scpost.txt)
- **MeshCAM:** Post choice sits under Job Setup > Select Machine. For example, the Nomad post is listed there **[anecdotal]** — [Carbide 3D community: MeshCAM post for Nomad](https://community.carbide3d.com/t/post-processor-for-nomad-with-meshcam/76686)

### Inferences
- **Recommended data model** (synthesised from the above):
  - **Machine.** Physical facts: travel envelope per axis, home/zero location convention, max feed and rapid per axis, acceleration, spindle RPM range and type, tool-change capability (manual, ATC, rack), probe or touch plate presence.
  - **Controller/dialect.** What the firmware accepts: Mach4, GRBL/grblHAL, LinuxCNC, Centroid CNC12, Masso, UCCNC.
  - **Post.** A versioned translator, parameterised by options.
  - **Tool library.** Geometry only.
  - **Cutting data.** Keyed by tool + material + machine, as Vectric does. Feeds that are fine on a stiff Avid PRO are wrong on a 3018.
  - **Material.**
- Vectric's "one file per variant" model (inch/mm × arcs × ATC) multiplies the list of choices and drives wrong-post errors (see section 2). The Fusion and FreeCAD model is one post with typed options, and the machine stores option values. That avoids the multiplication while still letting one machine have several *output profiles*, for example "Mach4 inch, manual change" and "Mach4 mm, ATC".
- Keep Vectric's "Latest vs pinned version" per machine–post association and its "filter posts to the selected machine" behaviour. Both directly reduce the wrong-post problem.
- A job should record machine ID + version, post ID + version, and option values, so it can be re-posted reproducibly later.

### Gaps
- Fusion docs reached here do not say whether one machine definition can link several posts, or how linked-post properties persist with the machine. The NC Program page (not fetched) likely covers this.
- No official Estlcam, CamBam or MeshCAM documentation could be read (marketing-only page, expired TLS certificate, no docs found). Their models are described from forums only.
- Carbide Create's official JavaScript custom-post documentation returned 404 (see section 3).

## 2. How do users find and install a post for their machine; what are common support problems (wrong post chosen, tool-change handling, arcs, units, Z zero)?

### Takeaway
Finding a post is either catalogue-driven (Vectric's cloud machine database/packages, Fusion's vendor-filtered Post Library, Kiri's built-in list) or a forum download that you copy into a folder. The recurring failures are the same across all products: **units mismatch** (inch post on an mm controller, or the reverse), **tool changes** (post with no tool-change support, missing M0/M5, wrong `TxM6` syntax, preload confusion), **arcs** (controller arc-endpoint errors), **Z zero/probing** (unexpected probing code, wrong Z reference), and **regressions after post updates**.

### Cited Findings

**How posts are found and installed**
- **Vectric:** The Post-Processor Manager has "Update Post-Processor List" (needs internet and a V&Co login), "Install Post-Processor" (from file), and "Customize" (creates an editable copy marked with a pencil icon, stored in `My_PostP`). Cloud updates do not affect custom posts — [Vectric V12 Post-Processor Management](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/form/post-processor-management/index.html)
- **Vectric machine packages:** "Search Machine Online" downloads a machine package, and "Install Offline Package" installs one from your V&Co account. Packages "come with compatible post-processors and an initial set of Feeds & Speeds" — [Vectric V12.5 Machine Configuration Management](https://docs.vectric.com/docs/V12.5/Cut2DPro/ENU/Help/form/tool-database-machine-management/index.html). Online configuration uses "V&Co's Machine Database" to set up the software for a make and model — [Vectric V12 User Guide](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/page/user-guide/index.html)
- Machine vendors now point users at Vectric's cloud update rather than shipping files. Onefinity staff, 2025: "Please use the machine configuration and click the cloud icon to download the latest post processors!" — [Onefinity forum, 5/30/25](https://forum.onefinitycnc.com/t/vectric-post-processor-update-for-all-machine-types-info-5-30-25/33564)
- **Fusion:** The Post Library has Fusion Library, Local, Cloud and Linked (external folder) sources. You filter by **Capabilities** and **Vendor**, then drag a post into Local or Cloud. Import and Export are supported — [Fusion help: Post Library reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POSTPROCESSOR-LIBRARY-REF.htm). A preference, "Automatically Get Latest Posts, Machines and Print Settings", keeps the library current. Customised posts saved alongside installed posts "can be overwritten when Fusion updates". Cloud posts can be shared across a hub — [Fusion help: Post Process overview](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSING-OVERVIEW.htm)
- **Kiri:Moto:** To add a machine to the built-in library, you submit a GitHub pull request. Users can also share exported workspaces (`.kmz`) on Discord or the forums — [Kiri:Moto docs: Machines](https://docs.grid.space/kiri-moto/CAM/machines). Users without a profile for their machine are told to copy header lines from the vendor's default software output **[anecdotal]** — [Grid.Space forum: Nymo 5040 profile request](https://forum.grid.space/t/any-chance-for-nymo-5040-to-be-added-to-supported-machine-profiles/2538)
- **Carbide Create Pro** with a third-party GRBL machine: "Select 'GRBL' as your post-processor and hit export". Carbide Create Core only exports G-code for Carbide 3D machines — [Carbide 3D: Carbide Create for Genmitsu 3018-PRO](https://carbide3d.com/carbidecreate/machines/3018-pro)

**Units mismatch (the most common and most dangerous)**
- **[anecdotal]** This one is on the user's own machine brand. An Avid CNC user ran a V-Carve job with the mm post while the Avid EX controller was set to inches and got "Z axis work envelope exceeded". An Avid staff reply: "Vectric, your post and your machine should all be in the same units"; the controller "doesn't convert units". The controller caught it because it pre-scans the G-code against the work envelope, but only once tool lengths are measured — [Avid CNC forum: Z axis work envelope exceeded](https://forum.avidcnc.com/t/z-axis-work-envelope-exceeded-what-am-i-missing/4398)
- **[anecdotal]** Similar reports: Z plunging about 0.5" too deep (wrong post suspected; a reply notes that G20 switches all moves to inches) — [Sienci forum: Why is the Z off so much?](https://forum.sienci.com/t/why-is-the-z-off-so-much/22029). Mismatched mm/inch posts on a Shapeoko Pro XXL — [Carbide 3D community: Pro XXL loses Z zero](https://community.carbide3d.com/t/pro-xxl-loses-z-zero-on-first-run-after-power-up/41686). A Masso user: "mismatching the post processor to your project units will result in incorrect part sizes" — [Onefinity forum](https://forum.onefinitycnc.com/t/vectric-post-processor-update-for-all-machine-types-info-5-30-25/33564)
- **[anecdotal]** Some controllers accept only one unit. The Axiom controller runs mm only, so there is "ONLY ONE post processor" — [Vectric forum: Axiom post processor](https://forum.vectric.com/viewtopic.php?p=190173). Sienci advises exporting with a mm post even when designing in inches — [Sienci: CNC post processors](https://resources.sienci.com/view/cnc-post-processors/) (search excerpt)

**Wrong controller post / Z reference**
- **[anecdotal]** An Avid user on the EX (Centroid CNC12) controller saw Z work zero reading 0 at the top of travel. They had the wrong post and needed the Avid EX post — [Avid CNC forum: EX CNC12 Z axis trouble](https://forum.avidcnc.com/t/ex-cnc12-z-axis-trouble/4351) (search excerpt). A 2023 Avid-focused blog: "If you use Centroid / CNC12, then don't use Avid's Post processor, and just use the Centroid one!" — [corbinstreehouse.com: Avid CNC ATC post for Vectric](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-setup-vectric-vcarve-vectric-aspire)
- **[anecdotal]** Carbide Create's default post inserts probing code ("Shapeoko with limit switches"). Non-Carbide users are told to pick GRBL instead — [Onefinity forum](https://forum.onefinitycnc.com/t/carbide-create-post-processor-selection/812)
- **[anecdotal]** Easel's Carvey output contains a G28 that errors elsewhere. The Carvey origin is bottom-left of the machine, while the X-Carve origin is wherever the bit starts, so "the same code cannot be used for both machines" — [Princeton lab page](https://commons.princeton.edu/josephhenry/cnc-milling-machines); [Easel forum](https://forum.easel.com/t/g-code-error-from-f-engrave/22247) (search excerpt)

**Tool changes**
- Vectric's "Visible Toolpaths To One File" "Requires that the selected toolpaths uses the same tool, or the use of an automatic tool changer". For manual changes, "a separate toolpath is needed for each cutter". The post checks for ATC support and that each different cutter has a different tool number, and errors otherwise — [Vectric V12.5 Save Toolpaths](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/Save%20Toolpaths/index.html)
- **[anecdotal]** Users hit "post doesn't support tool change" with the Shapeoko post bundled in VCarve. Community posts (e.g., by neilferreri) and a "Carbide Motion ATC" post were the fix. One user found two toolpaths sharing tool number 1 with different geometry — [Carbide 3D community: Aspire multi-tool issue](https://community.carbide3d.com/t/aspire-multi-tool-issue-for-shapeoko-post-processor/32508); [Carbide 3D community: Shapeoko 5 post question](https://community.carbide3d.com/t/post-processor-question-with-shapeoko-5/59073) (search excerpts). An older Shapeoko post dropped Z height on tool change — [Carbide 3D community: VCarve post for Shapeoko/Nomad](https://community.carbide3d.com/t/vcarve-post-processor-for-shapeoko-nomad/27082) (search excerpt)
- **[anecdotal]** Avid + Mach4 ATC. The Avid-provided post "is not right!", and the author's fix adds `M5`, a tool comment, `T[T]M6` and `G43 H[T]` to the TOOLCHANGE block — [corbinstreehouse.com](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-setup-vectric-vcarve-vectric-aspire)
- **[anecdotal]** Fusion. Spindle doesn't stop at a manual change unless `useToolChanger` is set to NO — [Autodesk forum: UCCNC](https://forums.autodesk.com/t5/fusion-manufacture/uccnc-post-processor-tool-change-doesn-t-stop-spindle/m-p/8129742). Fanuc-style `TxM6` vs `M6Tx` causes errors — [Autodesk forum: tool change syntax](https://forums.autodesk.com/t5/fusion-manufacture/post-processor-issues-w-tool-change-syntax/td-p/11536997). Staff offered to add an `M0` after the tool call so the machine pauses — [Autodesk forum: Mach3 post changes](https://forums.autodesk.com/t5/fusion-manufacture-forum/recent-changes-to-mach3-post-processor/m-p/9188895). A tool "crushed into the piece after a tool change" with a Fusion post — [V1 Engineering forum](https://forum.v1engineering.com/t/fusion-360-post-processor-crush-tool-into-piece-after-a-tool-change/8476)
- Fusion for Personal Use removes automatic tool changes: multi-operation posting works only "so long as they all use the same tool". Linking moves are capped at the cut feedrate, so no true rapids — [Autodesk: Fusion free license changes](https://autodesk.com/support/technical/article/Fusion-360-Free-License-Changes) (search excerpt)

**Arcs**
- **[anecdotal]** Carbide Motion/GRBL "arc endpoint error". Users say G2/G3 arcs are "poorly mathematically posed", so small numeric differences between CAM and controller cause errors. Suggested fixes: a metric G2/G3 post, or a tool like GCodeClean — [Carbide 3D community: arc endpoint error](https://community.carbide3d.com/t/error-1-error-in-line-20-arc-endpoint-error/6741?page=5); [Carbide 3D community: enable G2/G3 in non-Pro CC](https://community.carbide3d.com/t/enable-g2-g3-in-cc-non-pro-postprocessor/92849) (search excerpts). Carbide's supported-code list includes G2/G3 — [Carbide 3D supported G-codes](https://carbide3d.com/hub/faq/supported-gcodes)
- Vectric posts control arc linearisation with `MIN_ARC_RADIUS`/`MAX_ARC_RADIUS` — [Vectric V12.5 Post-Processor Editing](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html)

**Regressions after updates**
- **[anecdotal]** A 3-axis router user with manual tool change reported errors after Fusion's Feb 2025 update. Autodesk staff said the post seemed to be "missing the part of the code that handles tool changes" and asked if it was customised. Staff also noted that connection moves in machine simulation were now on for all simulation-capable posts — [Autodesk forum: Errors since Feb 2025 update](https://forums.autodesk.com/t5/fusion-manufacture-forum/errors-since-feb-2025-update/m-p/13387763)
- After a Vectric upgrade, custom posts must be copied to the new version's PostP folder and reselected — [Vectric V12.5 Post-Processor Editing](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html)

### Inferences
- **Best practice for first-run machine selection:**
  1. Pick the vendor and model from a catalogue (as Vectric's machine database does).
  2. Ask explicitly for the **controller** (on an Avid this matters: Mach4 vs EX/CNC12 need different posts) and the **controller's unit mode**.
  3. Ask for the **tool-change method** (manual with touch plate, manual without probe, ATC).
  4. Show a plain-language summary ("Output will be inches, G20; manual tool change pauses with M0 and re-probes Z").
- Never present an "inch" and an "mm" post as two equal list items. Units should be a machine/controller fact, checked at post time. The emitted file should always state `G20`/`G21` explicitly near the top.
- Mirror Vectric's hard error when tool numbers collide or when a multi-tool file is posted with a post that can't change tools. Extend it to manual change: the app should *require* a defined pause/re-zero sequence before it allows multi-tool files for a manual-change machine.
- The Easel case (CAM writing controller firmware settings because of a machine pick) is an anti-pattern for an app that wants to support any router safely. Read controller state only. Never write `$` settings or Mach4 profiles silently.

### Gaps
- No vendor support statistics on how often each failure occurs. Frequency here comes from forum prevalence, not data.
- I didn't find an official Avid CNC page listing its current posts for Vectric/Fusion/Mach4/CNC12 (search turned up blogs and forum posts only).

## 3. How do products let users edit posts (template text, JavaScript, Python, Lua, GUI settings)? Pros and cons for safety and maintainability

### Takeaway
There are four approaches, in order of increasing power and risk:
1. **GUI fields plus free-text snippets** (Kiri:Moto, Estlcam, Easel, LightBurn).
2. **Declarative template files** (Vectric `.pp`; CamBam reportedly XML).
3. **Full scripting** (Fusion/Carbide Create Pro JavaScript, FreeCAD Python, SheetCAM Lua).
4. **Structured machine config feeding a small set of maintained scripts** (FreeCAD 1.2's direction).

Every vendor that allows editing pairs it with a "take all precautions on first run" disclaimer and no automated safety net.

### Cited Findings
- **Vectric `.pp` (template):**
  - Structure: plain text with comment lines (`+` or `|`), upper-case global statements (`POST_NAME`, `FILE_EXTENSION`, `UNITS`, `LINE_ENDING`, `MIN_ARC_RADIUS`, `MAX_ARC_RADIUS`, `DIRECT_OUTPUT`, `LASER_SUPPORT`), `begin BLOCKNAME` sections (HEADER, TOOLCHANGE, NEW_SEGMENT, FEED_MOVE, FIRST_FEED_MOVE, CW/CCW arc and helical arc blocks, RAPID_MOVE, FOOTER, plus plunge, retract, dwell and drill), and `[X]`/`[F]`/`[T]` variables with format and multiplier syntax.
  - Testing advice: cut a simple line-and-circles file shallow, inspect the output in a text editor, change `POST_NAME` when you alter output, and restart. Syntax errors keep the post out of the list and report a line number.
  - Warnings: "Please take all necessary precautions when running the output from a modified post processor for the first time"; edit a copy in your user area, not the program folder.
  - [Vectric V12.5 Post-Processor Editing](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html)
- Vectric's manager offers **View**, **Changelog** (differences between versions) and **Customize** (editable copy) for each post — [Vectric V12 Post-Processor Management](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/form/post-processor-management/index.html)
- **Fusion `.cps` (JavaScript):** Posts are `*.cps` files. Autodesk's only stated verification step on the overview page is: "Use all necessary safety precautions when testing the NC file from any new post processor" — [Fusion help: Post Process overview](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSING-OVERVIEW.htm). The API reference is published at [Autodesk CAM Post Processor Documentation](https://cam.autodesk.com/posts/reference/). Autodesk's post-editing blog advises backing up the original, using a CNC simulator or a dry run with the machine in a safe state, and validating G-code line by line if necessary — [Autodesk blog: Quick introduction to editing post processors (2026 update)](https://www.autodesk.com/products/fusion-360/blog/a-quick-introduction-to-editing-post-processors) (search excerpt)
- **Fusion simulation depends on the post.** In Machine Builder, toolpath information passes through the post before display, so a post that isn't "simulation-ready" must be adjusted — [Autodesk blog: Machine Builder](https://www.autodesk.com/products/fusion-360/blog/learn-how-machine-builder-works-in-autodesk-fusion/) (search excerpt). Posts can hard-code axis limits: a DMG Mori post had built-in X/Y min/max values that needed editing to match the machine **[anecdotal]** — [Autodesk HSM post forum](https://forums.autodesk.com/t5/hsm-post-processor-forum/onsection-error-only-when-tyring-to-post-adaptive-tool-path/m-p/9024736)
- **Carbide Create Pro (JavaScript):** Supports custom JavaScript posts. You drop the file into the Posts folder (path shown in the About window), and it is reloaded each time you save G-code, so iteration is quick — [Carbide 3D Hub FAQ: Create Pro custom post processor](https://carbide3d.com/hub/faq/create-pro-custom-post-processor) (search excerpt only; returned 404 when fetched, so treat as unverified for the current version)
- **FreeCAD (Python):** "Post processors are implemented as python modules" named `<name>_post.py`. They derive from a base class in `Path/Post/Processor.py` and implement `export()`, `tooltip()` and `tooltipArgs()`. Old posts are wrapped by a `WrapperPost`. The design goal is to be "Simple enough for a novice user to customize for common changes" yet "Powerful enough to handle complex tasks" — [FreeCAD dev wiki: Postprocessing](https://github-wiki-see.page/m/sliptonic/FreeCAD/wiki/Postprocessing). Bundled posts include centroid, grbl, linuxcnc, mach3_mach4, dynapath and others — [FreeCAD wiki: CAM Postprocessor Customization](https://wiki.freecad.org/CAM_Postprocessor_Customization) (search excerpt; wiki blocked by bot wall)
- **SheetCAM (Lua):** Posts are Lua scripts with event functions such as `OnInit` and custom options via `post.DefineCustomOption`/`post.ShowCustomOptions` — [Example SheetCAM post](https://www.forum.linuxcnc.org/media/kunena/attachments/20660/SpaceShipPlasma-rev6-plasmac.scpost.txt)
- **Kiri:Moto (GUI + macros):** Free-text Header, Footer, Tool, Dwell and Spindle macros with variables such as `{top}` and `{left}`. "Not all macros are available in all contexts, so be careful!" — [Kiri:Moto docs: Machines](https://docs.grid.space/kiri-moto/CAM/machines); [Kiri:Moto GCode Macros](https://docs.grid.space/projects/kiri-moto/gcode-macros)
- **LightBurn (GUI + custom G-code):** A device-settings page for custom start/end G-code — [LightBurn 2.1 docs: Custom GCode](https://docs.lightburnsoftware.com/2.1/Reference/DeviceSettings/CustomGCode/)
- **Estlcam (GUI + texts):** Start, end and tool-change texts under Setup > CNC Programs > Texts. Units must match what the controller expects **[anecdotal guide]** — [davelers.com Estlcam setup](https://davelers.com/Workshop/CNC/Estlcam/Setup/)

### Inferences
- **Scripting (JS/Python/Lua)**
  - Pros: can handle any controller quirk.
  - Cons: posts become programs that users fork. Forks drift from upstream fixes, and a Fusion update can break or overwrite a customised post (sections 2 and 5). A post can also emit anything, including moves the CAM never simulated.
- **Templates (Vectric `.pp`)**
  - Pros: easy to diff and audit, and the vendor can show a changelog.
  - Cons: can't express logic such as "re-probe only if a touch plate exists", which pushes vendors to ship many near-duplicate files.
- **GUI + snippets**
  - Pros: the safest for novices.
  - Cons: free text can still inject dangerous code (e.g., G28 or probing). Context rules ("not all macros are available in all contexts") are invisible to users.
- **Recommendation for a native macOS app** (matches FreeCAD 1.2's stated direction):
  - A small set of **first-party dialect emitters**, compiled into the app and unit-tested.
  - Each emitter driven by a **typed, declarative machine/controller profile**: JSON or plist with schema validation covering units, arcs (on/off, plane, IJK vs R, max radius), tool-change strategy, safe-Z method (G53 vs work Z), comment style and line numbering.
  - **Constrained snippets** (header, footer, tool change) that are linted before posting: unknown codes flagged, plus rules such as no G28/G30 unless allowed, no M-codes that change units, and a warning on G92.
  - A sandboxed script escape hatch, if offered at all, should be clearly labelled unsupported.

### Gaps
- I could not read CamBam's post documentation (expired TLS certificate on cambam.info), so its XML macro model and its pros and cons are unverified.
- Official Carbide Create JS post API docs were unavailable (404).
- I found no published comparison of post-language safety. The pros and cons above are inference.

## 4. How are machine profiles shared: vendor-published files, community repositories, built-in catalogs; licensing of built-in catalogs

### Takeaway
Sharing happens through four channels:
1. Vendor cloud catalogues tied to an account (Vectric V&Co machine packages; Fusion Library with vendor filters and cloud/hub sharing).
2. Open repositories with pull requests (Kiri:Moto on GitHub, MIT licence; FreeCAD addons in 1.2).
3. Exportable bundle files (LightBurn `.lbdev`/`.lbzip`/`.lbvendor`; Kiri `.kmz`/`.km`).
4. Forum and blog downloads (most third-party Vectric/Fusion posts).

Licensing of the big catalogues is mostly unclear. Fusion posts carry an Autodesk copyright notice while Autodesk calls the library freely available.

### Cited Findings
- **Vectric:** Machine packages downloaded through a V&Co account bundle compatible posts and initial feeds and speeds. Search Machine Online and Install Offline Package are both supported — [Vectric V12.5 Machine Configuration Management](https://docs.vectric.com/docs/V12.5/Cut2DPro/ENU/Help/form/tool-database-machine-management/index.html). Post list updates need a logged-in V&Co account — [Vectric V12 Post-Processor Management](https://docs.vectric.com/docs/V12.0/Aspire/ENU/Help/form/post-processor-management/index.html)
- **Fusion:** Built-in Fusion Library of machines and posts. Posts are filtered by Vendor/Capabilities. Cloud posts are shared across a hub's users and computers, and Linked folders point at external directories — [Fusion help: Post Library reference](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POSTPROCESSOR-LIBRARY-REF.htm); [Fusion help: Post Process overview](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-POST-PROCESSING-OVERVIEW.htm). Third parties publish their own `.cps` files on GitHub, e.g., an Avid ATC post — [corbinstreehouse.com: Avid ATC post for Fusion](https://www.corbinstreehouse.com/blog/2023/05/avid-cnc-atc-post-processor-for-fusion-360/) — and a Centroid post — [Fusion Milling Post for Centroid](https://swissi2000.github.io/Fusion-360-Milling-Post-Processor-for-Centroid)
- **Fusion licensing:** Autodesk's support article reportedly calls the post library freely available and "open-source" — [Autodesk support: How to find or customize post processors](https://autodesk.com/support/technical/article/Request-for-post-processors-for-Fusion-360-or-HSM-product) (search excerpt; page returned 403). The post reference carries "Copyright (c) 2012-2025 by Autodesk, Inc." — [Autodesk CAM Post Processor Documentation](https://cam.autodesk.com/posts/reference/). A forum thread asking whether a modified post can be sold had no visible answer — [Autodesk forum: post processor license](https://forums.autodesk.com/t5/fusion-api-and-scripts/post-processor-license/m-p/12003844) (search excerpt)
- **Kiri:Moto:** Machine profiles are contributed by GitHub pull request to `GridSpace/grid-apps`, which is MIT-licensed. An example is a community PR adding V1 Engineering Lowrider/MPCNC profiles — [GridSpace/grid-apps](https://github.com/GridSpace/grid-apps); [V1e forum: default Kiri profile for V1e machines](https://forum.v1e.com/t/default-kiri-moto-profile-for-v1e-machines-lowrider-and-mpcnc/39289). Single-device `.km` export/import exists since v2.2.5, and you can drag and drop a profile to import it **[anecdotal]** — [V1e forum](https://forum.v1e.com/t/default-kiri-moto-profile-for-v1e-machines-lowrider-and-mpcnc/39289) (search excerpt). Machine vendors also host their own Kiri guidance — [V1E docs: Kiri](https://docs.v1e.com/software/kiri/)
- **FreeCAD:** Machine configuration `.fcm` files are "suitable for version control" and support "configuration sharing and backup" — [FreeCAD dev wiki: Machines](https://github-wiki-see.page/m/sliptonic/FreeCAD/wiki/Machines). Machines are an Addon type introduced with FreeCAD 1.2 — [FreeCAD Addon Academy: Machines](https://freecad.github.io/Addon-Academy/Topics/Types/Machines) (search excerpt)
- **LightBurn:**
  - **Formats:** 2.x exports a User Bundle (devices, settings, hotkeys, presets, libraries). `.lbdev` files "are not guaranteed to be backwards compatible", and importing a conflicting device creates a duplicate — [LightBurn 2.1 docs: Devices](https://docs.lightburnsoftware.com/2.1/Reference/Devices/); [LightBurn 2.0 migration guide](https://docs.lightburnsoftware.com/2.0/Guides/Migration/)
  - **Vendor distribution:** Laser vendors ship device files as "easy button" imports. One notes the file is a snapshot that must be re-exported after changes — [Thunder Laser: device profile import](https://support.thunderlaserusa.com/portal/en/kb/articles/thunder-laser-easy-button-for-device-profile-imports-to-get-offsets-basic-settings-additional-settings-and-device-profile-settings) (search excerpt)
  - **Syncing:** There's no simple way to sync settings between two computers — [LightBurn forum: shared drive settings](https://forum.lightburnsoftware.com/t/lb-settings-on-a-shared-drive-folder-for-use-on-two-computers/55532) (search excerpt)
- **Forum distribution of Vectric posts** is still common, e.g., the Onefinity download thread for Vectric ≤10.5 — [Onefinity forum: Vectric posts for 10.5 or older](https://forum.onefinitycnc.com/t/vectric-post-processors-for-10-5-or-older-versions-download-links-included/640/1)

### Inferences
- A new app can't legally assume it may bundle Fusion `.cps` posts or Vectric `.pp` files. Their copyright status is unclear or proprietary. Building first-party emitters from controller documentation, plus an open (e.g., MIT or CC0) machine-profile catalogue that accepts pull requests (the Kiri model), avoids that risk.
- Use a single-file, human-readable, schema-versioned profile format (JSON, as FreeCAD intends) with:
  - stable IDs, so imports update rather than duplicate (LightBurn's duplicate-on-conflict behaviour is a known annoyance);
  - an explicit `schemaVersion` with forward migration;
  - provenance fields (author, source URL, vendor-verified flag, last-tested date and firmware).
- Vendor-verified versus community profiles should look visibly different in the UI.

### Gaps
- I couldn't read the licence text for Autodesk's post library or Vectric's post files. Their redistribution terms are unknown.
- Whether FreeCAD's bundled posts and machines are LGPL (FreeCAD's general licence) was not confirmed from a source in this session.
- I found no machine vendor publishing a vendor-neutral, machine-readable profile (kinematics + limits) usable across CAM packages.

## 5. What run-time estimation or simulation uses machine parameters (acceleration, max feeds) in these products?

### Takeaway
Vectric is the only product found that documents acceleration in the machine configuration, and it uses it only for time estimates. Fusion's machining-time estimate uses feeds, path length, rapid feed and tool-change time, with no documented acceleration model. Users report it as badly off on 3D toolpaths. Fusion's machine simulation uses machine-definition travel limits for overtravel warnings, but staff said linear-axis limit violations were not always warned. Hobby tools only use bed size and max spindle RPM.

### Cited Findings
- **Vectric:** Machine configurations hold per-axis acceleration (XYZ in mm/s², in/s² and other units, plus rotary deg/s² or rad/s²), "only used to estimate toolpath times". The Machine Configuration dialog is reachable from the Estimating Machining Time form — [Vectric V12.5 Machine Configuration Management](https://docs.vectric.com/docs/V12.5/Cut2DPro/ENU/Help/form/tool-database-machine-management/index.html)
- **Fusion machining time:** "The machining time is the sum of the feed time, rapid time, and tool-change time", from tool feeds and speeds, toolpath distance, and rapid feed. Feed Scale scales cutting, lead and plunge feeds. Rapid Feed should come from the machine-tool maker. The page does not mention acceleration — [Fusion help: Machining Time](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/MFG-MACHINING-TIME-OVERVIEW.htm)
- **[anecdotal]** Fusion users say the estimate assumes full feed for every move, ignores acceleration and deceleration, and is "off by 2-10x" on 3D toolpaths — [Autodesk forum: Machining time estimates are junk](https://forums.autodesk.com/t5/fusion-manufacture-forum/machining-time-estimates-are-junk/td-p/7035875/highlight/true) (search excerpt). A developer said the "Machining time" dialog values take precedence over machine-definition settings — [Autodesk forum: Machine configuration not affecting time](https://forums.autodesk.com/t5/fusion-manufacture-forum/machine-configuration-not-affecting-time-cnc-mill-time/m-p/13423375) (search excerpt). On Personal licences, rapids are posted at the cut feed, which distorts estimates — [Autodesk: Fusion free license changes](https://autodesk.com/support/technical/article/Fusion-360-Free-License-Changes) (search excerpt)
- **Fusion simulation limits:**
  - **Source of the limits.** Overtravel warnings come from per-axis travel limits in the machine definition (a mentor's reply). They appeared only with "simulate with machine" **[anecdotal]** — [Autodesk forum: overtravel warnings](https://forums.autodesk.com/t5/fusion-manufacture/simulation-issues-dialog-box-overtravel-warnings/td-p/12743634); [follow-up](https://forums.autodesk.com/t5/fusion-manufacture-forum/simulation-issues-dialog-box-overtravel-warnings/m-p/12744578)
  - **Gap in coverage.** An Autodesk staff member said machine simulation did not warn when linear-axis limits were crossed — [Autodesk forum: Machine simulation linear axis limit](https://forums.autodesk.com/t5/fusion-manufacture/machine-simulation-linear-axis-limit/td-p/10557264) (search excerpt; thread dates from ~2021, current behaviour unverified)
  - **Simulation vs posted code.** **[anecdotal]** A user found the simulation looked correct while the posted G-code had X values doubled — [Autodesk forum: internal profile simulation does not match gcode](https://forums.autodesk.com/t5/fusion-manufacture/internal-profile-simulation-does-not-match-gcode/m-p/12804423) (search excerpt)
- **Kiri:Moto:** Uses workspace dimensions and Max Spindle (clamps S values). The docs page shows no feed or acceleration fields — [Kiri:Moto docs: Machines](https://docs.grid.space/kiri-moto/CAM/machines)
- **FreeCAD 1.2 machine model:** Max velocity per linear axis and max RPM per rotary axis. No acceleration field is mentioned — [FreeCAD dev wiki: Machines](https://github-wiki-see.page/m/sliptonic/FreeCAD/wiki/Machines)
- **Controller-side checks:**
  - **Avid EX (Centroid).** The controller makes a pass through the loaded G-code and flags a work-envelope violation before cutting **[anecdotal]** — [Avid CNC forum](https://forum.avidcnc.com/t/z-axis-work-envelope-exceeded-what-am-i-missing/4398)
  - **Grbl soft limits.** `$20` "Enables soft limits checks within machine travel and sets alarm when exceeded. Requires homing", and `$130`–`$132` define max travel from the homing switch — [Grbl v1.1 Configuration wiki](https://github.com/gnea/grbl/wiki/Grbl-v1.1-Configuration/f7a8ef43bd2bc0dab6e7cbdd31a05668d22d3394). Soft limits don't work if homing is disabled (`$22=0`) — [grblHAL docs: homing explained](https://petervanderwalt.github.io/grblhal_docs/Core-Concepts/homing-explained)
  - **gSender/Sienci.** Soft-limit alarms are explained as a jog or job exceeding the machine dimensions set in firmware. Sienci suggests repositioning stock and zero so the job fits — [Sienci support: Alarm 1 or Alarm 2](https://sienci.zendesk.com/hc/en-us/articles/41566952133524-Alarm-1-or-Alarm-2)

### Inferences
- A good estimator needs per-axis max feed, rapid and acceleration, and ideally the controller's junction or look-ahead behaviour. This is real differentiation, since Fusion's documented model omits acceleration and Vectric's is acceleration-only. Report the estimate as a range and let the user calibrate it from a measured run, which is what Fusion users do by hand.
- Simulate and back-plot the **emitted G-code** (re-parse the output file), not only the internal toolpath. The doubled-X Fusion case and the vendor verification literature (section 6) show the two can diverge.
- Envelope checks in CAM need the work-zero location relative to machine travel, which is usually unknown before setup. Practical checks:
  1. Check job extents (including retract heights and tool-change positions) against travel size. This fits or doesn't fit regardless of origin.
  2. Let the user optionally state where work zero will be (e.g., "front-left corner of stock at machine X=…").
  3. Check Z: deepest cut plus tool stickout against Z travel.
- Never rely on controller soft limits. Grbl only enforces them with homing on, and users often turn them off to max out travel.

### Gaps
- Estlcam, Carbide Create, MeshCAM, SheetCAM and CamBam time-estimation methods were not documented in sources found.
- No source confirmed current (2026) Fusion behaviour on linear-axis limit warnings, or whether Fusion machine definitions store per-axis acceleration.

## 6. Any published guidance or papers on post-processor verification and machine-specific G-code safety

### Takeaway
I found no peer-reviewed survey on post-processor verification in this session. Practical guidance comes from three places: vendor docs (Autodesk benchmark parts and dry cycles; Vectric's "simple test file, inspect output, take precautions"), the commercial verification industry (VERICUT/ICAM/NCSIMUL), and one concrete open-source practice: FreeCAD's golden-output unit tests for each post. The vendors' consistent message is "simulate the G-code the machine will run, not the CAM toolpath". That is a marketing claim, but it matches the forum evidence.

### Cited Findings
- **Autodesk testing guidance:** Post and run one operation at a time. Use the benchmark files in the Fusion "CAM Samples > Post Processor" folder. Load the benchmark NC code, "set offsets to a safe position and dry cycle the machine". If the control errors, check the post properties and the machine's programming manual — [Autodesk Post Processor Training Guide](https://cam.autodesk.com/posts/posts/guides/Post%20Processor%20Training%20Guide.pdf); [Fusion help page on testing (GUID-3F1D198D)](https://help.autodesk.com/cloudhelp/ENU/Fusion-CAM/files/GUID-3F1D198D-F647-48A4-BAB3-D4FD4813B0F8.htm) (search excerpts)
- **Vectric testing guidance:** Cut a simple line-and-circles test shallow, inspect the output in a text editor, rename `POST_NAME` when you change output, and "take all necessary precautions when running the output from a modified post processor for the first time" — [Vectric V12.5 Post-Processor Editing](https://docs.vectric.com/docs/V12.5/Aspire/ENU/Help/form/post-processor-editing/index.html)
- **FreeCAD golden-output tests:** `TestMach3Mach4Post.py` generates G-code via `post.export()` and `assertEqual`s it against expected strings. It covers:
  - default precision (3 decimals) and `--precision=2`;
  - `--inches` emitting `G20` with converted coordinates (e.g., `"G0 X0.3937 Y0.7874 Z1.1811"`);
  - line numbers, preamble and postamble, comment pass-through;
  - modal suppression;
  - the tool-change sequence `M5`, `M6 T2`, `G43 H2`, and `--no-tlo` dropping G43.

  The header is checked only by line count because it contains a timestamp — [FreeCAD source: TestMach3Mach4Post.py](https://raw.githubusercontent.com/FreeCAD/FreeCAD/main/src/Mod/CAM/CAMTests/TestMach3Mach4Post.py). Tests run with `FreeCADCmd -t TestCAMApp` — [FreeCAD dev wiki: Postprocessing](https://github-wiki-see.page/m/sliptonic/FreeCAD/wiki/Postprocessing)
- **Why verify post output separately (trade and vendor sources; treat as marketing):**
  - **Two error sources.** Program errors are a common cause of crashes, coming from programmer mistakes and "errors introduce[d] by the CAM system's post-processor" — [Modern Machine Shop: The value of double-checking your programs](https://mmsonline.com/articles/the-value-of-double-checking-your-programs) (search excerpt)
  - **Verify the real NC code.** A Siemens-linked patent says path verification should ideally use "the actual NC codes that will eventually be fed to the machine's controller" — [US Patent 8577655](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/8577655) (search excerpt)
  - **Same G-code as the machine.** VERICUT says it simulates "the same post-processed G-code that runs on your machine" — [VERICUT Verification](https://vericut.com/products/vericut-verification). ICAM's Virtual Machine shares one database between post-processor and simulation — [ICAM Virtual Machine](https://vericut.com/products/icam-virtual-machine) (search excerpts)
  - **Post-driven simulation questioned.** A trade article asks "how can you trust a post-processor driven simulation?" — [OEM Update: G-code verification](https://oemupdate.com/machine-tools/g-code-verification-what-are-you-really-checking) (search excerpt)
  - **Case study.** Jobs that looked error-free in CAM simulation showed collisions in NCSimul — [MMS: Simulation software helps shop prevent costly errors](https://www.mmsonline.com/news/simulation-software-helps-shop-see-prevent-costly-errors) (search excerpt; single vendor-sourced case)
  - **Discrete checks.** Collision checks done only at discrete positions can miss collisions between them; swept-volume checks avoid this — [ETMM: How machining processes can be accurately simulated](https://www.etmm-online.com/how-machining-processes-can-be-accurately-simulated-and-verified-a-1028821/) (search excerpt; attribution between this and a similar MoldMaking Technology article is uncertain)
- **Open-source G-code simulator:** CAMotics simulates 3-axis G-code and renders the result in 3D. It is GPLv2 and available for macOS — [LinuxLinks: CAMotics](https://www.linuxlinks.com/camotics-3-axis-cnc-gcode-simulator/) (search excerpt). Users say a critical simulator function is stepping through the program line by line — [CAMotics users group](https://groups.google.com/g/camotics-users/c/GYs3GpfI_MM) (search excerpt)
- **Responsibility disclaimers:** Community posts come "with no guarantees that it will run the machine in a safe manner or at all" **[anecdotal]** — [Autodesk forum: SCM Record 220 post](https://forums.autodesk.com/t5/hsm-post-processor-forum/post-for-a-scm-record-220-with-num-1080/m-p/6477028) (search excerpt)

### Inferences

**Verification pipeline for a native macOS app**
1. **Golden-file tests per dialect emitter.** Fixed toolpaths (line, arcs in each quadrant, helix, multi-tool job, inch and mm) go through each emitter and are compared byte-for-byte against checked-in `.nc` files, as FreeCAD does but with whole-file golden outputs and timestamps stripped. Any change to an emitter or profile shows as a reviewable diff. This is also the mechanism for safe post updates: show users the output diff, not just a changelog (Vectric shows only a text changelog).
2. **Round-trip check.** Re-parse the emitted G-code with an in-app interpreter that models the target controller's modal state (units, G90/G91, plane, tool length offset). Compare the resulting motion to the internal toolpath within a tolerance. This catches the doubled-X class of bug and unit errors before the file leaves the app.
3. **Lint rules for each controller**, for example:
   - an explicit units code in the first N lines that matches the controller's unit mode;
   - no G28/G30 unless the profile allows it;
   - arcs: radius consistency (start and end distances to centre within the controller's tolerance — the Grbl "arc endpoint error" class);
   - a tool change sequence present for every new T on a manual-change machine (spindle stop, pause, re-zero prompt);
   - F and S within machine maxima;
   - first move after a tool change is a safe-Z retract.
4. **Envelope check** of the emitted file against machine travel (section 5).
5. **Dry-run aid:** an optional "air cut" variant of the file with Z offset upward by a user-chosen amount, plus a printed setup sheet. This mirrors Autodesk's "set offsets to a safe position and dry cycle" advice.
6. **Avoid known bad patterns:** silently writing controller settings (Easel); overwriting user-customised posts on update (Fusion); version-incompatible profile files (LightBurn).

**Safety warnings to show at post time**
- The post's units differ from the controller's declared units.
- The selected post's controller family differs from the machine's controller (e.g., Mach4 post on an EX/CNC12 machine).
- A multi-tool job is being posted to a manual-change machine without a pause/re-zero sequence.
- Arcs are on for a controller flagged as arc-sensitive.
- The job is larger than the travel.
- The spindle RPM requested exceeds the maximum.

### Gaps
- No academic papers or standards documents on post-processor verification were found. Searches returned vendor and trade-press material only. ISO 6983 (G-code) and ISO 14649 (STEP-NC) were not researched here. A follow-up in IEEE Xplore/Elsevier/Springer ("NC verification", "post-processor validation") is needed for scholarly backing.
- No source documented any hobby CAM product (Vectric, Carbide Create, Easel, Estlcam, Kiri) doing automated checks of its own G-code output against machine limits. The Vectric ATC/tool-number check is the only built-in post-time validation found.
- No source found for how Mach4 specifically handles soft limits or pre-scan envelope checks (relevant to the user's Avid PRO6060 + Mach4 setup). The Avid envelope pre-scan evidence is from the EX/Centroid controller, not Mach4.
