#!/usr/bin/env python3
# make-projects.py: writes the Validation Handbook's test projects into
# docs/validation/projects/.
#
#   python3 docs/validation/tools/make-projects.py <nativecam-cli> <scratch dir>
#
# Every project starts from a file NativeCAM itself wrote: the CLI's `new`,
# `demo`, `demo3d` and `demosheets`, a saved project from the test fixtures, or
# one of the examples. Where a test needs its own coupon, the shapes are
# NativeCAM's own primitives (rectangle, circle, text), placed on a project the
# CLI wrote, with tools copied from the starter library in the demos. No vector
# or mesh geometry is written by hand. IDs are derived from the names, so
# running it again writes the same files.
#
# SPDX-License-Identifier: GPL-3.0-or-later

import copy, json, math, os, shutil, subprocess, sys, uuid

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OUT = os.path.join(ROOT, "docs", "validation", "projects")
FIX = os.path.join(ROOT, "Tests", "CAMCoreTests", "Fixtures")
EX = os.path.join(ROOT, "examples")
CLI, SCRATCH = sys.argv[1], sys.argv[2]
IN = 25.4
NS = uuid.UUID("6E415449-5645-4341-4D00-56414C494441")   # "NATIVECAM VALIDA"

os.makedirs(SCRATCH, exist_ok=True)
os.makedirs(OUT, exist_ok=True)


def cli(*args):
    subprocess.run([CLI, *args], check=True, stdout=subprocess.DEVNULL)


def base(kind):
    path = os.path.join(SCRATCH, f"{kind}.nativecam")
    cli(kind, path)
    return json.load(open(path))


def load(path): return json.load(open(path))


def uid(*parts): return str(uuid.uuid5(NS, "/".join(parts))).upper()


def save(p, name):
    # The rotary axis's centre height and turn speed are measured on the machine
    # by its owner: never ship a value for them (a fixture's placeholder included).
    for key in ("centerHeight", "turnSpeed"):
        p["machine"].get("rotary", {}).pop(key, None)
    json.dump(p, open(os.path.join(OUT, name + ".nativecam"), "w"), indent=2, sort_keys=True)
    print("  " + name + ".nativecam")


def copy_fixture(src, name, title=None):
    p = load(src)
    if title:
        p["name"] = title
    save(p, name)
    return p


_demo, _relief = base("demo"), base("demo3d")
END_MILL = _demo["operations"][1]["tool"]      # T1 1/4" upcut end mill
VBIT = _demo["operations"][0]["tool"]          # T5 60° V-bit 1/2"
BALL = _relief["operations"][1]["tool"]        # T7 1/4" ball nose
EIGHTH = load(os.path.join(FIX, "projects", "inlay-v6.nativecam"))["operations"][0]["kind"]["vcarve"]["_0"]["clearanceTool"]


def tool(t, **changes):
    t = copy.deepcopy(t)
    cutting = changes.pop("cutting", {})
    t.update(changes)
    t["cutting"].update(cutting)
    return t


# The starter bits' feeds suit hardwood. For the MDF coupons, feeds and speeds are
# set inside the chip-load chart's range for MDF, so the coupons post without
# chip-load warnings; for softwood, the chart's own suggestion.
MDF_END_MILL = tool(END_MILL, cutting=dict(spindleRPM=10000, feedRate=270 * IN))     # 0.0135 in/tooth
MDF_EIGHTH = tool(EIGHTH, cutting=dict(spindleRPM=18000, feedRate=171 * IN))         # 0.0048 in/tooth
SOFT_END_MILL = tool(END_MILL, cutting=dict(spindleRPM=13000, feedRate=273 * IN))    # 0.0105 in/tooth


