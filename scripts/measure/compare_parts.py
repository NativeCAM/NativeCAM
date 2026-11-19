#!/usr/bin/env python3
"""Compare two simulated height maps (from `nativecam-cli sim ... --heights`) inside the finished part.

Usage: compare_parts.py before.bin after.bin --ellipse cx cy rx ry   (mm, design coordinates)
       compare_parts.py before.bin after.bin --rect x0 y0 x1 y1
Reports how many part cells differ by more than 0.005 in (0.127 mm) and the largest difference, both ways.
Inputs must use the same grid (same stock and --cell).
"""
import struct
import sys


def load(path):
    with open(path, "rb") as fh:
        cols, rows = struct.unpack("<ii", fh.read(8))
        cell, ox, oy = struct.unpack("<ddd", fh.read(24))
        heights = struct.unpack(f"<{cols * rows}f", fh.read(4 * cols * rows))
    return cols, rows, cell, ox, oy, heights


def main():
    a, b = load(sys.argv[1]), load(sys.argv[2])
    if a[:5] != b[:5]:
        sys.exit("grids differ; simulate both with the same project stock and --cell")
    cols, rows, cell, ox, oy, ha = a
    hb = b[5]
    kind = sys.argv[3]
    vals = [float(v) for v in sys.argv[4:8]]
    if kind == "--ellipse":
        cx, cy, rx, ry = vals
        inside = lambda x, y: ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1
    else:
        x0, y0, x1, y1 = vals
        inside = lambda x, y: x0 <= x <= x1 and y0 <= y <= y1
    total = over = 0
    deeper = shallower = 0.0
    for r in range(rows):
        y = oy + r * cell
        for c in range(cols):
            x = ox + c * cell
            if not inside(x, y):
                continue
            total += 1
            d = hb[r * cols + c] - ha[r * cols + c]  # + = after leaves more material
            if abs(d) > 0.127:
                over += 1
            shallower = max(shallower, d)
            deeper = max(deeper, -d)
    print(f"part cells: {total}, differing > 0.005 in: {over} ({100 * over / max(total, 1):.2f}%)")
    print(f"max extra material left: {shallower / 25.4:.4f} in, max extra cut: {deeper / 25.4:.4f} in")


if __name__ == "__main__":
    main()
