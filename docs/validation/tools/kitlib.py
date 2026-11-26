# kitlib.py: shared helpers for the Validation Handbook's build scripts.
#
# A test page is a Markdown file under docs/validation/handbook/tests/ with a
# front matter block:
#
#   ---
#   id: VH-PRF-01
#   title: Profile inside, outside and on the line
#   family: profile
#   levels: 0, 1, 2, 3
#   ...
#   commands:
#   - nativecam-cli post docs/validation/projects/prf-coupon.nativecam -o prf-coupon.tap
#   ---
#
# `commands` are run by run-kit.py exactly as printed on the page.
#
# SPDX-License-Identifier: GPL-3.0-or-later

import glob, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
VALIDATION = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(VALIDATION))
HANDBOOK = os.path.join(VALIDATION, "handbook")
BUILD = os.path.join(VALIDATION, "build")
IMAGES = os.path.join(VALIDATION, "images")

LIST_KEYS = {"commands", "images", "projects", "manual"}


def read_page(path):
    text = open(path, encoding="utf-8").read()
    meta, body = {}, text
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if m:
        body = text[m.end():]
        key = None
        for line in m.group(1).splitlines():
            if line.startswith("- ") and key:
                meta.setdefault(key, []).append(line[2:].strip())
            elif ":" in line:
                key, _, value = line.partition(":")
                key, value = key.strip(), value.strip()
                if key in LIST_KEYS:
                    meta[key] = [value] if value else []
                else:
                    meta[key] = value
    meta["path"] = path
    return meta, body


def tests():
    out = []
    for path in sorted(glob.glob(os.path.join(HANDBOOK, "tests", "*.md"))):
        meta, body = read_page(path)
        out.append((meta, body))
    return out