class Job:
    """A project the CLI wrote, with shapes and toolpaths added."""

    def __init__(self, key, title, w, h, t, kind="mdf", material="MDF", mm=False, start="new"):
        self.key = key
        self.p = base(start) if start in ("new", "demo", "demo3d", "demosheets") else load(start)
        self.p["name"] = title
        if mm:
            self.p["displayUnits"] = "mm"
            self.p["machine"]["outputUnits"] = "mm"
        self.p["stock"].update(width=w, height=h, thickness=t, materialName=material, materialKind=kind)
        self.p["shapes"], self.p["operations"] = [], []

    def shape(self, kind, x, y, name, layer="Default"):
        s = {"id": uid(self.key, "shape", name), "kind": kind, "layer": layer, "name": name,
             "position": {"x": x, "y": y}, "rotation": 0, "scale": 1}
        self.p["shapes"].append(s)
        return s

    def rect(self, x, y, w, h, name, r=0):
        return self.shape({"rectangle": {"width": w, "height": h, "cornerRadius": r}}, x, y, name)

    def circle(self, x, y, d, name):
        return self.shape({"circle": {"radius": d / 2}}, x, y, name)

    def text(self, x, y, s, cap, name, font="Helvetica-Bold"):
        return self.shape({"text": {"_0": {"string": s, "fontName": font, "capHeight": cap, "letterSpacing": 0}}},
                          x, y, name)

    def op(self, name, kind, params, shapes, t, **extra):
        o = {"enabled": True, "id": uid(self.key, "op", name), "kind": {kind: {"_0": params}}, "name": name,
             "shapeIDs": [s["id"] for s in shapes], "tool": copy.deepcopy(t)}
        o.update(extra)
        self.p["operations"].append(o)
        return o

    def save(self, name=None):
        save(self.p, name or self.key)


def depth(cut, start=0, **more): return dict(cutDepth=cut, startDepth=start, **more)


PLUNGE = {"kind": "plunge", "rampLength": 25.4}
RAMP = {"kind": "ramp", "rampLength": 25.4}
LEADS = {"kind": "arc", "radius": 6.35, "sweep": 90, "length": 6.35, "angle": 45, "leadOut": True, "overlap": 0}


def tabs(n=4, thick=3.175, width=9.525, **more):
    return dict(count=n, enabled=n > 0, thickness=thick, width=width, **more)


print("Writing docs/validation/projects:")

# ---------------------------------------------------------------- VH-PRF-01
# Profile coupon: outside with tabs, ramp and leads; inside with leads; on the line.
for mm in (False, True):
    u = 1 if mm else IN
    if mm:
        W, H, T, sq, hole, groove, gdepth = 250, 200, 18, 75, 50, 60, 2.5
    else:
        W, H, T, sq, hole, groove, gdepth = 10 * IN, 8 * IN, 0.75 * IN, 3 * IN, 2 * IN, 2.5 * IN, 0.1 * IN
    j = Job("prf-coupon" + ("-mm" if mm else ""), "Profile coupon" + (" (mm)" if mm else ""), W, H, T, mm=mm)
    a = j.rect(W * 0.28, H * 0.5, sq, sq, "Outside square")
    b = j.circle(W * 0.72, H * 0.68, hole, "Inside circle")
    c = j.circle(W * 0.72, H * 0.27, groove, "On-line circle")
    j.op("On-line groove", "profile", {"allowance": 0, "depth": depth(gdepth), "direction": "climb", "entry": PLUNGE,
                                       "side": "on", "tabs": tabs(0)}, [c], MDF_END_MILL)
    j.op("Inside circle", "profile", {"allowance": 0, "depth": depth(T + 0.5, fromBottom=-0.5), "direction": "climb",
                                      "entry": RAMP, "leads": LEADS, "side": "inside", "tabs": tabs(0)}, [b], MDF_END_MILL)
    j.op("Outside square", "profile", {"allowance": 0, "depth": depth(T + 0.5, fromBottom=-0.5), "direction": "climb",
                                       "entry": RAMP, "leads": LEADS, "side": "outside", "tabs": tabs(4)}, [a], MDF_END_MILL)
    j.save()

# ---------------------------------------------------------------- VH-PRF-02, -03
copy_fixture(os.path.join(FIX, "projects", "finishing-pass-v28.nativecam"), "prf-finish-pass", "Finishing pass coupon")
copy_fixture(os.path.join(FIX, "projects", "tabs-start-v29.nativecam"), "prf-tabs-start", "Tabs and start point coupon")

# ---------------------------------------------------------------- VH-PKT-01
# Pocket with an island, 1/4" end mill, plus a narrow slot the 1/4" can't finish,
# rest-machined with a 1/8" end mill.
for mm in (False, True):
    if mm:
        W, H, T, pw, ph, isl, d, slot = 200, 150, 18, 120, 70, 25, 6, 10
    else:
        W, H, T, pw, ph, isl, d, slot = 8 * IN, 6 * IN, 0.75 * IN, 5 * IN, 2.75 * IN, 1 * IN, 0.25 * IN, 0.375 * IN
    j = Job("pkt-island" + ("-mm" if mm else ""), "Pocket coupon" + (" (mm)" if mm else ""), W, H, T, mm=mm)
    outer = j.rect(W * 0.5, H * 0.58, pw, ph, "Pocket", r=pw * 0.05)
    island = j.circle(W * 0.5, H * 0.58, isl, "Island")
    slotr = j.rect(W * 0.5, H * 0.15, pw, slot, "Square-cornered slot")
    params = {"allowance": 0, "depth": depth(d), "direction": "climb", "entry": RAMP, "rasterAngle": 0,
              "strategy": "offset"}
    j.op("Pocket with island", "pocket", dict(params), [outer, island], MDF_END_MILL)
    j.op("Slot 1/4 in", "pocket", dict(params), [slotr], MDF_END_MILL)
    j.op("Slot corners 1/8 in (rest)", "pocket", dict(params, restFromEarlier=True), [slotr], MDF_EIGHTH)
    j.p["formatVersion"] = max(j.p.get("formatVersion", 1), 1)
    j.save()

