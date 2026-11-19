#!/usr/bin/env python3
"""Toolpath efficiency metrics for NativeCAM Mach4 .tap files.

Usage: analyze.py file.tap [--accel in_per_s2] [--json out.json]

Time models
  CV : constant velocity. Feeds at programmed F, rapids at RAPID in/min (what NativeCAM's estimate does).
  B  : trapezoidal velocity planner (look-ahead over the whole program), accel A in/s^2 on the path,
       full stop at any junction whose direction change exceeds STOP_ANGLE degrees, at M-codes and dwells;
       otherwise the junction may be taken at min(F_in, F_out).
  C  : B plus a centripetal limit on arcs (v <= sqrt(A*r)) and a junction-deviation limit (GRBL-style,
       delta = JD inches) on the shallow (<= STOP_ANGLE) junctions. Sensitivity case, stricter than B.
"""
import json
import math
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from gcode import parse, Move  # noqa: E402

RAPID = 400.0          # in/min
A = 15.0               # in/s^2
STOP_ANGLE = 30.0      # degrees
JD = 0.001             # junction deviation, inches (model C)
CLEAR = 0.5            # safe Z in the files
PLUNGE_Z = 0.1
TINY = 0.01            # inches


def vmax(m, model):
    if m.kind == "G0":
        return RAPID / 60.0
    v = (m.feed or RAPID) / 60.0
    if model == "C" and m.is_arc and m.radius > 0:
        v = min(v, math.sqrt(A * m.radius))
    return v


def junction_cap(a, b, model):
    """Max speed (in/s) through the junction between moves a -> b."""
    if a.kind in ("STOP", "G4") or b.kind in ("STOP", "G4"):
        return 0.0
    if a.t1 is None or b.t0 is None:
        return 0.0
    c = max(-1.0, min(1.0, sum(x * y for x, y in zip(a.t1, b.t0))))
    phi = math.degrees(math.acos(c))
    if phi > STOP_ANGLE:
        return 0.0
    v = min(vmax(a, model), vmax(b, model))
    if model == "C" and phi > 1e-6:
        ch = math.cos(math.radians(phi) / 2)     # = sin(theta/2) with theta the GRBL junction angle
        if ch < 1 - 1e-12:
            v = min(v, math.sqrt(A * JD * ch / (1 - ch)))
    return v


def seg_time(L, v0, v1, vm, a=None):
    a = a or A
    if L <= 0:
        return 0.0
    da = max(0.0, (vm * vm - v0 * v0) / (2 * a))
    dd = max(0.0, (vm * vm - v1 * v1) / (2 * a))
    if da + dd <= L:
        return (vm - v0) / a + (vm - v1) / a + (L - da - dd) / vm
    vp = math.sqrt(max(0.0, (2 * a * L + v0 * v0 + v1 * v1) / 2))
    vp = max(vp, v0, v1)
    return max(0.0, (vp - v0) / a) + max(0.0, (vp - v1) / a)


def plan(moves, model):
    """Per-move times for model 'CV', 'B' or 'C'."""
    n = len(moves)
    times = [0.0] * n
    if model == "CV":
        for i, m in enumerate(moves):
            if m.kind == "G4":
                times[i] = m.dwell
            elif m.kind != "STOP":
                times[i] = m.length / ((m.feed or RAPID) if m.is_feed else RAPID) * 60
        return times
    # Motion segments only; events become forced stops.
    segs = []
    for i, m in enumerate(moves):
        if m.kind == "G4":
            times[i] = m.dwell
        if m.kind in ("G0", "G1", "G2", "G3"):
            segs.append(i)
    k = len(segs)
    cap = [0.0] * (k + 1)
    for j in range(1, k):
        a, b = moves[segs[j - 1]], moves[segs[j]]
        # Any event between the two motions forces a stop.
        if segs[j] - segs[j - 1] > 1:
            cap[j] = 0.0
        else:
            cap[j] = junction_cap(a, b, model)
    v = cap[:]
    for j in range(k - 1, -1, -1):
        L = moves[segs[j]].length
        v[j] = min(v[j], math.sqrt(v[j + 1] ** 2 + 2 * A * L))
    for j in range(1, k + 1):
        L = moves[segs[j - 1]].length
        v[j] = min(v[j], math.sqrt(v[j - 1] ** 2 + 2 * A * L))
    for j in range(k):
        m = moves[segs[j]]
        times[segs[j]] = seg_time(m.length, v[j], v[j + 1], vmax(m, model))
    return times


def category(m):
    if m.kind == "G0":
        return "rapid_xy" if m.xy > 1e-6 else "rapid_z"
    if m.kind == "G4":
        return "dwell"
    if m.kind == "STOP":
        return "event"
    if m.xy < 1e-4 and m.dz < 0:
        return "plunge"
    if m.dz < -1e-6 and abs(m.dz) > 0.05 * m.xy:
        return "ramp/descend"
    return "cut"


