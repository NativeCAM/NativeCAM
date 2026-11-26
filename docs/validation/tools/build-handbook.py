#!/usr/bin/env python3
# build-handbook.py: turns the Validation Handbook's Markdown sources into one
# printable HTML page, for render-pdf.swift.
#
#   python3 docs/validation/tools/build-handbook.py letter|a4 <out.html>
#
# Sources, in order:
#   handbook/front/*.md       front matter (one section each)
#   handbook/families/*.md    one per test family, each followed by its tests
#   handbook/tests/*.md       the tests (front matter block + body), by file name
#   handbook/back/*.md        back matter
# plus build/kit-results.json from run-kit.py (what each command printed).
#
# The Markdown is a small subset: #–#### headings, paragraphs, - and 1. lists
# (nested by indent), pipe tables, ``` code blocks, > callouts, **bold**,
# *italic*, `code` and [links](url).
#
# SPDX-License-Identifier: GPL-3.0-or-later

import datetime, glob, html, json, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kitlib import BUILD, HANDBOOK, IMAGES, ROOT, read_page, tests

PAPER = sys.argv[1] if len(sys.argv) > 1 else "letter"
OUTFILE = sys.argv[2] if len(sys.argv) > 2 else os.path.join(BUILD, f"handbook-{PAPER}.html")
RESULTS = json.load(open(os.path.join(BUILD, "kit-results.json"))) if os.path.exists(
    os.path.join(BUILD, "kit-results.json")) else {}


# ------------------------------------------------------------------ Markdown

def inline(s):
    s = html.escape(s, quote=False)
    codes = []

    def keep(m):
        codes.append("<code>" + m.group(1) + "</code>")
        return f"\x00{len(codes) - 1}\x00"
    s = re.sub(r"`([^`]+)`", keep, s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", s)
    s = s.replace("[ ]", '<span class="box"></span>')
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], s)