copy_fixture(os.path.join(FIX, "projects", "rest-pocket-v1.nativecam"), "pkt-two-tool", "Two-tool pocket (clearance tool)")
copy_fixture(os.path.join(FIX, "projects", "adaptive-v13.nativecam"), "pkt-adaptive", "Adaptive pocket")

# ---------------------------------------------------------------- VH-DRL-01
j = Job("drl-coupon", "Drilling coupon", 8 * IN, 4 * IN, 0.75 * IN)
plunge = [j.circle((1.5 + i) * IN, 2.9 * IN, 0.25 * IN, f"Plunge {i + 1}") for i in range(4)]
peck = [j.circle((1.5 + i) * IN, 1.1 * IN, 0.25 * IN, f"Peck {i + 1}") for i in range(4)]
j.op("Plunge holes", "drill", {"depth": 0.5 * IN, "peckDepth": 0, "fullRetract": True, "dwell": 0}, plunge, MDF_END_MILL)
j.op("Peck holes", "drill", {"depth": 0.75 * IN + 0.5, "fromBottom": -0.5, "peckDepth": 0.125 * IN,
                             "fullRetract": True, "dwell": 0.5}, peck, MDF_END_MILL)
j.save()

copy_fixture(os.path.join(FIX, "projects", "helical-bore-v31.nativecam"), "drl-helical", "Helical bore coupon")

# ---------------------------------------------------------------- VH-CRN-01
# Mortises with dogbone and T-bone corners, and a square-cornered tenon that should fit both.
j = Job("crn-corners", "Corner relief coupon", 8 * IN, 6 * IN, 0.75 * IN)
m1 = j.rect(2.25 * IN, 4.25 * IN, 2 * IN, 1 * IN, "Mortise dogbone")
m2 = j.rect(5.75 * IN, 4.25 * IN, 2 * IN, 1 * IN, "Mortise T-bone")
ten = j.rect(4 * IN, 1.6 * IN, 2 * IN, 1 * IN, "Tenon")
mp = {"allowance": 0, "depth": depth(0.375 * IN), "direction": "climb", "entry": RAMP, "rasterAngle": 0,
      "strategy": "offset"}
j.op("Mortise, dogbones", "pocket", dict(mp, cornerRelief={"style": "dogbone", "tBoneSide": "longer",
                                                             "maxCornerAngle": 120}), [m1], MDF_END_MILL)
j.op("Mortise, T-bones", "pocket", dict(mp, cornerRelief={"style": "tBone", "tBoneSide": "alongX",
                                                            "maxCornerAngle": 120}), [m2], MDF_END_MILL)
j.op("Cut out tenon", "profile", {"allowance": 0, "depth": depth(0.75 * IN + 0.5, fromBottom=-0.5),
                                  "direction": "climb", "entry": RAMP, "side": "outside", "tabs": tabs(4)},
     [ten], MDF_END_MILL)
groups = [{"id": uid("crn", "group", "Mortises"), "name": "Mortises"},
          {"id": uid("crn", "group", "Tenon"), "name": "Tenon"}]
j.save()
# The same job with toolpath groups, for VH-GRP-01.
j.key = "grp-corners"
j.p["name"] = "Toolpath groups coupon"
j.p["toolpathGroups"] = groups
for o in j.p["operations"]:
    o["groupID"] = groups[0]["id"] if o["name"].startswith("Mortise") else groups[1]["id"]
j.save()

