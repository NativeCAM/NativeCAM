# Using NativeCAM

[← Back to the README](../README.md)

- [Workflow](#workflow)
- [Supported files](#supported-files)
- [Keyboard and mouse](#keyboard-and-mouse)
- [Toolpaths and features](#toolpaths-and-features)
- [Leads and corners](#leads-and-corners)
- [Rest machining](#rest-machining)
- [V-carve inlays](#v-carve-inlays)
- [Rotary jobs](#rotary-jobs)

## Workflow

| Step | Where |
|---|---|
| **1. Set up the job** | Select **Material & Machine** in the sidebar. Set the material size and thickness, XY and Z zero, heights, and your machine (pick a saved one or [set up a new one](machines.md#setting-up-a-machine)). |
| **2. Add artwork** | Use the shape button in the toolbar for rectangles, circles, ellipses, polygons, stars and text (any installed macOS font), or import a file with **⌘I** or by dropping it on the canvas. |
| **3. Pick bits** | Open the **Tool Library** (**⇧⌘T**) to add or edit bits: flat, ball, bull nose, V-bit, engraving, surfacing and drill, with full geometry and feeds and speeds. |
| **4. Create toolpaths** | Select vectors, then use the toolpath button in the toolbar or right-click them. Toolpaths run in sidebar order; drag to reorder, or choose **Toolpaths ▸ Optimize Run Order** for the fewest tool changes (**⌘Z** puts the old order back). |
| **5. Review checks** | Warnings appear under **Checks** in the sidebar as you edit. |
| **6. Simulate** | **⌘R** plays the material-removal simulation; **⌘.** stops it. |
| **7. Export** | **⌘E** checks and saves the file for your controller (`.tap` for Mach4, `.nc` for Grbl, `.sbp` for ShopBot, and so on; one file per tool where the controller can't stop for a tool change). **File ▸ Export Air Cut…** (**⌥⌘E**) saves the same program with every Z raised, to run above the material first. **File ▸ Export Setup Sheet…** saves a printable page for the person at the machine. See [Export checks, air cuts and setup sheets](controllers.md#export-checks-air-cuts-and-setup-sheets). |

Load the file on your controller, zero X/Y, touch off Z and air-cut it before cutting material.

## Supported files

| Kind | Formats | Notes |
|---|---|---|
| Vectors | **DXF** | Lines, arcs, circles, polylines with bulges, splines, ellipses, blocks and inserts, `$INSUNITS`. POINT entities become drill marks. Loose segments are chained into closed loops. |
| | **SVG** | Full path grammar, transforms, viewBox units |
| | **PDF**, **Illustrator `.ai`** | PDF-compatible `.ai` files. Handles nested groups, page rotation and the crop box. Clipping masks trim what they cover, and hidden layers are left out, as a PDF viewer shows them. |
| 3D models | **STL** (binary/ASCII), **OBJ**, **3MF**, **USDZ/USD**, **PLY** | 3MF includes Bambu and Prusa multi-part files. Choose the up axis, flip, size, carve depth and how far below the surface the top sits. |
| G-code | **`.tap`**, **`.nc`**, **`.gcode`**, **`.ngc`**, **`.cnc`**, ShopBot **`.sbp`** | Opened for simulation only (**File ▸ Simulate G-code File…**, or drop on the canvas). Drilling cycles (`G73`, `G81`–`G83`, `G85`, `G86`, `G89`) are expanded into the moves the controller makes. |
| Machines | Mach4 **`Machine.ini`**, Grbl **`$$`** output, **LinuxCNC** INI, **FluidNC** `config.yaml`, **Fusion 360** `.mch` | Speeds, accelerations, travel and spindle range for a machine. See [Importing controller settings](machines.md#importing-controller-settings). |
| Posts | Your own **Vectric `.pp`** | Writes G-code for a controller NativeCAM has no post for. See [Using your own Vectric post](controllers.md#using-your-own-vectric-post). |
| Tool libraries | **Fusion 360** `.tools` / `.json`, **Vectric** `.vtdb`, NativeCAM `.json` | **Tool Library ▸ ⋯ ▸ Import Tools…** lists the bits by the library's folders. Search, filter by type and tick the ones you want. Vendors such as Amana Tool publish their bits in these formats. Values a library leaves out (Vectric files have no cutting or shank lengths) are read from the bit's name where possible, otherwise filled conservatively and marked ⚠ (details in the tool's notes). Tapered ball nose, form, dovetail, roundover and thread bits are listed as not imported. Vectric's older `.tool` files aren't supported. |
| Projects | **`.nativecam`** | JSON document. Projects for any controller other than Avid's Mach4 profile, or with an imported post, are saved as format 2, and projects with rotary stock as format 3, format 4 when the blank is turned by hand, format 5 when designs wrap around it or it has a spiral or a rounding toolpath, or format 7 when a 3D model sits on it or it has a 3D rotary finishing toolpath. Older builds refuse to open a format they don't know rather than silently writing the wrong G-code. |

## Keyboard and mouse

| Action | How |
|---|---|
| Select | Click a vector's line (for text, click inside a letter). Shift- or ⌘-click to add or remove. |
| Marquee select | Drag on empty canvas in Top view |
| Move | Drag selected vectors, or nudge with the arrow keys (Shift moves 10×) |
| Orbit | Drag empty canvas in 3D views, or Option-drag anywhere. Trackpad rotate spins the view. |
| Pan / zoom | Two-finger scroll or right-drag / pinch or scroll wheel |
| Context menu | Right-click or Control-click a vector to add toolpaths, duplicate, center on material or change views |

| Shortcut | Command | | Shortcut | Command |
|---|---|---|---|---|
| ⌘I | Import | | ⌘1 / ⌘2 / ⌘3 | Top / Front / Iso view |
| ⌘E | Export G-code | | ⌘0 | Zoom to fit |
| ⌥⌘E | Export air cut | | ⌥⌘I | Show or hide inspector |
| ⌘R | Simulate | | ⇧⌘T | Tool library |
| ⌘. | Stop simulation | | ⌘D | Duplicate |
| ⇧⌘R | Recalculate all toolpaths | | | |

## Toolpaths and features

| Area | Details |
|---|---|
| Stock | Material size and thickness, XY zero at any corner or the centre, Z zero on the material top or the spoilboard, safe and plunge heights, park position. Inches or millimetres. Or a round or square [rotary blank](#rotary-jobs). |
| Profile | Inside, outside or on the line; climb or conventional; multi-pass; ramp entry; arc or line leads in and out; dogbone or T-bone corners; tabs; allowance; holes cut before outside profiles. See [Leads and corners](#leads-and-corners). |
| Pocket | Offset or raster clearing, islands, safe feed links between regions, dogbone or T-bone corners. Inner clearing rings get rounded corners (within a set tolerance, 0.25 mm by default); the wall pass stays exact. [Rest machining](#rest-machining): a larger end mill clears the pocket first, and the pocket's own bit cuts only the corners and narrow parts it can't reach, then the walls. |
| Drill | Peck, chip-break and dwell. Canned cycles are expanded into plain moves. |
| V-carve | Maximal inscribed circles. **Start depth** carves as if the material top were lower (to carve inside an existing pocket, or for an inlay plug). **Flat depth** caps the carve, measured down from the start depth as in Vectric VCarve, so the deepest cut is start depth + flat depth. The flat bottom is cleared by an end mill you choose (cut first, and skipping depths an earlier pocket cleared) or, without one, by the V-bit itself, in passes close enough to leave ridges of about 0.1 mm. Multi-pass, counted down from the start depth. [Inlay](#v-carve-inlays) pockets and plugs. |
| 3D roughing | Layered clearing with an end mill, leaving an allowance for finishing. Layer outlines follow the surface between grid samples instead of stepping cell by cell, so the machine doesn't crawl through stair-step corners. Machine inside the model outline, inside **selected vectors** such as the cut-out outline (chosen automatically when a cut-out surrounds the model, so scrap isn't machined), or across the whole material. |
| 3D finishing | Raster passes with an exact triangle drop-cutter for ball and flat bits, so steep walls aren't gouged. Shows scallop height. Same boundary choices as roughing. |
| Arc fitting | Line segments are re-fitted to arcs, helical ones included (for controllers that take arcs) |
| Links between cuts | **Minimum** (default): rise just above the remaining material plus a safe distance, feed straight across short stretches already cleared to depth, and rapid down to just above floors this job already cut. **Full** always returns to safe Z. Shapes marked as clamps raise an error if a toolpath cuts into them, and links cross them above their height. Profiles skip depths an earlier toolpath already cleared. |
| Cut order | Holes, profile loops and V-carve strokes are ordered by nearest neighbour and then improved by local search (2-opt, Or-opt); closed loops are entered wherever they're nearest the tool. Across toolpaths, **Optimize Run Order** finds the order with the fewest tool changes that keeps the work inside each part before its cut-out, roughing before finishing, and your order wherever toolpaths overlap. Toolpaths next to each other that clear with the same bit first (rest-machined pockets, V-carve flat clearing) do all that clearing before any of them changes to its own bit. |
| Job checks | Cuts into the spoilboard or a clamp, depth beyond flute length, toolpaths outside the work area, rapids through material, out-of-range feeds or RPM, chip loads too thin for the material (with a one-click recommended feed), a run order that cuts a part free too early, two different bits sharing one tool number (which would skip a tool change and cut with the wrong bit), a pocket's clearance tool that's no larger than its own or that reaches the whole pocket anyway, and a V-carve inlay plug that won't seat in its pocket. The exported file is checked too; see [Export checks](controllers.md#export-checks-air-cuts-and-setup-sheets). |
| Run-time estimate | See [Run-time estimates](machines.md#run-time-estimates). |
| Tools | Flat, ball, bull nose, V-bit, engraving (tip diameter), surfacing and drill. Flute length, shank, stickout, flute count and direction, feeds and speeds, chip-load calculator checked against chart chip loads for the material type, compression bits whose first pass clears the upcut length, live profile drawing, import from Fusion 360 and Vectric libraries. Saved to `~/Library/Application Support/NativeCAM/tools.json`. |
| Simulator | A Metal-rendered heightmap carved by the true tool shape (flat, ball, bull nose, V), with through-cuts, a tool marker, play, pause, scrub and speed control, timed like the real job, and detection of rapids through material. Rotary jobs are carved face by face on a turning blank. It also simulates G-code and ShopBot files from other programs. |

## Leads and corners

**Leads** (Profile ▸ Leads) start and end each closed loop of an inside or outside profile with a short move in the waste, so the bit never plunges or stops against the finished edge.

- **Arc** comes onto the cut on a tangent arc (**Radius** and **Sweep**). **Line** comes in straight at an **Angle** to the cut (90° comes in square).
- **Lead out** leaves the loop the same way. **Overlap** runs the last lap a little past its start first, to hide the seam.
- With a plunge entry, the bit plunges at the far end of the lead, in the waste. With a ramp entry, the ramp runs down the lead and on along the wall. Between passes the tool feeds straight back to the lead's start at the depth it just cut, so a ramped cut never plunges.
- Each loop is entered where it's nearest the tool and a lead fits. Leads stay on the waste side, on the material and clear of clamps. They shrink, down to a quarter of the bit's radius, to fit small holes and tight gaps. A loop with no room for one is entered without a lead, and **Checks** says how many.
- When a profile starts below the top because an earlier toolpath cleared it (a finishing pass after roughing), leads only go where that toolpath cleared, so they may come out short.
- Leads only know about the shapes in their own toolpath. Put parts that sit close together in one profile toolpath, or use a smaller lead.

**Corner reliefs** (Profile and Pocket ▸ Corners) cut just past each inside corner the bit can't reach, so square tenons, tabs and finger joints fit.

- **Dogbone** cuts into the corner along its bisector until the bit's edge touches the drawn corner. On a square corner that goes about 0.29 × the bit's radius past each wall.
- **T-bone** cuts past the corner along one wall, so the notch is only in the other wall. **T-bone side** puts it in the **Longer side** (the default), the **Shorter side**, or the sides along X or Y. T-bones suit slots about as wide as the bit, where dogbones would overlap.
- **Corners up to** is the widest corner that's relieved, measured across the cut-away area: a square corner is 90°. The default, 120°, includes hexagons. Flatter corners and faceted curves are left alone.
- Profiles relieve the inside corners on either side of the line: the corners of an inside cut, and the inside corners of an outside cut (finger joints, notches, the holes in a part). Pockets relieve the corners of the wall and the inside corners of islands. Corners rounded at least as much as the bit, and the pinch where an island comes closer to a wall than the bit is wide, are left alone.
- Allowance is left in the corner too. Very sharp corners get long reliefs that reach well into both walls, so check the preview.
- **Corner by corner:** with the toolpath selected, each relieved corner is circled on the canvas, at the bit's position at the end of the relief. Click a circle to step that corner through dogbone, T-bone into one side, T-bone into the other, and no relief. Right-click it to pick one, or **Use Toolpath Setting** to go back. Corners you've changed are drawn in the accent colour, and a relief that would cut into nearby geometry gets an orange cross. The choice belongs to the corner of its shape, so it follows the shape when you move, turn or scale it. **Corners ▸ Reset** clears them all.

## Rest machining

**Pocket ▸ Rest machining ▸ Clear with a larger tool first** clears a pocket with a big end mill and sends the pocket's own, smaller bit only where the big one can't reach: the corners, slots narrower than the big bit and the gaps round islands. On a machine with manual tool changes that's one extra collet swap for much less time with the small bit, instead of pocketing everything with it.

- The **Larger tool** cuts first, with the pocket's strategy (offset or raster) and its own stepover, pass depth and feeds from the tool library. It leaves the allowance plus a tenth of the small bit's diameter (at most 0.01 in) on the walls, so the small bit cuts the whole wall and there's no step where the two bits meet.
- The pocket's own bit then clears what's left with offset rings, overlapping the big bit's cut a little so no slivers stay behind, and makes the final pass round the walls and islands, with any corner reliefs, at each of its pass depths. The result is the same pocket the small bit would cut on its own.
- The two bits are two toolpaths in the output, **Pocket – clearing** and **Pocket**, the clearing drawn in a paler shade of the toolpath's colour. The inspector's **Result** gives each one's time, and the setup sheet says what each bit cuts.
- Pockets next to each other in the toolpath list that clear with the same big bit clear all their pockets with it first, then finish them all with their own bits, so three pockets cleared with a 1/2" bit and finished with a 1/8" one load each bit once. **Optimize Run Order** brings such pockets together.
- **Checks** warns when the larger tool isn't larger than the pocket's, isn't a flat end mill, doesn't fit in the pocket (the small bit then clears it all), or reaches the whole pocket (a round pocket, say), where the big bit alone would do and save a tool change.
- Projects with rest machining open in older builds, which cut the pocket with its own bit alone.

## V-carve inlays

A V-carve inlay is a plug of contrasting wood glued into a V-carved pocket, then planed flush. Both sides come from one design and one V-bit: the **pocket** (female) is carved into the main board, and the **plug** (male) carves away the wood *around* the mirrored design on a second board, so the design stands proud. Turned over and pressed in, the plug's sloped walls meet the pocket's all the way round. The settings follow Vectric's VCarve Inlay toolpath, so its tutorials and recipes carry over.

1. **Pocket.** Select the design, add a V-carve and set **Inlay** to **Pocket**. Give it a **Flat depth**, the pocket depth P (0.2 in is a common start), and an end mill under **Clear flat area with**. Narrow parts are carved as a plain V; wider parts get a flat floor at P.
2. **Plug.** Add a second V-carve on the *same* design, set **Inlay** to **Plug**, and use the same V-bit. Picking Plug copies the pocket's flat depth, V-bit and clearance tool. The plug is mirrored left to right inside the toolpath, about the centre of the design, so leave the design as drawn: the shapes on the canvas don't change.
   - **Pocket depth** (P): the pocket's flat depth. **Checks** warns when they differ.
   - **Glue gap** (G): the gap left between the plug's face and the pocket's floor. 0.02 in (0.5 mm) is typical.
   - **Surface clearance** (C): how far the plug board's carved floor stays above the pocket board's surface when the walls meet. It leaves room to clamp the plug in and is the waste you saw or plane off. The default is 1/16 in.
   - **Boundary**: where the carving round the design stops. **Margin** carves the **Boundary margin** past the design's outline. **Selected vector** carves inside a closed vector you select with the design for the plug toolpath (a rectangle the size of the plug board, say): the one that goes round all the others, shown as the **Boundary vector**. It's a choice rather than a guess because a design can have a shape round the rest of it too, like a frame.
   - The plug is carved from its **start depth** S = P − G down to S + C, both shown in the inspector. At depth S its walls lie exactly on the mirrored outline, and above that they lean in at the bit's angle, as the pocket's do. Flipped into the pocket, the walls meet when the plug's face is S deep, which leaves P − S = G under it.
3. **Cut them on separate boards.** Turn off **Include in output** on one side and export the other, then swap. **Checks** warns if both would be cut in one file on top of each other. Saw the plug free inside the carved band, glue it into the pocket face down, clamp, then plane or sand it flush.

Without a clearance tool the V-bit clears the flat areas itself, in rings close enough that the ridges between them stay under the glue gap. It's slower, so use an end mill for large areas. On an inlay, the V-bit also cleans up the corners and narrow places the end mill can't reach, so nothing stands proud of the pocket's floor or the plug's.

**Checks** warns when the plug won't seat: a different V-bit angle or tip from the pocket's, a pocket depth that doesn't match the pocket's flat depth (with the gap the plug would really get, or a warning that it bottoms out before its walls meet), no glue gap or one too small for the V-bit's clearing ridges, no surface clearance, a plug cut deeper than the bit's V is tall, or a V-bit with a flat tip (narrow parts of the plug then come out taller than the pocket's grooves). The setup sheet lists each inlay toolpath's side and depths.

**Start depth** on any V-carve carves as if the material top were lower. On a plug it's set by the pocket depth and glue gap. Elsewhere, use it to carve inside an existing pocket (enter the pocket's depth), or to drop an inlay pocket into a recess: **Flat depth** is then measured from the start depth, as in Vectric VCarve.

## Rotary jobs

NativeCAM cuts rotary work two ways. **On faces** (indexed, 3+1), the blank turns to a fixed angle, the router cuts the face on top, then the blank turns to the next angle. **Wrapped around**, the design sheet wraps around a round blank, and the blank turns while the router cuts: text and patterns around a rolling pin, flutes, spirals. On either layout, **3D rotary finishing** turns a 3D model (a table leg, a baluster, a chess piece) all the way round as the blank turns. **File ▸ New Demo Rotary Project (3D)** opens a chess pawn ready to cut.

1. **Machine.** Turn on **Rotary axis** under **Material & Machine ▸ Rotary Axis**, or in the setup step of **Set Up a Machine…**. NativeCAM drives an A axis along X so far. Measure the **Centre height** (the chuck centre above the spoilboard) so the job can be checked against the Z travel. To check **Reversed**, jog A positive: the top of the blank should roll toward −Y. Get this right before a wrapped job, or wrapped designs come out mirrored. Set the **Turn speed** (degrees per minute; on Mach4, Configure ▸ Control ▸ Motors, the A motor's velocity) and the run-time estimate and the simulation time each turn with it; until then they assume 90° a second.
   - **Turn by hand.** For a machine that can't drive the axis (Grbl, FluidNC, Carbide Motion and Masso have no A axis in NativeCAM), or a hand-cranked indexer, turn on **Turn by hand**. Before each new angle the program lifts to safe Z, stops the spindle and pauses (`M0`) with a comment such as "Turn the blank to 90°, then Cycle Start"; Cycle Start (or Resume in your sender) starts the spindle again and carries on. Every file starts with a pause that asks for its first angle, so a job split into one file per tool never assumes where the last file left the blank. Angles count up as the top of the blank rolls toward −Y; if your indexer counts the other way, turn on **Reversed** and each pause asks for your indexer's reading. Each turn by hand counts as 30 seconds in the run-time estimate. Wrapped jobs need a driven axis.
2. **Blank.** Turn on **Material ▸ Rotary blank**, then set the shape (round or square bar), the diameter or the size across the faces, and the length. Then choose how designs sit on it under **Designs**:
   - **On faces:** the design sheet becomes one face of the blank: as wide as the blank is long, as high as its diameter, with the axis under its middle and the thickness down to the axis.
   - **Wrapped around** (a round blank, or a square bar with a Rounding toolpath first): the design sheet becomes the blank unrolled: as wide as the blank is long and once round it high (π × the diameter). The line across the middle of the sheet is the top of the blank at A0, and the sheet's top and bottom edges meet at the seam. Shapes that run past the seam carry on round, so a line drawn longer than the sheet is high becomes a spiral. Designs come out true to size at the **Wrap diameter**: the blank's diameter, or the finished size if it's turned down first.

   Width, height and thickness follow the blank, and safe Z rises to clear a square bar's corners as it turns.
3. **Zero.** Z zero is on the rotation axis and Y zero on its centreline (on Avid, Rotary tab ▸ Z Axis Touch and Y Axis Touch). X zero is the left end, the middle or the right end of the blank. On a square bar, A zero must put a face square to the spindle. Rotary jobs park over the middle of the blank.
4. **Toolpaths.**
   - **On faces:** profile, pocket, drill and V-carve toolpaths list the angles the blank turns to, in cutting order, under **Index Angles**, and cut the same shapes at each. **Spread evenly** fills in n faces 360°/n apart. A square bar only takes quarter turns (0°, 90°, 180° and 270°). The blank turns with the tool at safe Z. A V-carve with flat-area clearing clears every face first, then carves every face, so the job changes tools once rather than at each face. On a round blank, **Checks** warns when a cut reaches far enough from the top line of the face that the surface falls away under it; a V-carve there comes out shallower and narrower than drawn.
   - **Wrapped around:** profile (on the line for engraving), pocket, V-carve and drill toolpaths. Each shape is cut at the angle its height on the sheet gives, and holes are drilled straight in toward the axis. Pocket walls along the blank point at the axis rather than staying parallel, as with any wrapped pocket. Wrapped toolpaths go up to safe Z between cuts, and turns of more than 90° are split into pieces so a controller that takes the short way round still turns the right way.
   - **Spirals** (rope and barley twists): on a wrapped job, **Add Shape ▸ Spiral** adds lines that climb once around the blank per **Pitch** along it, with any number of **Starts** and a right- or left-hand **Twist**. They follow the sheet when the wrap diameter changes. Cut them on the line with a ball nose or V-bit.

   - **3D models** (either layout): an imported model (STL, OBJ, 3MF, USDZ) on a rotary blank lies along the rotation axis, centred on it, scaled to fit the blank and placed in its middle. Its outline on the sheet is the model seen from the side. In the inspector, **Along the blank** picks which of the model's own axes runs along the blank (its longest, to start with), **End for end** turns it round, **Turn** turns it about the axis (which side is on top at A0), and **Length**, **Diameter** and **Middle (X)** size and place it. **Fit to Blank** makes it as wide as the blank is round and no longer than the blank less half an inch at each end; **Actual Size** shows it as drawn. The 3D view shows the model on the blank.
   - **3D rotary finishing** (either layout): select the model, then **Add Toolpath ▸ 3D Rotary Finishing**. A ball nose follows the model all the way round with an exact drop-cutter (the model turned to each angle and the tool dropped onto it), so it never cuts into the model at the points it's dropped at, and a move whose middle would dip into it is split. **Pattern**: **Spiral** (one continuous helix along the blank, a stepover per turn, with a full turn at each end, so there's no seam), **Rings** (a turn at one station, then a step along the blank) or **Along X** (passes along the blank, stepping round by the stepover at the model's largest radius; often quicker when the rotary is slow). The inspector shows the stepover in millimetres or inches and the scallop it leaves. **Allowance** leaves material on the model. **Start** and **End** default to the model's ends, with the cutter kept inside the blank's. **Sample spacing** (along the blank) and **Angle step** (round it; by default the sample spacing at the model's largest radius) set how closely the tool is dropped. Where the model is deeper below the stock than the **Pass depth** (the bit's stepdown unless set), layers cut down to it first, each following the model no closer to the axis than its own radius and leaving out what would only cut air, at the **Layer stepover** (40% unless set); a Rounding first saves the layers from cutting a square bar's corners or a blank bigger than the model. The feed comes down where the rotary axis couldn't otherwise keep up: near the axis, a full-speed cut would need the blank to turn faster than its **Turn speed**, and **Checks** says how slow it gets (set the turn speed for a real figure). **Checks** also warns when the model doesn't fit the blank or is too close to its ends, when parts of it are hidden from a tool coming in toward the axis (undercuts) or the axis isn't inside it, when the collet could hit the blank (the bit's stickout against the deepest cut), when a pass is deeper than the flutes, and when it starts from a square bar with no Rounding first. Other bit shapes are followed as if they were flat end mills of their diameter: safe, but they leave material in hollows. The setup sheet lists the model each finish follows and how. Keep a short stub at each end of the model (the demo pawn has one) so the part stays held between the chuck and the tailstock; part it off by hand.
   - **Rounding** (either layout): **Add Toolpath ▸ Rounding** turns a square bar round, or a round blank down to a smaller diameter, in layers no deeper than the **Layer depth**. **Finished diameter** is the wrap diameter on a wrapped job and the blank's own (across the faces) otherwise. **Around** cuts each layer as a spiral along the blank; **Along** makes passes parallel to the axis, stepping round between them, which is often quicker when the rotary is slow and skips the faces of a square bar until the layers reach them. **Start** and **End** set how much of the blank it rounds; by default the cutter stays just inside its ends. Rounding needs no shapes and always runs first (**Optimize Run Order** puts it there).

   On a wrapped sheet a dashed green line marks the top of the blank at A0, and dashed orange lines along the top and bottom edges mark the seam.

   A rotary program turns the blank back to A0 at the end. After more than ten turns (a long rounding pass), it stops on the nearest whole turn instead of winding them all back, and says so at the end of the file: zero A (on Avid, Rotary tab ▸ Zero A) before the next job.

**Checks** lists anything the job can't cut. A wrapped design is exact only at the wrap diameter: deeper in, the same angle spans less, so a cut deeper than a tenth of the radius gets a warning with how much narrower it comes out at the bottom.

**Feeds on wrapped toolpaths.** When the blank turns during a cut, the right feed depends on how far the tool is from the axis. NativeCAM writes those moves in inverse-time mode (`G93`): each line's F is one over its time in minutes, worked out from the length of the path the tool tip traces. That's what Avid's own wrap posts do. Moves that don't turn the blank stay in `G94` with an ordinary feed, and `G94` is back on before every tool change and the program end. Controllers whose rotary feeds aren't documented and that don't take `G93` (Centroid and Buildbotics, so far) can't cut wrapped jobs. Mach4's `G93` hasn't been tested on a machine yet: before your first wrapped job, with the tool raised and no blank in the chuck, run `G21 G90`, then `G93 G01 A360 F10`, then `G94` from MDI. The turn should take exactly 6 seconds.

**⌘R** simulates the job on the blank itself. On faces it turns to each angle with the tool at safe Z, as the machine will, at the machine's turn speed, and slows down for each turn so you can follow it. Wrapped, the tool stays over the axis and the blank turns under it as it cuts, with the toolpaths wrapped round it; a wall cut straight along the blank (a flute's side) shows very slightly radial. The run-time estimate times wrapped moves by the path of the tool tip, as the `G93` feeds make them run. 3D rotary finishing simulates the same way, all the way round. Designs stay on the flat sheet. The setup sheet gives each angle in the run order, and on a blank turned by hand, a step for each pause.