def air_length(m):
    """Length of a feed move above the material top (Z > 0)."""
    z0, z1 = m.s[2], m.e[2]
    if z0 <= 1e-6 and z1 <= 1e-6:
        return 0.0
    if z0 >= -1e-6 and z1 >= -1e-6:
        return m.length
    f = (max(z0, z1) - 0) / abs(z1 - z0)
    return m.length * f


def links(moves):
    """Retract-to-clearance cycles inside one toolpath: (tp, hop_xy, z_from, z_to_after_plunge, idx range)."""
    out = []
    n = len(moves)
    i = 0
    while i < n:
        m = moves[i]
        if m.kind == "G0" and m.s[2] < CLEAR - 1e-6 and m.e[2] >= CLEAR - 1e-6 and m.xy < 1e-6:
            j = i + 1
            while j < n and moves[j].kind == "G0" and abs(moves[j].s[2] - moves[j].e[2]) < 1e-9 and moves[j].xy > 0:
                j += 1
            if j < n and moves[j].kind == "G0" and moves[j].e[2] < CLEAR - 1e-6 and moves[j].tp == m.tp:
                k = j + 1
                while k < n and moves[k].is_feed and moves[k].xy < 1e-4 and moves[k].dz < 0:
                    k += 1
                hop = math.hypot(moves[j].e[0] - m.s[0], moves[j].e[1] - m.s[1])
                out.append(dict(tp=m.tp, i=i, j=j, k=k, hop=hop, z_from=m.s[2], z_to=moves[k - 1].e[2]))
                i = j
                continue
        i += 1
    return out


