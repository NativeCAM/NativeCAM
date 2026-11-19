"""Minimal Mach4 G-code reader for NativeCAM .tap output (inches, G90, G91.1 incremental I/J).

Produces a flat list of Move records with exact geometry (arc length from I/J, helical Z),
start/end tangents (for corner analysis) and the toolpath each move belongs to.
"""
import math
import re

WORD = re.compile(r"([A-Z])\s*([-+]?\d*\.?\d+)")


class Move:
    __slots__ = ("kind", "s", "e", "feed", "tp", "line", "center", "radius", "sweep",
                 "length", "xy", "dz", "t0", "t1", "dwell")

    def __init__(self, kind, s, e, feed, tp, line):
        self.kind = kind          # 'G0', 'G1', 'G2', 'G3', 'G4' (dwell), 'STOP' (M-code / program event)
        self.s = s
        self.e = e
        self.feed = feed          # in/min for feeds
        self.tp = tp
        self.line = line
        self.center = None
        self.radius = 0.0
        self.sweep = 0.0
        self.length = 0.0
        self.xy = 0.0             # planar path length (arc length for arcs)
        self.dz = e[2] - s[2]
        self.t0 = None            # unit tangent at start (3D)
        self.t1 = None            # unit tangent at end
        self.dwell = 0.0

    @property
    def is_feed(self):
        return self.kind in ("G1", "G2", "G3")

    @property
    def is_arc(self):
        return self.kind in ("G2", "G3")


def _unit(v):
    n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    return None if n < 1e-12 else (v[0] / n, v[1] / n, v[2] / n)


def parse(path, start=(0.0, 0.0, 1.0)):
    """Returns (moves, tools) where tools maps T number -> (diameter, shape label, name)."""
    moves = []
    tools = {}
    tp_tool = {}
    pos = list(start)
    mode = None
    feed = None
    tp = "(preamble)"
    arc_radius_err = 0.0
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            m = re.match(r"^\(\s*T(\d+)\s+(.*?)\s+-\s+D([\d.]+)\s+(.*)\)$", line)
            if m:
                tools[int(m.group(1))] = (float(m.group(3)), m.group(4), m.group(2))
            m = re.match(r"^\(Toolpath:\s*(.*?)\s+Tool:\s*T(\d+)", line)
            if m:
                tp = m.group(1)
                tp_tool[tp] = int(m.group(2))
                continue
            code = re.sub(r"\(.*?\)", "", line).upper()
            if not code:
                continue
            words = WORD.findall(code)
            if not words:
                continue
            g = [float(v) for k, v in words if k == "G"]
            mw = [int(float(v)) for k, v in words if k == "M"]
            vals = {k: float(v) for k, v in words if k not in ("G", "M")}
            if "F" in vals:
                feed = vals["F"]
            for gv in g:
                if gv in (0, 1, 2, 3):
                    mode = int(gv)
            if 4 in g:
                mv = Move("G4", tuple(pos), tuple(pos), 0, tp, lineno)
                mv.dwell = vals.get("P", 0.0)
                moves.append(mv)
                continue
            if mw:
                # Tool change, spindle, pause, end: the machine comes to a stop here.
                moves.append(Move("STOP", tuple(pos), tuple(pos), 0, tp, lineno))
            if not any(k in vals for k in "XYZ"):
                continue
            e = [vals.get("X", pos[0]), vals.get("Y", pos[1]), vals.get("Z", pos[2])]
            s = tuple(pos)
            if mode is None:
                mode = 0
            kind = "G%d" % mode
            mv = Move(kind, s, tuple(e), feed if mode else 0, tp, lineno)
            if mode in (2, 3):
                cx, cy = s[0] + vals.get("I", 0.0), s[1] + vals.get("J", 0.0)
                r = math.hypot(s[0] - cx, s[1] - cy)
                re_ = math.hypot(e[0] - cx, e[1] - cy)
                arc_radius_err = max(arc_radius_err, abs(r - re_))
                a0 = math.atan2(s[1] - cy, s[0] - cx)
                a1 = math.atan2(e[1] - cy, e[0] - cx)
                if mode == 3:
                    sw = a1 - a0
                    while sw <= 1e-12:
                        sw += 2 * math.pi
                else:
                    sw = a0 - a1
                    while sw <= 1e-12:
                        sw += 2 * math.pi
                planar = r * sw
                mv.center = (cx, cy)
                mv.radius = r
                mv.sweep = sw
                mv.xy = planar
                mv.length = math.hypot(planar, mv.dz)
                sign = 1 if mode == 3 else -1
                # Planar tangent = radius vector rotated +-90 deg; blend in helical Z.
                def tan_at(px, py):
                    rx, ry = px - cx, py - cy
                    n = math.hypot(rx, ry) or 1.0
                    tx, ty = -sign * ry / n, sign * rx / n
                    return _unit((tx * planar, ty * planar, mv.dz))
                mv.t0 = tan_at(s[0], s[1])
                mv.t1 = tan_at(e[0], e[1])
            else:
                d = (e[0] - s[0], e[1] - s[1], e[2] - s[2])
                mv.xy = math.hypot(d[0], d[1])
                mv.length = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)
                mv.t0 = mv.t1 = _unit(d)
            if mv.length > 1e-9:
                moves.append(mv)
            pos = e
    return moves, tools, tp_tool, arc_radius_err