# ---------------------------------------------------------------- VH-VC-01
j = Job("vc-coupon", "V-carve coupon", 8 * IN, 5 * IN, 0.75 * IN, kind="hardwood", material="Hardwood")
word = j.text(2.6 * IN, 3.4 * IN, "NC", 1.5 * IN, "Lettering")
box = j.rect(5.8 * IN, 3.4 * IN, 2.5 * IN, 1.5 * IN, "Flat-bottom rectangle")
box2 = j.rect(4 * IN, 1.1 * IN, 6 * IN, 0.75 * IN, "V-bit flat clearing")
j.op("V-carve lettering", "vcarve", {"sampleSpacing": 0.25}, [word], VBIT)
j.op("Flat-bottom V-carve", "vcarve", {"sampleSpacing": 0.25, "flatDepth": 0.125 * IN, "clearanceTool": EIGHTH},
     [box], VBIT)
j.op("V-bit flat clearing", "vcarve", {"sampleSpacing": 0.25, "flatDepth": 0.0625 * IN}, [box2], VBIT)
j.save()

# ---------------------------------------------------------------- VH-INL-01, -02
inl = load(os.path.join(FIX, "projects", "inlay-v6.nativecam"))
inl["name"] = "Inlay pocket board"
inl["operations"][0]["enabled"], inl["operations"][1]["enabled"] = True, False
save(inl, "inl-pocket")
inl["name"] = "Inlay plug board"
inl["operations"][0]["enabled"], inl["operations"][1]["enabled"] = False, True
save(inl, "inl-plug")
copy_fixture(os.path.join(FIX, "projects", "inlay-upgrades-v14.nativecam"), "inl-board-plug", "Whole-board inlay plug")

# ---------------------------------------------------------------- VH-SHP-01, -02
copy_fixture(os.path.join(FIX, "projects", "shaped-v8.nativecam"), "shp-chamfer-flute-prism",
             "Chamfer, flutes and prism coupon")
copy_fixture(os.path.join(FIX, "projects", "edge-profile-v18.nativecam"), "shp-edge-profile", "Edge profile coupon")

# ---------------------------------------------------------------- VH-3D
copy_fixture(os.path.join(SCRATCH, "demo3d.nativecam"), "3d-relief", "3D relief medallion")
r = load(os.path.join(SCRATCH, "demo3d.nativecam"))
r["name"] = "3D relief: adaptive roughing and rest finishing"
r["operations"][0]["kind"]["rough3D"]["_0"].update(clearing="adaptive", adaptive={"optimalLoad": 0.12})
small = tool(BALL, id=uid("3d-rest", "tool"), number=11, name='1/8" Ball Nose', diameter=3.175, shankDiameter=3.175,
             fluteLength=12.7, stickout=25.4, cutting=dict(feedRate=1524, plungeRate=508, stepdown=1.5875))
rest = {"enabled": True, "id": uid("3d-rest", "op"), "name": "Rest finish", "tool": small,
        "shapeIDs": list(r["operations"][1]["shapeIDs"]),
        "kind": {"finish3D": {"_0": {"allowance": 0, "boundary": "vectors", "rasterAngle": 135, "smoothLinks": True,
                                      "stepoverFraction": 0.1, "strategy": "rest",
                                      "rest": {"tolerance": 0.05, "margin": 0.5, "pencil": False}}}}}
r["operations"].insert(2, rest)
r["formatVersion"] = 26
save(r, "3d-adaptive-rest")
copy_fixture(os.path.join(FIX, "projects", "3d-tabs-v30.nativecam"), "3d-holding-tabs", "3D holding tabs medallion")
copy_fixture(os.path.join(FIX, "projects", "finishing-v21.nativecam"), "3d-finish-patterns",
             "Constant scallop, spiral and radial finishing")
copy_fixture(os.path.join(FIX, "projects", "finishing-v10.nativecam"), "3d-waterline",
             "Steep and shallow, waterline and pencil finishing")

# ---------------------------------------------------------------- VH-NST-01
# The frames, brackets and coasters from `demosheets`, on 12 x 12 in sheets.
n = base("demosheets")
n["name"] = "Nest Parts coupon"
keep = [s for s in n["shapes"] if s["name"].startswith(("Bracket", "Coaster"))]
ids = {s["id"] for s in keep}
n["shapes"] = keep
n["operations"] = [o for o in n["operations"] if o["name"] == "Cut out parts"]
for o in n["operations"]:
    o["shapeIDs"] = [i for i in o["shapeIDs"] if i in ids]
# A small frame (the demo's frames are 16 x 12 in): its window is cut by the same
# outside profile, from inside, so a coaster can be nested in it.
for name, size in (("Frame", 7), ("Frame window", 5)):
    fr = {"id": uid("nst", "shape", name), "kind": {"rectangle": {"width": size * IN, "height": size * IN,
                                                                  "cornerRadius": 0.25 * IN}},
          "layer": "Parts", "name": name, "position": {"x": 20 * IN, "y": 6 * IN}, "rotation": 0, "scale": 1}
    n["shapes"].append(fr)
    n["operations"][0]["shapeIDs"].append(fr["id"])
