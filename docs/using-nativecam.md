# Using NativeCAM

[← Back to the README](../README.md)

- [Workflow](#workflow)
- [Supported files](#supported-files)
- [Keyboard and mouse](#keyboard-and-mouse)
- [Toolpaths and features](#toolpaths-and-features)
- [Leads and corners](#leads-and-corners)

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
| | **PDF**, **Illustrator `.ai`** | PDF-compatible `.ai` files. Handles nested groups, page rotation and the crop box. |
| 3D models | **STL** (binary/ASCII), **OBJ**, **3MF**, **USDZ/USD**, **PLY** | 3MF includes Bambu and Prusa multi-part files. Choose the up axis, flip, size, carve depth and how far below the surface the top sits. |
| G-code | **`.tap`**, **`.nc`**, **`.gcode`**, **`.ngc`**, **`.cnc`**, ShopBot **`.sbp`** | Opened for simulation only (**File ▸ Simulate G-code File…**, or drop on the canvas) |
| Machines | Mach4 **`Machine.ini`**, Grbl **`$$`** output, **LinuxCNC** INI, **FluidNC** `config.yaml`, **Fusion 360** `.mch` | Speeds, accelerations, travel and spindle range for a machine. See [Importing controller settings](machines.md#importing-controller-settings). |
| Posts | Your own **Vectric `.pp`** | Writes G-code for a controller NativeCAM has no post for. See [Using your own Vectric post](controllers.md#using-your-own-vectric-post). |
| Tool libraries | **Fusion 360** `.tools` / `.json`, **Vectric** `.vtdb`, NativeCAM `.json` | **Tool Library ▸ ⋯ ▸ Import Tools…** lists the bits by the library's folders. Search, filter by type and tick the ones you want. Vendors such as Amana Tool publish their bits in these formats. Values a library leaves out (Vectric files have no cutting or shank lengths) are read from the bit's name where possible, otherwise filled conservatively and marked ⚠ (details in the tool's notes). Tapered ball nose, form, dovetail, roundover and thread bits are listed as not imported. Vectric's older `.tool` files aren't supported. |
| Projects | **`.nativecam`** | JSON document. Projects for any controller other than Avid's Mach4 profile, or with an imported post, are saved as format 2, and projects with rotary stock as format 3. Older builds refuse to open a format they don't know rather than silently writing the wrong G-code. |

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
| Stock | Material size and thickness, XY zero at any corner or the centre, Z zero on the material top or the spoilboard, safe and plunge heights, park position. Inches or millimetres. |
| Profile | Inside, outside or on the line; climb or conventional; multi-pass; ramp entry; arc or line leads in and out; dogbone or T-bone corners; tabs; allowance; holes cut before outside profiles. See [Leads and corners](#leads-and-corners). |
| Pocket | Offset or raster clearing, islands, safe feed links between regions, dogbone or T-bone corners. Inner clearing rings get rounded corners (within a set tolerance, 0.25 mm by default); the wall pass stays exact. |
| Drill | Peck, chip-break and dwell. Canned cycles are expanded into plain moves. |
| V-carve | Maximal inscribed circles, flat-depth cap, optional flat-area clearing tool, multi-pass |
| 3D roughing | Layered clearing with an end mill, leaving an allowance for finishing. Layer outlines follow the surface between grid samples instead of stepping cell by cell, so the machine doesn't crawl through stair-step corners. Machine inside the model outline, inside **selected vectors** such as the cut-out outline (chosen automatically when a cut-out surrounds the model, so scrap isn't machined), or across the whole material. |
| 3D finishing | Raster passes with an exact triangle drop-cutter for ball and flat bits, so steep walls aren't gouged. Shows scallop height. Same boundary choices as roughing. |
| Arc fitting | Line segments are re-fitted to arcs, helical ones included (for controllers that take arcs) |
| Links between cuts | **Minimum** (default): rise just above the remaining material plus a safe distance, feed straight across short stretches already cleared to depth, and rapid down to just above floors this job already cut. **Full** always returns to safe Z. Shapes marked as clamps raise an error if a toolpath cuts into them, and links cross them above their height. Profiles skip depths an earlier toolpath already cleared. |
| Cut order | Holes, profile loops and V-carve strokes are ordered by nearest neighbour and then improved by local search (2-opt, Or-opt); closed loops are entered wherever they're nearest the tool. Across toolpaths, **Optimize Run Order** finds the order with the fewest tool changes that keeps the work inside each part before its cut-out, roughing before finishing, and your order wherever toolpaths overlap. |
| Job checks | Cuts into the spoilboard or a clamp, depth beyond flute length, toolpaths outside the work area, rapids through material, out-of-range feeds or RPM, chip loads too thin for the material (with a one-click recommended feed), a run order that cuts a part free too early, and two different bits sharing one tool number (which would skip a tool change and cut with the wrong bit). The exported file is checked too; see [Export checks](controllers.md#export-checks-air-cuts-and-setup-sheets). |
| Run-time estimate | See [Run-time estimates](machines.md#run-time-estimates). |
| Tools | Flat, ball, bull nose, V-bit, engraving (tip diameter), surfacing and drill. Flute length, shank, stickout, flute count and direction, feeds and speeds, chip-load calculator checked against chart chip loads for the material type, compression bits whose first pass clears the upcut length, live profile drawing, import from Fusion 360 and Vectric libraries. Saved to `~/Library/Application Support/NativeCAM/tools.json`. |
| Simulator | A Metal-rendered heightmap carved by the true tool shape (flat, ball, bull nose, V), with through-cuts, a tool marker, play, pause, scrub and speed control, timed like the real job, and detection of rapids through material. It also simulates G-code and ShopBot files from other programs. |

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