def table(rows):
    cells = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows]
    head, body = cells[0], [r for r in cells[2:]]
    fill = [h.lower() in ("measured", "result", "✓", "pass", "pass?", "notes", "initials", "date", "value", "answer",
                          "count", "name", "signature") for h in head]
    wide = len(head) <= 3
    out = ['<table class="md"><thead><tr>' + "".join(f"<th>{inline(h)}</th>" for h in head) + "</tr></thead><tbody>"]
    for r in body:
        r = r + [""] * (len(head) - len(r))
        out.append("<tr>" + "".join(
            f'<td class="{("fill" + (" wide" if wide else "")) if fill[i] and not c else ""}">{inline(c)}</td>'
            for i, c in enumerate(r)) + "</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def lists(lines):
    """Nested lists from lines with their indents."""
    out, stack = [], []
    for line in lines:
        indent = len(line) - len(line.lstrip())
        text = line.strip()
        ordered = bool(re.match(r"\d+\. ", text))
        item = re.sub(r"^(\d+\.|[-*]) ", "", text)
        while stack and indent < stack[-1][0]:
            out.append(f"</li></{stack.pop()[1]}>")
        if not stack or indent > stack[-1][0]:
            tag = "ol" if ordered else "ul"
            cls = ' class="check"' if item.startswith("[ ]") else ""
            out.append(f"<{tag}{cls}><li>")
            stack.append((indent, tag))
        else:
            out.append("</li><li>")
        out.append(inline(item))
    while stack:
        out.append(f"</li></{stack.pop()[1]}>")
    return "".join(out)


def markdown(text, shift=0):
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith("```"):
            j = i + 1
            while j < len(lines) and not lines[j].startswith("```"):
                j += 1
            out.append("<pre>" + html.escape("\n".join(lines[i + 1:j])) + "</pre>")
            i = j + 1
            continue
        m = re.match(r"(#{1,4}) (.*)", line)
        if m:
            level = min(len(m.group(1)) + shift, 6)
            out.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
            i += 1
            continue
        if line.startswith("|"):
            j = i
            while j < len(lines) and lines[j].startswith("|"):
                j += 1
            out.append(table(lines[i:j]))
            i = j
            continue
        if line.startswith(">"):
            j = i
            while j < len(lines) and lines[j].startswith(">"):
                j += 1
            inner = "\n".join(l[1:].lstrip() if l.startswith("> ") or l == ">" else l[1:] for l in lines[i:j])
            kind = "warn" if re.match(r"\*\*(Warning|Danger|Stop|Safety)", inner) else "note"
            out.append(f'<div class="callout {kind}">{markdown(inner)}</div>')
            i = j
            continue
        if re.match(r"\s*([-*]|\d+\.) ", line):
            j = i
            while j < len(lines) and (re.match(r"\s*([-*]|\d+\.) ", lines[j]) or
                                      (lines[j].startswith("   ") and lines[j].strip())):
                j += 1
            block, merged = lines[i:j], []
            for b in block:
                if re.match(r"\s*([-*]|\d+\.) ", b) or not merged:
                    merged.append(b)
                else:
                    merged[-1] += " " + b.strip()
            out.append(lists(merged))
            i = j
            continue
        j = i
        while j < len(lines) and lines[j].strip() and not re.match(r"(#{1,4} |\||>|```|\s*([-*]|\d+\.) )", lines[j]):
            j += 1
        out.append("<p>" + inline(" ".join(l.strip() for l in lines[i:j])) + "</p>")
        i = j
    return "\n".join(out)


# ------------------------------------------------------------------ pages

toc = []          # (level, id, title)


def section(sid, title, body_html, cls="section"):
    toc.append((1, sid, title))
    marker = (f'<span class="m">@@S:{sid}@@</span>'
              f'<span data-section-id="{sid}" data-section-title="{html.escape(title)}"></span>')
    # The marker goes inside the section's first heading, so it lands on the page the heading starts.
    if "<h1>" in body_html:
        body_html = body_html.replace("<h1>", "<h1>" + marker, 1)
    else:
        body_html = marker + body_html
    return f'<section class="{cls}" id="{sid}">{body_html}</section>'


def md_section(path, cls="section"):
    meta, body = read_page(path)
    sid = os.path.splitext(os.path.basename(path))[0]
    title = meta.get("title") or re.search(r"^# (.*)$", body, re.M).group(1)
    body_html = markdown(body)
    if "{{RESULTS_LOG}}" in body_html:
        rows = "".join(f"<tr><td><strong>{t[0]['id']}</strong></td><td>{html.escape(t[0]['title'])}</td>"
                       f"<td>{html.escape(t[0].get('levels', ''))}</td><td class='fill'></td><td class='fill'></td>"
                       f"<td class='fill'></td><td class='fill'></td></tr>" for t in tests())
        body_html = body_html.replace("<p>{{RESULTS_LOG}}</p>", '<table class="md log"><thead><tr><th>Test</th>'
                                      '<th>Title</th><th>Levels</th><th>Highest level passed</th><th>Result</th>'
                                      '<th>Date</th><th>Initials</th></tr></thead><tbody>' + rows + "</tbody></table>")
    return meta, section(sid, title, body_html, cls)


def output_lines(tid):
    """The issue lines and summary lines each command printed, for the page."""
    entry = RESULTS.get(tid)
    if not entry:
        return ""
    blocks = []
    for c in entry["commands"]:
        keep = []
        for line in c["output"].splitlines():
            if line.startswith("Generated") and " -> " in line:
                line = re.sub(r" -> .*", "", line)
            line = re.sub(r" -> \S.*$", lambda m: " -> " + os.path.basename(m.group(0)[4:]), line)
            keep.append(line if len(line) < 400 else line[:397] + "…")
        if len(keep) > 36:
            keep = keep[:34] + [f"… ({len(keep) - 34} more lines)"]
        status = "exit 0" if c["exit"] == 0 else f"exit {c['exit']}"
        blocks.append(f'<div class="run"><div class="runcmd">$ {html.escape(c["command"])} '
                      f'<span class="exit">({status})</span></div>'
                      + ("<pre>" + html.escape("\n".join(keep)) + "</pre>" if keep else "") + "</div>")
    return "".join(blocks)


def facts_row(label, value):
    return f"<tr><th>{label}</th><td>{inline(value)}</td></tr>" if value else ""


LEVELS = {"0": "0 read-only", "1": "1 air cut", "2": "2 shallow cut", "3": "3 full cut"}


def test_page(meta, body):
    tid, title = meta["id"], meta["title"]
    toc.append((2, tid, f"{tid}  {title}"))
    levels = ", ".join(LEVELS.get(x.strip(), x.strip()) for x in meta.get("levels", "").split(","))
    status = meta.get("status", "Not yet run on a real machine")
    files = meta.get("projects", [])
    facts = "".join([
        facts_row("Validates", meta.get("validates", "")),
        facts_row("Levels", levels),
        facts_row("Risk", meta.get("risk", "")),
        facts_row("Time", meta.get("time", "")),
        facts_row("Stock", meta.get("stock", "")),
        facts_row("Bits", meta.get("bits", "")),
        facts_row("Project files", ", ".join(f"`projects/{f}`" for f in files) if files else ""),
        facts_row("Status", status),
    ])
    cmds = meta.get("commands", []) + meta.get("manual", [])
    cmd_html = ""
    if cmds:
        cmd_html = ('<div class="cmds"><div class="label">Make the program (from the repository folder)</div><pre>'
                    + html.escape("\n".join(cmds)) + "</pre></div>")
    imgs = ""
    entry = RESULTS.get(tid, {})
    for name in entry.get("images", []):
        imgs += (f'<figure><img src="../images/{name}" alt="Simulated heightmap for {tid}">'
                 f'<figcaption>Simulated result (<code>nativecam-cli sim --png</code>): darker is deeper.'
                 f'</figcaption></figure>')
    out = output_lines(tid)
    out_html = (f'<div class="printed"><h4>What NativeCAM printed when this kit was built</h4>'
                f'<p class="small">Every warning and note below is expected for this test unless the page '
                f'says otherwise. If your build prints something different, note it in the results box.</p>'
                f'{out}</div>') if out else ""
    results = f"""
<div class="results"><h4>Results: {tid}</h4>
<table class="rbox">
<tr><th>Date</th><td></td><th>Tester</th><td></td></tr>
<tr><th>Machine</th><td></td><th>Controller and version</th><td></td></tr>
<tr><th>NativeCAM build</th><td></td><th>Material</th><td></td></tr>
<tr><th>Levels run</th><td>☐ 0 &nbsp; ☐ 1 &nbsp; ☐ 2 &nbsp; ☐ 3</td><th>Result</th><td>☐ Pass &nbsp; ☐ Fail &nbsp; ☐ Not run</td></tr>
<tr><th>Notes</th><td colspan="3" class="notes"></td></tr>
</table></div>"""
    body_html = markdown(body, shift=1)
    return (f'<section class="test" id="{tid}">'
            f'<div class="thead"><div class="tid">{tid}</div><h2><span class="m">@@T:{tid}@@</span>{html.escape(title)}</h2></div>'
            f'<table class="facts">{facts}</table>{cmd_html}{body_html}{imgs}{out_html}{results}</section>')


def git(*args):
    try:
        return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""


commit = git("rev-parse", "--short", "HEAD") or "unknown"
fmt = "?"
try:
    src = open(os.path.join(ROOT, "Sources/CAMCore/Model/Project.swift")).read()
    fmt = re.search(r"currentFormatVersion\s*=\s*(\d+)", src).group(1)
except Exception:
    for p in glob.glob(os.path.join(ROOT, "Sources/CAMCore/**/*.swift"), recursive=True):
        m = re.search(r"currentFormatVersion\s*=\s*(\d+)", open(p).read())
        if m:
            fmt = m.group(1)
            break
built = datetime.date.today().isoformat()

all_tests = tests()
parts = []
for path in sorted(glob.glob(os.path.join(HANDBOOK, "front", "*.md"))):
    parts.append(md_section(path)[1])
for path in sorted(glob.glob(os.path.join(HANDBOOK, "families", "*.md"))):
    meta, sec = md_section(path, "section family")
    fam = meta.get("family")
    members = [t for t in all_tests if t[0].get("family") == fam]
    if members:
        listing = "".join(f"<tr><td><strong>{t[0]['id']}</strong></td><td>{html.escape(t[0]['title'])}</td>"
                          f"<td>{html.escape(t[0].get('levels', ''))}</td>"
                          f"<td class='pg'><span data-page-of=\"{t[0]['id']}\">000</span></td></tr>" for t in members)
        sec = sec.replace("</section>", '<table class="md famlist"><thead><tr><th>Test</th><th>What it checks</th>'
                                        '<th>Levels</th><th>Page</th></tr></thead><tbody>' + listing
                          + "</tbody></table></section>")
    parts.append(sec)
    for t in members:
        parts.append(test_page(*t))
for path in sorted(glob.glob(os.path.join(HANDBOOK, "back", "*.md"))):
    parts.append(md_section(path)[1])

missing = sorted({t[0]["family"] for t in all_tests} - {read_page(p)[0].get("family") for p in
                                                         glob.glob(os.path.join(HANDBOOK, "families", "*.md"))})
if missing:
    sys.exit(f"tests name families with no page: {missing}")

toc_html = "".join(
    f'<div class="toc{lvl}"><a href="#{sid}">{html.escape(title)}</a><span class="dots"></span>'
    f'<span class="pg" data-page-of="{sid}">000</span></div>' for lvl, sid, title in toc)

css = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "handbook.css")).read()
size = "A4" if PAPER == "a4" else "letter"
page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>NativeCAM Validation Handbook</title>
<style>@page {{ size: {size}; }}
{css}</style></head><body>
<section class="cover"><span class="m">@@S:cover@@</span>
<div class="cover-top">NativeCAM</div>
<h1>Validation Handbook</h1>
<p class="subtitle">Real-machine tests for the program files NativeCAM writes: what to cut, how to set it up, what to measure, and how to report it.</p>
<div class="cover-box">
<p><strong>For any NativeCAM user, on any supported machine and controller.</strong> Work through the levels in order: read the file, air-cut it, cut it shallow in foam or MDF, then cut it for real.</p>
<p><strong>{len(all_tests)} tests</strong> in {len(set(t[0]['family'] for t in all_tests))} families, with the project files in <code>docs/validation/projects/</code>.</p>
</div>
<div class="cover-warn"><strong>Read “Safety first” before you run anything.</strong> NativeCAM's output has been run on a real machine only for the Avid Mach4 profile. Treat every other controller, and every test marked “not yet run on a real machine”, as unverified.</div>
<p class="cover-meta">Built {built} from NativeCAM <code>{commit}</code>, project format {fmt}. US {('Letter' if PAPER != 'a4' else 'A4').replace('US A4', 'A4')} edition. GPL-3.0-or-later.</p>
</section>
<section class="toc">
<h1><span class="m">@@S:contents@@</span><span data-section-id="contents" data-section-title="Contents"></span>Contents</h1>{toc_html}</section>
{"".join(parts)}
</body></html>"""
page = page.replace("US A4", "A4")
os.makedirs(os.path.dirname(os.path.abspath(OUTFILE)), exist_ok=True)
open(OUTFILE, "w", encoding="utf-8").write(page)
print(f"Wrote {OUTFILE}: {len(all_tests)} tests, {len(toc)} contents entries")