n["stock"].update(width=12 * IN, height=12 * IN)
save(n, "nst-parts")
# Nested by the CLI onto as many 12 x 12 in sheets as it needs, with a fixed seed so
# the layout repeats.
subprocess.run([CLI, "nest", os.path.join(OUT, "nst-parts.nativecam"), "--evaluations", "300", "--seed", "1",
                "--svg", os.path.join(SCRATCH, "nst-parts-nested.svg"),
                "-o", os.path.join(OUT, "nst-parts-nested.nativecam")], check=True)
print("  nst-parts-nested.nativecam (nativecam-cli nest)")

# ---------------------------------------------------------------- VH-TIL-01
# A 20 in board cut in 8 in tiles, fed through in Y, with registration holes.
t = load(os.path.join(FIX, "projects", "tiled-v9.nativecam"))
t["name"] = "Tiling coupon"
t["stock"].update(width=8 * IN, height=20 * IN)
t["tiling"]["tileHeight"] = 8 * IN
t["tiling"]["registration"]["edgeOffset"] = 0.75 * IN
pos = {"Panel": (4, 10), "Slot": (3, 10.5), "Star": (5.2, 10), "Hole 1": (3, 4), "Hole 2": (5.2, 16)}
for s in t["shapes"]:
    x, y = pos[s["name"]]
    s["position"] = {"x": x * IN, "y": y * IN}
    k = s["kind"]
    if "rectangle" in k and s["name"] == "Panel":
        k["rectangle"].update(width=5 * IN, height=18 * IN, cornerRadius=0.5 * IN)
    if "rectangle" in k and s["name"] == "Slot":
        k["rectangle"].update(width=1 * IN, height=5 * IN)
    if "star" in k:
        k["star"].update(outerRadius=0.75 * IN, innerRadius=0.35 * IN)
save(t, "til-feed-through")

# ---------------------------------------------------------------- VH-ROT
rot = {"letter": "A", "alignment": "x", "reversed": False}
j = Job("rot-indexed", "Indexed square bar", 12 * IN, 2 * IN, 1 * IN, kind="softwood", material="Softwood")
j.p["machine"]["rotary"] = dict(rot)
j.p["stock"]["rotary"] = {"shape": "squareBar", "diameter": 2 * IN, "length": 12 * IN}
j.p["stock"]["clearanceHeight"] = max(j.p["stock"]["clearanceHeight"], 1 * IN * (math.sqrt(2) - 1) + 5.08)
mort = j.rect(6 * IN, 1 * IN, 2.5 * IN, 0.5 * IN, "Mortise")
j.op("Mortise", "pocket", {"allowance": 0, "depth": depth(0.25 * IN), "direction": "climb", "entry": RAMP,
                           "rasterAngle": 0, "strategy": "offset"}, [mort], SOFT_END_MILL, indexAngles=[0, 90, 180, 270])
j.p["formatVersion"] = 3
j.save()

copy_fixture(os.path.join(FIX, "projects", "rotary-by-hand-v4.nativecam"), "rot-by-hand", "Indexed bar turned by hand")

d = 2 * IN
j = Job("rot-wrapped", "Wrapped letter F", 10 * IN, math.pi * d, d / 2, kind="softwood",
        material="Softwood dowel")
j.p["machine"]["rotary"] = dict(rot)
j.p["stock"]["rotary"] = {"shape": "cylinder", "diameter": d, "length": 10 * IN, "layout": "wrapped"}
f = j.text(3 * IN, math.pi * d / 2, "F", 1.25 * IN, "Letter F")
j.op("V-carve F", "vcarve", {"sampleSpacing": 0.25}, [f], VBIT)
j.p["formatVersion"] = 5
j.save()

copy_fixture(os.path.join(EX, "Demo Pawn.nativecam"), "rot-pawn", "Rotary pawn: rounding and 3D finishing")
copy_fixture(os.path.join(EX, "Demo Table Leg.nativecam"), "rot-table-leg", "Rotary table leg: 3D roughing and finishing")

# ---------------------------------------------------------------- VH-FED-01
copy_fixture(os.path.join(FIX, "projects", "load-feeds-v1.nativecam"), "fed-load", "Feeds that follow the load")

print("Done.")
