# Using NativeCAM

[← Back to the README](../README.md)

- [Workflow](#workflow)
- [Supported files](#supported-files)
- [Keyboard and mouse](#keyboard-and-mouse)
- [Toolpaths and features](#toolpaths-and-features)

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
| Profile | Inside, outside or on the line; climb or conventional; multi-pass; ramp entry; tabs; allowance; holes cut before outside profiles |
| Pocket | Offset or raster clearing, islands, safe feed links between regions. Inner clearing rings get rounded corners (within a set tolerance, 0.25 mm by default); the wall pass stays exact. |
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
