# Workflows for agents

[← Back to AGENTS.md](../../AGENTS.md)

Step-by-step recipes for the common jobs, each with the commands to run and what to check. Every recipe ends with the files handed to the human, who decides whether and how to run them. **Never run them on a machine yourself** (see [AGENTS.md](../../AGENTS.md#hard-safety-rules)).

- [Setup: a scratch folder and a small helper](#setup-a-scratch-folder-and-a-small-helper)
- [1. Import vectors and cut a profile, pocket and drill job](#1-import-vectors-and-cut-a-profile-pocket-and-drill-job)
- [2. V-carve a sign](#2-v-carve-a-sign)
- [3. An inlay pair](#3-an-inlay-pair)
- [4. Nest parts onto sheets](#4-nest-parts-onto-sheets)
- [5. A 3D relief: adaptive roughing, finishing and rest finishing](#5-a-3d-relief-adaptive-roughing-finishing-and-rest-finishing)
- [6. A rotary job, indexed and wrapped](#6-a-rotary-job-indexed-and-wrapped)
- [7. Apply a template](#7-apply-a-template)
- [8. Read the setup sheet and run-time estimate](#8-read-the-setup-sheet-and-run-time-estimate)
- [9. Calibration programs and fitting times](#9-calibration-programs-and-fitting-times)
- [10. A restart after a broken bit or an E-stop](#10-a-restart-after-a-broken-bit-or-an-e-stop)
- [Every recipe: the hand-over](#every-recipe-the-hand-over)

## Setup: a scratch folder and a small helper

Work in a scratch folder, not in the repository or the human's project folder. Build the CLI once:

```bash
swift build -c release --product nativecam-cli
CLI="$PWD/.build/release/nativecam-cli"
mkdir -p "$SCRATCH" && cd "$SCRATCH"          # any folder of your own
"$CLI" new new.nativecam && "$CLI" demo demo.nativecam && "$CLI" demo3d demo3d.nativecam
```

The recipes edit JSON with Python 3. Save this helper as `ncam.py` in the scratch folder. It takes the starter tools from the demo projects, so they're real bits with real feeds, and it writes shapes and toolpaths with every key the [format](project-format.md) requires.

```python
# ncam.py: helpers for writing NativeCAM projects. Lengths in mm.
import copy, json, uuid

def load(path): return json.load(open(path))
def save(project, path): json.dump(project, open(path, "w"), indent=2)
def uid(): return str(uuid.uuid4()).upper()

_demo, _relief = load("demo.nativecam"), load("demo3d.nativecam")
END_MILL = _demo["operations"][1]["tool"]      # T1 1/4" upcut end mill
VBIT = _demo["operations"][0]["tool"]          # T5 60° V-bit 1/2"
BALL = _relief["operations"][1]["tool"]        # 1/4" ball nose

def tool(base, **changes):
    """A copy of a tool with changes; pass a new number and id for a different bit."""
    t = copy.deepcopy(base); cutting = changes.pop("cutting", {})
    t.update(changes); t["cutting"].update(cutting); return t

def shape(kind, x, y, name, layer="Default"):
    return {"id": uid(), "kind": kind, "layer": layer, "name": name,
            "position": {"x": x, "y": y}, "rotation": 0, "scale": 1}

def op(name, kind, params, shapes, tool, **extra):
    o = {"enabled": True, "id": uid(), "kind": {kind: {"_0": params}}, "name": name,
         "shapeIDs": [s["id"] for s in shapes], "tool": copy.deepcopy(tool)}
    o.update(extra); return o

def depth(cut, start=0, **more): return dict(cutDepth=cut, startDepth=start, **more)
PLUNGE = {"kind": "plunge", "rampLength": 25.4}
```

## 1. Import vectors and cut a profile, pocket and drill job

**Import the drawing with `nativecam-cli import`**, which adds it as **File ▸ Import** does, through the same code (see [Command line](cli.md#import)). Have the toolpaths find their vectors by layer, and the import binds them:

1. Start from a project with the material set, and toolpaths whose `vectorSelection` names the drawing's layers: `{"layers": ["Cut Out"]}` and so on. `template apply` gives you those from a template; otherwise add them to the JSON with empty `shapeIDs`.
2. Import, saying the unit if the file doesn't (a DXF without `$INSUNITS` is refused until you do). Keep the file's coordinates if they're on the material; otherwise pass `--center` or `--at x,y`.
3. Read what it printed: the unit, each shape's size (does it match the drawing?), any `open` paths, and that every toolpath you expected is in `Toolpaths whose vectors changed`.
4. Post, then simulate.

Here with the test fixtures in `Tests/CAMCoreTests/Fixtures` (a two-layer DXF in inches and a DXF of drill points, into a project whose toolpaths find layers “Profile”, “Pocket” and “Holes”):

```text
$ "$CLI" import projects/cli-import-target.nativecam import/cli-two-layers-inch.dxf import/cli-points.dxf -o part.nativecam
cli-two-layers-inch.dxf: inches, as the file says
  Added “cli-two-layers-inch – Profile” on layer “Profile”: 6.0000 × 4.0000 in from (2.0000, 2.0000) to (8.0000, 6.0000), 1 closed path
  Added “cli-two-layers-inch – Pocket” on layer “Pocket”: 2.0000 × 2.0000 in from (4.0000, 3.0000) to (6.0000, 5.0000), 1 closed path
  Kept the file's coordinates
cli-points.dxf: inches, as the file says
  Added “cli-points points” on layer “Holes”: 4.0394 × 2.0394 in from (2.9803, 2.9803) to (7.0197, 5.0197), 4 closed paths
  Kept the file's coordinates
Toolpaths whose vectors changed:
  Pocket (Layer “Pocket”): 0 → 1 vector (1 added)
  Drill holes (Layer “Holes”): 0 → 1 vector (1 added)
  Cut out part (Layer “Profile”): 0 → 1 vector (1 added)
Kept as chosen by hand: Hand-picked V-carve (1 vector)
Wrote part.nativecam (format 1)
$ "$CLI" post part.nativecam -o part.tap
[info] Drill holes: Cuts through the material (0.0200 in into the spoilboard).
[info] Cut out part: Cuts through the material (0.0200 in into the spoilboard).
Generated 4 toolpaths in 0.01s, 783 lines -> part.tap
```

If you then move shapes to other layers in the JSON, `"$CLI" rebind bracket.nativecam -o rebound.nativecam` has the toolpaths look again; `post --rebind` does that in memory before posting. Without it, `post` cuts exactly the `shapeIDs` the file lists.

**Writing the vectors yourself** as a `paths` shape is still possible for a simple outline you're given as numbers rather than a file: flatten every curve to polylines (0.01–0.05 mm tolerance), convert to millimetres, and keep each closed loop as one polyline with `"isClosed": true`. Loops inside loops are holes. Check its size against the drawing's before you add toolpaths. For any drawing that exists as a file, import it instead.

**The same job written by hand**, here with a bracket outline written as vectors:

1. Start from `new.nativecam`. Set the material and units.
2. Add the shapes: the imported outline (`paths`), a recess (`rectangle`) and holes (`circle`), each on its own layer.
3. Add the toolpaths in cutting order: inside work first (pocket, drill), the cut-out last, with tabs.
4. Post, then simulate.

```python
# bracket.py
from ncam import *
p = load("new.nativecam")
p.update(name="Bracket", displayUnits="mm")
p["stock"].update(width=300, height=200, thickness=18, materialName="Baltic birch", materialKind="plywood")
outline = [{"x": -100, "y": -60}, {"x": 100, "y": -60}, {"x": 100, "y": 60}, {"x": 0, "y": 60}, {"x": -100, "y": 0}]
part = shape({"paths": {"_0": [{"isClosed": True, "points": outline}]}}, 150, 100, "Bracket outline", "Cut Out")
recess = shape({"rectangle": {"width": 60, "height": 30, "cornerRadius": 4}}, 180, 90, "Recess", "Pocket")
holes = [shape({"circle": {"radius": 3}}, x, y, f"Hole {i + 1}", "Holes")
         for i, (x, y) in enumerate([(80, 60), (220, 60), (220, 140)])]
p["shapes"] = [part, recess] + holes
p["operations"] = [
    op("Recess", "pocket", {"allowance": 0, "depth": depth(6), "direction": "climb", "entry": PLUNGE,
                            "rasterAngle": 0, "strategy": "offset"}, [recess], END_MILL),
    op("Holes", "drill", {"depth": 18.5, "fromBottom": -0.5, "dwell": 0, "fullRetract": True, "peckDepth": 6},
       holes, END_MILL),
    op("Cut out", "profile", {"allowance": 0, "depth": depth(18.5, fromBottom=-0.5), "direction": "climb",
                              "entry": {"kind": "ramp", "rampLength": 25}, "side": "outside",
                              "tabs": {"count": 4, "enabled": True, "thickness": 3, "width": 8}}, [part], END_MILL),
]
save(p, "bracket.nativecam")
```

```text
$ python3 bracket.py && "$CLI" post bracket.nativecam -o bracket.tap
[info] Holes: Cuts through the material (0.500 mm into the spoilboard).
[info] Cut out: Cuts through the material (0.500 mm into the spoilboard).
Generated 3 toolpaths in 0.01s, 254 lines -> bracket.tap
Estimated run time: 0:01:02 (cutting 0:00:50, rapids 0:00:12, tool changes/pauses 0:00:00; distance/feed alone: 0:00:47)
  Recess: 0:00:17
  Holes: 0:00:12
  Cut out: 0:00:31
$ "$CLI" sim bracket.nativecam --png bracket.png
Simulated 222 steps on a 1500x1000 grid (0.20 mm cells) in 0.00s
Removed 82.8 cm³ of material; job time 0:01:02
Wrote bracket.png
```

To keep the tabs off a detail, place them yourself instead of `count`: add `"placed"` to `tabs`, a list of marks on the outline in the shape's own coordinates, and `"shape": "triangular"` for ramped tabs with an end mill. To start the cut on a particular edge, add `"startPoints"` to the profile. For the bracket, two tabs on its bottom edge, one on its right side, and the cut starting on the bottom edge (it's then format 29):

```python
cut = p["operations"][-1]["kind"]["profile"]["_0"]
cut["tabs"]["placed"] = [{"shapeID": part["id"], "point": {"x": x, "y": y}} for x, y in [(-50, -60), (50, -60), (100, 0)]]
cut["startPoints"] = [{"shapeID": part["id"], "point": {"x": 0, "y": -60}}]
```

`post` warns about a mark that's no longer on its shape (more than 1 mm, or the bit's radius, off its outline) and leaves it off; with no tabs left, it warns the cut frees the part. Read those warnings before handing the file over.

**Check:** exit 0; three toolpaths generated; no warnings; `Cuts through the material` on the drill and the cut-out; no `[error]` from `sim`; and the PNG shows the recess, three holes and the outline. A drill's holes are bored with the end mill here, plunging at each circle's centre; for holes bigger than the bit, pocket or profile them instead.

## 2. V-carve a sign

1. Add a `text` shape. Any macOS font works, by PostScript or family name. `capHeight` is a capital H's height in mm.
2. Add a `vcarve` toolpath with a V-bit. Add `flatDepth` with an end mill as `clearanceTool` for wide letters.
3. Post, and **read every warning**: lettering wider than the board gives `Toolpath extends beyond the material edges.`

```python
# sign.py
from ncam import *
s = load("new.nativecam")
s["name"] = "Sign"
s["stock"].update(width=457.2, height=203.2, thickness=19.05, materialName="Cherry", materialKind="hardwood")
word = shape({"text": {"_0": {"string": "WELCOME", "fontName": "Georgia-Bold", "capHeight": 50.8,
                              "letterSpacing": 0}}}, 228.6, 101.6, "Title")
s["shapes"] = [word]
s["operations"] = [op("V-carve title", "vcarve", {"sampleSpacing": 0.25}, [word], VBIT)]
save(s, "sign.nativecam")
```

```text
$ python3 sign.py && "$CLI" post sign.nativecam -o sign.tap
Generated 1 toolpaths in 0.02s, 2501 lines -> sign.tap
Estimated run time: 0:02:48 (cutting 0:02:40, rapids 0:00:07, tool changes/pauses 0:00:00; distance/feed alone: 0:02:33)
  V-carve title: 0:02:46
```

**Check:** no warnings. At a `capHeight` of 76.2 (3 in) the same word is wider than the 18 in board, and `post` warns that the toolpath extends beyond the material. Fix the size; don't hand that file over. For a cut-out round the sign, add a profile as in recipe 1.

## 3. An inlay pair

An inlay is two V-carves on the **same shapes with the same V-bit**: the `pocket` side in the main board and the `plug` side, mirrored by the toolpath itself, on a second board. They're cut on separate boards, so only one is enabled in each posted file. The app's **Add Toolpath ▸ Inlay…** makes both; headlessly, write them as below. Leave the design as drawn; the plug toolpath mirrors it. See [V-carve inlays](../using-nativecam.md#v-carve-inlays) for what P, G and C mean.

```python
# inlay.py
from ncam import *
EIGHTH = tool(END_MILL, id="4E415449-5645-4341-4D00-000000000002", number=2, name='1/8" Upcut End Mill',
              diameter=3.175, shankDiameter=3.175, fluteLength=12.7, stickout=25.4,
              cutting=dict(feedRate=3048, plungeRate=635, spindleRPM=18000, stepdown=1.5875))
i = load("new.nativecam")
i["name"] = "Star inlay"
i["stock"].update(width=203.2, height=152.4, thickness=19.05, materialName="Maple", materialKind="hardwood")
star = shape({"star": {"points": 5, "outerRadius": 40, "innerRadius": 18}}, 101.6, 76.2, "Star")
fit = {"boundary": "margin", "boundaryMargin": 6.35, "glueGap": 0.508, "pocketDepth": 5.08, "surfaceClearance": 1.5875}
i["shapes"] = [star]
i["operations"] = [
    op("Inlay pocket", "vcarve", {"flatDepth": 5.08, "sampleSpacing": 0.25, "clearanceTool": EIGHTH,
                                  "inlay": dict(fit, role="pocket")}, [star], VBIT),
    op("Inlay plug", "vcarve", {"sampleSpacing": 0.25, "inlay": dict(fit, role="plug")}, [star], VBIT, enabled=False),
]
i["formatVersion"] = 6                      # an inlay plug is format 6
save(i, "inlay.nativecam")                  # the pocket board
i["operations"][0]["enabled"], i["operations"][1]["enabled"] = False, True
save(i, "inlay-plug.nativecam")             # the plug board
```

```text
$ python3 inlay.py && "$CLI" post inlay.nativecam -o inlay-pocket.tap
Generated 2 toolpaths in 0.12s, 1960 lines -> inlay-pocket.tap
Estimated run time: 0:03:09 (cutting 0:02:02, rapids 0:00:08, tool changes/pauses 0:01:00; distance/feed alone: 0:02:37)
  Inlay pocket – flat clearing: 0:01:39
  Inlay pocket: 0:00:29
$ "$CLI" post inlay-plug.nativecam -o inlay-plug.tap
Generated 1 toolpaths in 0.02s, 305 lines -> inlay-plug.tap
…
```

**Check:** the pocket's `flatDepth` equals the plug's `pocketDepth` (P), both use the same V-bit, exactly one side is enabled in each file, and there are no inlay warnings. **Checks** warns when the plug won't seat: a different V-bit, a depth mismatch, no glue gap, a flat-tipped V-bit. The clearance end mill's flat clearing shows as its own toolpath in the estimate. Tell the human which file is which board, that the plug is glued in face down, and the depths: the setup sheet (`--sheet`) lists each inlay toolpath's side and depths.

## 4. Nest parts onto sheets

1. Have each part as a closed shape that a toolpath cuts out (an outside or on-the-line profile), with its holes and inside work in the same project. `demonest` and `demosheets` show the layout.
2. Run `nest` with `--evaluations` and `--seed`, so the layout repeats, and `--svg` to see it.
3. Read the result: `Nested x of y`, the sheets used, parts left over.
4. Post the nested project. A job on several sheets posts one file per sheet.

```text
$ "$CLI" demosheets parts.nativecam
$ "$CLI" nest parts.nativecam --evaluations 200 --seed 1 --svg layout.svg -o nested.nativecam
Nested 19 of 19 parts in 0.2 s (200 layouts tried), spacing 0.3750 in, edge margin 0.3750 in
On 2 sheets: sheet 1 11 parts, sheet 2 8 parts
In other parts' holes: Bracket 1 in Frame 1, Bracket 2 in Frame 1, Bracket 3 in Frame 2, Bracket 4 in Frame 2, Coaster 2 in Frame 2, Coaster 5 in Frame 2, Coaster 6 in Frame 1
Parts fill 59% of the 42.5102 in of the last sheet they use (61% of all the sheets' area)
Wrote layout.svg
Wrote nested.nativecam
$ "$CLI" post nested.nativecam -o nested.tap
…
[info] Nested onto 2 sheets, cut one after another. Export saves 2 files, one per sheet, and a setup sheet with a page for each sheet.
Generated 4 toolpaths in 0.02s, 2209 lines -> nested - sheet 1 of 2.tap, nested - sheet 2 of 2.tap
```

**Check:** every part placed (`19 of 19`); no `Didn't fit` lines; no `extends beyond the material edges` warnings or travel errors from `post`; the SVG looks right. Options: `--sheets n` caps the sheets, `--sheet-size 48x96` (display units) sizes the sheets after the first, `--no-holes` keeps parts out of other parts' holes, `--turns none` or `--grain` for grain direction, and `--spacing` and `--margin` for gaps. A rotary job can't be nested. Write to a new file (`-o`), never `--in-place` on the human's project.

## 5. A 3D relief: adaptive roughing, finishing and rest finishing

Start from `demo3d` (a relief mesh roughed, finished with a 1/4" ball nose and cut out), or add a model as in [3D models](project-format.md#3d-models). Then:

1. Make the roughing adaptive: `"clearing": "adaptive"` on `rough3D` (format 26).
2. Keep the raster finish.
3. Add a `finish3D` with `"strategy": "rest"` and a smaller ball, after the finish (format 17). Without `references`, it rests from every earlier enabled 3D finish on the same model with a larger bit.
4. Give the new bit its **own tool number**.

```python
# relief.py
from ncam import *
r = load("demo3d.nativecam")
r["operations"][0]["kind"]["rough3D"]["_0"].update(clearing="adaptive", adaptive={"optimalLoad": 0.12})
small = tool(BALL, id=uid(), number=8, name='1/8" Ball Nose', diameter=3.175, shankDiameter=3.175,
             fluteLength=12.7, stickout=25.4, cutting=dict(feedRate=1524, plungeRate=508, stepdown=1.5875))
finish = r["operations"][1]
rest = op("Rest finish", "finish3D", {"allowance": 0, "boundary": "vectors", "rasterAngle": 135, "smoothLinks": True,
                                      "stepoverFraction": 0.1, "strategy": "rest",
                                      "rest": {"tolerance": 0.05, "margin": 0.5, "pencil": False}}, [], small)
rest["shapeIDs"] = finish["shapeIDs"]       # the same model and boundary as the finish
r["operations"].insert(2, rest)
r["formatVersion"] = 26                     # adaptive 3D roughing
save(r, "relief.nativecam")
```

```text
$ python3 relief.py && "$CLI" post relief.nativecam -o relief.tap
[warning] Rough relief: Adaptive clearing couldn't hold its load everywhere (a slot or corner too tight for its loops), so it clears what it left there in passes of the tool's stepdown (0.1875 in).
[info] Cut out medallion: Cuts through the material (0.0200 in into the spoilboard).
Generated 4 toolpaths in 1.59s, 29624 lines -> relief.tap
Estimated run time: 0:15:13 (cutting 0:11:18, rapids 0:00:55, tool changes/pauses 0:03:00; distance/feed alone: 0:13:11)
  Rough relief: 0:03:27
  Finish relief: 0:04:51
  Rest finish: 0:03:36
  Cut out medallion: 0:00:18
$ "$CLI" sim relief.nativecam --png relief.png
```

**Check:** the adaptive warning above is expected on a relief and is worth passing on. Compare with the demo's offset roughing (1:17 against 3:27): adaptive roughing is slower here, which [Known limits](../known-limits.md) says to expect. A tool-number clash is an error and refuses the file:

```text
[error] Rest finish: Uses T7 for 1/8" Ball Nose, but “Finish relief” just before it uses T7 for 1/4" Ball Nose. No tool change is written between them, so this would cut with the 1/4" Ball Nose. Give each bit its own tool number.
```

For pockets, the rest equivalents are `restFromEarlier: true` on a later pocket with a smaller bit, or a `clearanceTool` on one pocket. For adaptive pockets, set `"strategy": "adaptive"` (format 13).

## 6. A rotary job, indexed and wrapped

A rotary job needs both a **rotary axis on the machine** (`machine.rotary`) and a **rotary blank** (`stock.rotary`), with the stock's `width`, `height` and `thickness` set to the blank's design sheet. Read [Machines and posts](machines-and-posts.md#the-rotary-axis) first. **Never guess the axis's direction (`reversed`), centre height or turn speed**: they're measured on the machine by the human, and getting the direction wrong mirrors wrapped work.

**Indexed**: the same shapes cut on each face at a list of angles.

```python
# indexed.py
import math
from ncam import *
x = load("new.nativecam")
x["name"] = "Indexed bar"
x["machine"]["rotary"] = {"letter": "A", "alignment": "x", "reversed": False}
blank = {"shape": "squareBar", "diameter": 50.8, "length": 304.8}
# On faces: width = length, height = diameter, thickness = radius.
x["stock"].update(rotary=blank, width=304.8, height=50.8, thickness=25.4, materialName="Poplar", materialKind="softwood")
# The blank turns at safe Z, so clear a square bar's corners: (√2 − 1) × radius plus the link safe distance.
x["stock"]["clearanceHeight"] = max(x["stock"]["clearanceHeight"], 25.4 * (math.sqrt(2) - 1) + 5.08)
mortise = shape({"rectangle": {"width": 60, "height": 12.7, "cornerRadius": 0}}, 152.4, 25.4, "Mortise")
x["shapes"] = [mortise]
x["operations"] = [op("Mortise", "pocket", {"allowance": 0, "depth": depth(6.35), "direction": "climb", "entry": PLUNGE,
                                            "rasterAngle": 0, "strategy": "offset"}, [mortise], END_MILL,
                      indexAngles=[0, 90, 180, 270])]
x["formatVersion"] = 3
save(x, "indexed.nativecam")
```

```text
$ python3 indexed.py && "$CLI" post indexed.nativecam -o indexed.tap
[warning] Mortise @ 0°: Chip load 0.0085 in is below the 0.0100 in–0.0120 in range for this bit in softwood (end-mill chart, 1/4" end mill); thin chips rub, burn and dull the bit. Try 273 in/min at 13000 RPM.
…
[info] Measure the rotary's centre height above the spoilboard so NativeCAM can check that the job fits under the Z travel.
Generated 4 toolpaths in 0.00s, 175 lines -> indexed.tap
…
  Mortise @ 0°: 0:00:07
  Mortise @ 90°: 0:00:07
  Mortise @ 180°: 0:00:07
  Mortise @ 270°: 0:00:07
```

The chip-load warning says how to fix it (raise the feed in the tool's `cutting.feedRate`). The centre-height note means the Z-travel check couldn't run; it's the human's to measure.

**Wrapped**: the design sheet is the blank unrolled. X runs along the axis, and Y runs once round it, 0 to π × the wrap diameter. Supported posts feed it in inverse time (`G93`).

```python
# wrapped.py
import math
from ncam import *
w = load("new.nativecam")
w["name"] = "Wrapped name"
w["machine"]["rotary"] = {"letter": "A", "alignment": "x", "reversed": False}
d = 50.8
# Wrapped: width = length, height = π × wrap diameter, thickness = wrap radius.
w["stock"].update(rotary={"shape": "cylinder", "diameter": d, "length": 254, "layout": "wrapped"},
                  width=254, height=math.pi * d, thickness=d / 2, materialName="Poplar", materialKind="softwood")
name = shape({"text": {"_0": {"string": "OAK", "fontName": "Helvetica-Bold", "capHeight": 25.4, "letterSpacing": 0}}},
             127, math.pi * d / 2, "Name")    # the middle of the sheet is the top of the blank at A0
w["shapes"] = [name]
w["operations"] = [op("V-carve name", "vcarve", {"sampleSpacing": 0.25}, [name], VBIT)]
w["formatVersion"] = 5
save(w, "wrapped.nativecam")
```

```text
$ python3 wrapped.py && "$CLI" post wrapped.nativecam -o wrapped.tap
[warning] V-carve name: The rotary axis turns at most 5,400°/min (its Turn speed isn't set, so NativeCAM assumes 90° a second: set it in Material & Machine ▸ Rotary Axis), so near the axis the cut slows to keep up: down to 76.8 in/min at 0.8191 in from the axis, from the 80.0 in/min set. If the wood burns there, lower the spindle speed.
[warning] V-carve name: Cuts 0.2410 in deep into a 1.0000 in wrap radius. A wrapped design is true to size only at the wrap diameter: at the bottom of this cut it comes out 24% narrower around the blank.
[info] Before the first wrapped cut, jog the rotary axis positive: the top of the blank should roll toward −Y. If it rolls toward +Y, tick Reversed, or wrapped designs come out mirrored.
[info] Measure the rotary's centre height above the spoilboard so NativeCAM can check that the job fits under the Z travel.
Generated 1 toolpaths in 0.01s, 623 lines -> wrapped.tap
…
$ "$CLI" sim wrapped.nativecam
Simulated 591 steps on a 1271x798 grid (0.20 mm cells) in 0.88s
Rotary blank, job time 0:00:25:
  Wrapped toolpaths: removed 2.0 cm³ all the way round (heights and PNG show the sheet unrolled)
```

**Check and hand over:** pass on the direction note word for word. The human has to jog the axis and confirm it before any wrapped cut. Which controllers can turn the blank, and how, is in [Machines and posts](machines-and-posts.md#the-rotary-axis). For 3D rotary work (rounding, `rotaryRough`, `rotaryFinish`), start from `examples/Demo Pawn.nativecam` or `examples/Demo Table Leg.nativecam`. Their simulations take tens of seconds.

## 7. Apply a template

A template is a saved set of toolpaths that find their shapes by **layer** or **kind** in the next design.

1. **Save one** from a finished project: `template save job.nativecam -o "Job.nativecamtemplate"`. Read its list: a toolpath marked `Selected vectors` finds nothing when the CLI applies it. Before saving, give it a layer rule (`"vectorSelection": {"layers": ["Cut Out"]}`) and put its shapes on that layer.
2. **Apply it** to the new design: `template apply "Job.nativecamtemplate" board.nativecam -o board-with-toolpaths.nativecam`.
3. **Read what each toolpath found.** `0 vectors, added empty` means it cuts nothing. When layers are missing, it refuses and names them; choose `--create-layers` (make them empty; you then put shapes on them and must set `shapeIDs` yourself, since `post` doesn't rebind) or `--skip-missing`.
4. Post the result.

```text
$ "$CLI" template save demo.nativecam -o Sign.nativecamtemplate
Saved 4 toolpaths to Sign.nativecamtemplate (format 1)
  V-carve title: Text
  Pocket plaque: Selected vectors
  Drill mounting holes: Circles
  Cut out sign: Selected vectors
$ "$CLI" template apply Tests/CAMCoreTests/Fixtures/templates/sign-layers-v1.nativecamtemplate new.nativecam -o board.nativecam
The design has no layers “V-Carve”, “Pocket”, “Holes”, “Cut Out”, which the template's toolpaths find their vectors on. Pass --create-layers to make them (empty, so vectors can be put on them later) or --skip-missing to leave out those toolpaths.
$ echo $?
1
```

`--setup` also takes the template's job setup (thickness, origin, heights). `--tools lib.json` matches its bits against a library from `nativecam-cli tools … -o lib.json` instead of the starter library. The output is always a new file unless you pass `--in-place`; don't, on the human's project.

## 8. Read the setup sheet and run-time estimate

`post --sheet out.html` writes the printable setup sheet. It holds the machine, material and zero; the tools in loading order; the run order with tool changes and times; each inlay toolpath's side and depths; clamps; and the open checks. It's HTML: read it as text, without the tags and the stylesheet, or render it.

```bash
"$CLI" post demo.nativecam -o demo.tap --sheet demo.html
python3 -c "
import html, re
t = re.sub(r'(?s)<(style|script)[^>]*>.*?</\\1>', '', open('demo.html').read())
print(html.unescape(re.sub(r'<[^>]+>', ' ', t)))" | tr -s ' \n' | head -40
```

```text
 Machine PRO6060 (5 × 5 ft), Avid Mach4, VFD spindle, Manual (M6)
 Material Baltic birch plywood: 24.000 in × 18.000 in × 0.750 in
 XY zero Lower left of the material
 Z zero Material top
 …
 Run order
 # Toolpath Tool RPM Feed Depth Time
 Load T5 60° V-Bit 1/2" and zero Z (material top) before starting.
 1 V-carve title T5 18000 80 in/min 0.433 in 1:26
 Change to T1 1/4" Upcut End Mill and re-zero Z with the touch plate, then press Cycle Start.
 2 Pocket plaque T1 13000 220 in/min 0.250 in 2:18
 …
```

The **run-time estimate** is `post`'s `Estimated run time:` line and the per-toolpath lines after it:

```text
Estimated run time: 0:06:54 (cutting 0:05:30, rapids 0:00:24, tool changes/pauses 0:01:00; distance/feed alone: 0:06:26)
```

- **Total** times the posted moves with the controller's look-ahead planner and the machine's accelerations.
- **cutting**, **rapids** and **tool changes/pauses** are its parts. Each tool change counts `toolChangeSeconds` (60 s on a manual M6 machine, 15 s with an ATC).
- **distance/feed alone** is the naive figure, for comparison.

The accelerations are class defaults until calibrated (see recipe 9). None of the estimates has been timed against a real machine, so call it an estimate when you report it. `sim` on a project prints the same job time.

## 9. Calibration programs and fitting times

Calibration is the **human's** job at the machine. The agent's part is to write the programs and, once the human has timed them, to fit the times they bring back.

1. Write the programs for the project's machine: `calibrate timing shop.nativecam`, and `calibrate rotary` and `calibrate ladder --tool n --material kind` as needed (see [Command line](cli.md#calibrate-timing-rotary-ladder)).
2. Hand the human the `.tap` (or `.nc`), the recording sheet `.html` and the times file `…-times.csv`, with the program's own instructions: the timing suite is an air cut with a stop before each section; zero X and Y at the window's front-left corner and Z on the work; keep the overrides at 100%. **The human runs and times it.**
3. When the human returns the times file with `measured_s` filled in, fit it and show them the result before applying anything:

```bash
"$CLI" calibrate fit calibration-timing-times.csv shop.nativecam            # report only
"$CLI" calibrate fit calibration-timing-times.csv shop.nativecam --apply -o shop-calibrated.nativecam
```

4. Report the before-and-after values, the sections still more than 10% off, and the F-change and `G93` verdicts.

**Never fill in `measured_s` yourself**, not even "to test", in a file that might be applied: `--apply` marks every fitted value `measured` in the machine's `provenance`. A times file with nothing measured is refused (`Not fitted: No times have been entered yet.`).

## 10. A restart after a broken bit or an E-stop

The human says a job stopped partway. A restart file is the rest of the job from a point you name (see [Restarting a job partway through](../using-nativecam.md#restarting-a-job-partway-through)).

1. **Ask the human where it stopped:** the line the controller showed, or the toolpath and pass, and which file on a tiled, multi-sheet or split job. Ask for the file that was running too. Never guess a line or pass.
2. Post the restart from the same project, comparing it with the file that was running:

   ```bash
   $CLI post job.nativecam -o job.tap --restart-line 812 --restart-from "job.tap"
   ```

   It snaps back to the start of that line's pass and stops over the restart point. Use `--restart-exact` only when the human asks to restart at the move itself.
3. Read every line. `Restart refused: …` (exit 1) can't be forced: tell the human why. An `[error]` that the running file differs means the project changed since that file was written, so the restart would cut something else: report it and stop. A warning that the spin-up dwell is 0 s goes to the human with the file.
4. Check the header the file starts with: the toolpath and pass, the line's text (the human compares it with the controller's screen), the tool to load and, on a rotary job, the A reading expected.
5. Hand over the restart file with the header's advice: re-home and check the XY zero after a power cut or E-stop, re-zero Z at the tool change, and jog Z clear before Cycle Start. Offer an air cut of the restart (`--air-cut`) for its first run. **The human runs it.** Restarts haven't been run on a real machine yet.

## 11. Surface the spoilboard

The human asks for a spoilboard surfacing program. It's a standalone file, not a toolpath in a project (see [Command line](cli.md#surface)).

1. **Ask** what to surface: the whole bed, or a board's size. Ask for the board's thickness if they know it, and whether they want to read tram (one way, 90% stepover, a small area, 0.01 in deep). Don't guess where the machine homes.
2. Write it from their project, so it gets their machine and tools:

   ```bash
   $CLI surface shop.nativecam -o surface.tap                                   # whole bed
   $CLI surface shop.nativecam --area 24x36 --board 0.75 -o board.tap           # a board
   ```

3. Read every line. `Not written: …` (exit 1) is a refusal: change the settings (a shallower pass, a smaller area, `--clamp-overshoot` if they accept a bit that doesn't clear the ends) or tell the human why. Never get around one with a different bit's made-up dimensions.
4. Hand over the program and its `-air` copy with the header's instructions: Z zero on the top of the spoilboard with the touch plate on the board, XY zero at the area's front-left corner, every clamp off and every screw head at least 1/8 in below the cut, the air cut first. **The human runs it.** Say that it hasn't been run on a real machine yet.

## Every recipe: the hand-over

Give the human:

- the G-code files and the project they came from (and the setup sheet, when there is one)
- every `[warning]` and `[info]` line from `post`, word for word, and what you think each means
- what you checked (exit status, toolpath count, `sim`'s removed volume and `[error]` lines, the PNG, the setup sheet) and what you couldn't (anything on the machine, anything unverified for that controller)
- that only Avid Mach4 output has been run on a real machine, if the job is for another controller, and that the [acceptance test](../controllers.md#trying-a-new-controller-safely) and an air cut come first