def summarize(moves, label):
    tps = []
    for m in moves:
        if m.tp not in tps:
            tps.append(m.tp)
    tcv, tb, tc = plan(moves, "CV"), plan(moves, "B"), plan(moves, "C")
    lk = links(moves)
    rows = {}
    for name in tps + ["TOTAL"]:
        sel = [i for i, m in enumerate(moves) if (name == "TOTAL" or m.tp == name)]
        feeds = [moves[i] for i in sel if moves[i].is_feed]
        rapids = [moves[i] for i in sel if moves[i].kind == "G0"]
        arcs = [m for m in feeds if m.is_arc]
        r = {}
        r["cut_len"] = sum(m.length for m in feeds)
        r["air_feed_len"] = sum(air_length(m) for m in feeds)
        r["rapid_len"] = sum(m.length for m in rapids)
        r["rapid_xy"] = sum(m.xy for m in rapids)
        r["rapid_z"] = sum(abs(m.dz) for m in rapids)
        r["rapid_z_up"] = sum(m.dz for m in rapids if m.dz > 0)
        r["retracts_to_clear"] = sum(1 for m in rapids if m.s[2] < CLEAR - 1e-6 and m.e[2] >= CLEAR - 1e-6)
        r["partial_retracts"] = sum(1 for m in rapids if m.dz > 1e-6 and m.e[2] < CLEAR - 1e-6)
        r["plunges"] = sum(1 for m in feeds if m.xy < 1e-4 and m.dz < 0)
        r["plunge_len"] = sum(-m.dz for m in feeds if m.xy < 1e-4 and m.dz < 0)
        r["entries"] = sum(1 for m in feeds if m.s[2] > 1e-6 and m.e[2] < 1e-6)  # feed moves crossing the top
        r["n_feed"] = len(feeds)
        r["avg_seg"] = r["cut_len"] / len(feeds) if feeds else 0
        r["median_seg"] = sorted(m.length for m in feeds)[len(feeds) // 2] if feeds else 0
        r["tiny"] = sum(1 for m in feeds if m.length < TINY)
        r["tiny_share"] = r["tiny"] / len(feeds) if feeds else 0
        r["arc_count_share"] = len(arcs) / len(feeds) if feeds else 0
        r["arc_len_share"] = sum(m.length for m in arcs) / r["cut_len"] if r["cut_len"] else 0
        # Direction changes between consecutive feed moves.
        sharp = 0
        for a_, b_ in zip(sel, sel[1:]):
            a, b = moves[a_], moves[b_]
            if a.t1 and b.t0 and (a.is_feed or b.is_feed) and a.kind != "STOP" and b.kind != "STOP":
                c = max(-1, min(1, sum(x * y for x, y in zip(a.t1, b.t0))))
                if math.degrees(math.acos(c)) > STOP_ANGLE:
                    sharp += 1
        r["sharp_corners"] = sharp
        for model, t in (("cv", tcv), ("b", tb), ("c", tc)):
            r["t_" + model] = sum(t[i] for i in sel)
            r["t_%s_feed" % model] = sum(t[i] for i in sel if moves[i].is_feed)
            r["t_%s_rapid" % model] = sum(t[i] for i in sel if moves[i].kind == "G0")
            r["t_%s_dwell" % model] = sum(t[i] for i in sel if moves[i].kind == "G4")
            cats = {}
            for i in sel:
                c = category(moves[i])
                cats[c] = cats.get(c, 0) + t[i]
            r["cat_" + model] = cats
        # Feed-rate histogram (length and CV time) by F.
        byf = {}
        for i in sel:
            m = moves[i]
            if m.is_feed:
                d = byf.setdefault(m.feed, [0.0, 0.0, 0.0])
                d[0] += m.length
                d[1] += tcv[i]
                d[2] += tb[i]
        r["by_feed"] = {str(k): v for k, v in sorted(byf.items())}
        L = [x for x in lk if name == "TOTAL" or x["tp"] == name]
        r["links"] = len(L)
        r["link_hops"] = sorted(round(x["hop"], 3) for x in L)
        r["link_time_cv"] = sum(sum(tcv[q] for q in range(x["i"], x["k"])) for x in L)
        r["link_time_b"] = sum(sum(tb[q] for q in range(x["i"], x["k"])) for x in L)
        rows[name] = r
    return rows


def fmt_time(s):
    s = int(round(s))
    return "%d:%02d:%02d" % (s // 3600, (s // 60) % 60, s % 60)


def print_table(rows, title):
    print("=" * 100)
    print(title)
    keys = list(rows)
    hdr = "%-28s" % "metric" + "".join("%16s" % k[:15] for k in keys)
    print(hdr)
    def line(label, f):
        print("%-28s" % label + "".join("%16s" % f(rows[k]) for k in keys))
    line("cutting length (in)", lambda r: "%.1f" % r["cut_len"])
    line("  of which above Z0 (in)", lambda r: "%.1f" % r["air_feed_len"])
    line("rapid length (in)", lambda r: "%.1f" % r["rapid_len"])
    line("  rapid XY (in)", lambda r: "%.1f" % r["rapid_xy"])
    line("  rapid Z (in)", lambda r: "%.1f" % r["rapid_z"])
    line("retracts to clearance", lambda r: r["retracts_to_clear"])
    line("partial retracts", lambda r: r["partial_retracts"])
    line("vertical plunges", lambda r: r["plunges"])
    line("  plunge depth sum (in)", lambda r: "%.2f" % r["plunge_len"])
    line("feed moves", lambda r: r["n_feed"])
    line("avg feed seg (in)", lambda r: "%.4f" % r["avg_seg"])
    line("median feed seg (in)", lambda r: "%.4f" % r["median_seg"])
    line("tiny segs <0.01in", lambda r: "%d (%.0f%%)" % (r["tiny"], 100 * r["tiny_share"]))
    line("arcs: share of moves", lambda r: "%.0f%%" % (100 * r["arc_count_share"]))
    line("arcs: share of length", lambda r: "%.0f%%" % (100 * r["arc_len_share"]))
    line("corners > 30 deg", lambda r: r["sharp_corners"])
    line("in-op retract links", lambda r: r["links"])
    line("time CV", lambda r: fmt_time(r["t_cv"]))
    line("  CV feed", lambda r: fmt_time(r["t_cv_feed"]))
    line("  CV rapid", lambda r: fmt_time(r["t_cv_rapid"]))
    line("  CV dwell", lambda r: fmt_time(r["t_cv_dwell"]))
    line("time B (accel)", lambda r: fmt_time(r["t_b"]))
    line("  B feed", lambda r: fmt_time(r["t_b_feed"]))
    line("  B rapid", lambda r: fmt_time(r["t_b_rapid"]))
    line("  B / CV", lambda r: "%.2fx" % (r["t_b"] / r["t_cv"] if r["t_cv"] else 0))
    line("time C (strict)", lambda r: fmt_time(r["t_c"]))
    line("  C / CV", lambda r: "%.2fx" % (r["t_c"] / r["t_cv"] if r["t_cv"] else 0))
    line("link time CV (s)", lambda r: "%.0f" % r["link_time_cv"])
    line("link time B (s)", lambda r: "%.0f" % r["link_time_b"])


if __name__ == "__main__":
    path = sys.argv[1]
    if "--accel" in sys.argv:  # acceleration in in/s^2 (default 15)
        globals()["A"] = float(sys.argv[sys.argv.index("--accel") + 1])
    moves, tools, tp_tool, err = parse(path)
    rows = summarize(moves, path)
    print_table(rows, path)
    print("max arc radius mismatch (in): %.5f" % err)
    for k, r in rows.items():
        print("--", k)
        print("   categories CV:", {c: round(v, 1) for c, v in r["cat_cv"].items()})
        print("   categories B :", {c: round(v, 1) for c, v in r["cat_b"].items()})
        print("   by feed F: [len, tCV, tB]", {f: [round(x, 1) for x in v] for f, v in r["by_feed"].items()})
        hops = r["link_hops"]
        if hops and k != "TOTAL":
            print("   link hops (in): n=%d min=%.3f med=%.3f max=%.3f  <=0.5in: %d" % (
                len(hops), hops[0], hops[len(hops) // 2], hops[-1], sum(1 for h in hops if h <= 0.5)))
    if "--json" in sys.argv:
        with open(sys.argv[sys.argv.index("--json") + 1], "w") as fh:
            json.dump(rows, fh, indent=1)
