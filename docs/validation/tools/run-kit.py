#!/usr/bin/env python3
# run-kit.py: runs every command the handbook's test pages print, into
# docs/validation/build/out/, and records what each printed in
# docs/validation/build/kit-results.json for the handbook. Also draws each
# test's heightmap with `nativecam-cli sim --png` into docs/validation/images/.
#
#   python3 docs/validation/tools/run-kit.py <nativecam-cli>
#
# Fails (exit 1) if a `post` exits non-zero or prints an [error], since every kit
# project must post cleanly without --force.
#
# SPDX-License-Identifier: GPL-3.0-or-later

import json, os, shlex, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kitlib import BUILD, IMAGES, ROOT, tests

CLI = os.path.abspath(sys.argv[1])
OUT = os.path.join(BUILD, "out")
os.makedirs(OUT, exist_ok=True)
os.makedirs(IMAGES, exist_ok=True)


def run(command):
    args = shlex.split(command)
    assert args[0] == "nativecam-cli", command
    args = [CLI] + [os.path.join(ROOT, a) if a.startswith(("docs/validation/", "Tests/")) else a for a in args[1:]]
    p = subprocess.run(args, cwd=OUT, capture_output=True, text=True)
    text = (p.stdout + p.stderr).replace(OUT + "/", "").replace(ROOT + "/", "")
    return p.returncode, text


results, failed = {}, []
for meta, _ in tests():
    tid = meta["id"]
    entry = {"commands": []}
    # `refused` commands are printed on the page like `commands`, but the test is that
    # post refuses them: exit 1 with an [error] and no file.
    refused = meta.get("refused", [])
    for command in meta.get("commands", []) + refused:
        code, text = run(command)
        entry["commands"].append({"command": command, "exit": code, "output": text})
        if command in refused:
            if code != 1 or "[error]" not in text:
                failed.append(f"{tid}: expected post to refuse: {command} (exit {code})")
        elif " post " in f" {command} " and (code != 0 or "[error]" in text):
            failed.append(f"{tid}: {command} (exit {code})")
        print(f"{tid}: exit {code}: {command}")
    for i, project in enumerate(meta.get("images", [])):
        name = f"{tid}{'' if i == 0 else '-' + str(i + 1)}.png"
        code, text = run(f"nativecam-cli sim docs/validation/projects/{project} --png {name} --cell 0.4")
        if code == 0 and os.path.exists(os.path.join(OUT, name)):
            os.replace(os.path.join(OUT, name), os.path.join(IMAGES, name))
            # Greyscale, so the book prints the same in black and white (macOS's own sips).
            subprocess.run(["sips", "--matchTo", "/System/Library/ColorSync/Profiles/Generic Gray Profile.icc",
                            os.path.join(IMAGES, name)], capture_output=True)
            entry.setdefault("images", []).append(name)
            entry.setdefault("sim", []).append(text)
        else:
            failed.append(f"{tid}: sim {project} (exit {code})")
        print(f"{tid}: sim {project} -> images/{name}")
    results[tid] = entry

json.dump(results, open(os.path.join(BUILD, "kit-results.json"), "w"), indent=1)
if failed:
    print("\nFAILED:\n  " + "\n  ".join(failed))
    sys.exit(1)
print(f"\n{len(results)} tests, every command ran cleanly.")
