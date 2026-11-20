# Controllers and G-code

[← Back to the README](../README.md)

- [Supported controllers](#supported-controllers)
- [Avid Mach4](#avid-mach4)
- [Grbl family](#grbl-family)
- [Other controllers](#other-controllers)
- [Using your own Vectric post](#using-your-own-vectric-post)
- [Export checks, air cuts and setup sheets](#export-checks-air-cuts-and-setup-sheets)
- [Trying a new controller safely](#trying-a-new-controller-safely)

NativeCAM writes each controller's own dialect, and the export checks hold every file to that controller's rules. Pick the controller under **Job Setup ▸ Machine ▸ Controller** or with the [setup assistant](machines.md#setting-up-a-machine).

## Supported controllers

| Controller | Machines | Files | Status |
|---|---|---|---|
| Avid Mach4 | Avid PRO series on Mach4 | `.tap` | Run on a real machine |
| Grbl 1.1, grblHAL, FluidNC, Carbide Motion | Shapeoko, X-Carve, LongMill, AltMill, many DIY machines | `.nc` | From documentation and firmware source |
| LinuxCNC | LinuxCNC and PathPilot machines | `.ngc` | From documentation |
| Masso | Masso G3 machines, Onefinity Elite (Masso) | `.nc` | From documentation |
| Centroid CNC12 | Acorn, Oak, Avid EX | `.cnc` | From Avid's EX posts |
| Buildbotics | Onefinity (original controller) | `.nc` | From documentation |
| ShopBot | ShopBot (OpenSBP part files) | `.sbp` | From ShopBot's command reference and vendor posts |
| RichAuto DSP | Axiom and many full-sheet routers | `.nc` | Conservative, as its handling is undocumented |
| Anything else | With your own Vectric `.pp` | The post's | Checked against the controller's rules where known |

Only Avid Mach4 output has run on a real machine so far. Treat the rest as unverified: [run the acceptance test](#trying-a-new-controller-safely), then air-cut.

## Avid Mach4

The post is modelled on Avid's own Vectric post (v3) and Fusion 360 post, so files behave like the ones Avid supports:

- `.tap` extension, CRLF line endings, parenthesised comments (nested parentheses become braces)
- Safety line `G00 G94 G20 G17 G90 G40 G49 G80` (or `G21` for metric), then `G91.1` for incremental I/J and `G64`
- Tool changes retract, stop the spindle, then call `T#M6`, so Avid's M6 macro handles the manual change and touch plate. ATC machines also get `G43 H#`. An optional `M00` pause mode is available for setups without an M6 macro.
- `M07` turns the dust collector on after each tool change, then `S#### M03` and an optional `G04 P#` spin-up dwell (always written with a decimal point, which every Mach4 build reads as seconds)
- Arcs as `G02`/`G03` with I/J, each under 180°, including helical arcs. 4 decimal places in inches, 3 in millimetres.
- Footer retracts, parks, then `M05`, `M09`, `M30`

<details>
<summary>Sample output (excerpt from posting the demo sign)</summary>

```gcode
(Demo sign)
(Post: Avid CNC Mach4 - NativeCAM 0.1)
(Created: 2026-11-19 07:38)
(Machine: PRO6060 {5 x 5 ft}, spindle, Manual {M6})
(Material: Baltic birch plywood X=24.0000 Y=18.0000 Z=0.7500 in)
(Z zero: Material top   XY zero: Lower left)
(Program extents: X0.8750 to X23.1250  Y0.8750 to Y17.1250  Z-0.7700 to Z0.1000)
(Safe Z = 0.5000)
(Tools used:)
(  T5 60deg V-Bit 1/2in - D0.5000 V-Bit)
(  T1 1/4in Upcut End Mill - D0.2500 End Mill)
G00 G94 G20 G17 G90 G40 G49 G80
G91.1
(Change to Tool: T5 60deg V-Bit 1/2in)
T5M6
M07
S18000 M03
(Toolpath: V-carve title  Tool: T5 60deg V-Bit 1/2in)
G00 Z0.5000
G00 X7.1025 Y9.7568
G00 Z0.1000
G01 Z-0.0117 F30.0
```

</details>

## Grbl family

Grbl 1.1, grblHAL, FluidNC and Carbide Motion have strict parsers, so the post only writes what each one accepts:

- `G90 G94 G17` and `G20`/`G21`; no `G64`, `G90.1`, `G43 H` or canned cycles. `.nc` files with LF line endings, every line within Grbl's 79-character limit (126 on FluidNC); long comments are shortened.
- `M8` for the dust collector (stock Grbl has no `M7`), `S#### M3`, and `G4 P` dwells in seconds.
- Arcs as `G2`/`G3` with incremental I/J, cut as lines where rounding would trip Grbl's arc check (error 33).
- **Tool changes.** Stock Grbl rejects `M6` but keeps running the lines after it, so the next tool's cuts would run with the old bit. NativeCAM writes `T# M6` only where something stops for it: Carbide Motion, a tool changer, or gSender or CNCjs named as the program that sends the file (the export check then reminds you to set it to pause). Otherwise each tool gets **its own file**, as Vectric does for Grbl, because many senders won't jog or probe during an `M0` pause. Choosing the pause (`M0`) tool change keeps one file for senders that handle it.
- Run-time estimates use Grbl's planner: 16 blocks of look-ahead, a 0.01 mm junction deviation (Grbl's `$11` default) and rapids blended like feeds.

## Other controllers

| Controller | What NativeCAM writes |
|---|---|
| LinuxCNC | `.ngc`; `G91.1` and `G64 P` blending at the arc tolerance; `T# M6` then `G43 H#` (LinuxCNC's M6 doesn't apply the tool length); `M8`; `G4 P` in seconds; checked strictly, as LinuxCNC rejects anything it doesn't know |
| Masso | `.nc`; `T# M06` (Masso applies the length itself); `G4 P` in whole **milliseconds**; no `G43`, `G64` or `G91.1`, which Masso's documentation doesn't list |
| Centroid CNC12 | `.cnc` with CRLF, as Avid's EX posts write; `T# M6` then `G43 H#` from CNC12's tool library (a tool with no length gets 0, so re-zeroing Z still works); `M7` |
| Buildbotics | `.nc`; `G91.1`; `T# M6`, which pauses for the change by default |
| ShopBot (OpenSBP) | `.sbp` part files, not G-code: a check of ShopBot's unit setting before any move, `SA`, `MS`/`JS` speeds in units per second, `M2`/`M3`/`MZ` and `J2`/`J3`/`JZ` moves, `CG` arcs (depth-changing arcs as short moves), `PAUSE n` dwells and `END`. Spindle `TR`/`C6`/`C7` and tool change `&Tool`/`C9` follow ShopBot's own posts. Without a tool changer each tool gets its own file. NativeCAM reads `.sbp` files back to check them, and **Simulate G-code File…** opens them too. |
| RichAuto DSP | `.nc` in millimetres only, with no comments and arcs as short lines (their handling isn't documented), one file per tool |

## Using your own Vectric post

For a controller NativeCAM has no post for, **Job Setup ▸ G-code Output ▸ Use a Vectric Post…** runs your own Vectric `.pp` file (the one your machine's maker publishes for VCarve or Aspire) as a template:

- NativeCAM fills its header, tool-change, spindle and move blocks and its variable formats.
- Arcs the post can't express are written as short lines, and a post with no tool-change block saves a file per tool.
- Posts that need rotary wrapping or inverse-time feeds are refused, with the reason.
- Before you use it, the sheet compares the post's output with NativeCAM's own post on the acceptance test program and shows any lines that differ.

Every exported file still goes through the export checks, which use the controller's rules when NativeCAM knows them. The project keeps its own copy of the post (saved as format 2); NativeCAM never ships or shares anyone's posts.

## Export checks, air cuts and setup sheets

On export, NativeCAM reads the file it's about to save back and checks it before the save panel appears:

- **Against the controller.** Units set before moving and matching the machine, line length, accepted codes, I/J only on arcs, arc radii within the controller's tolerance, a feed before the first feed move, tool numbers, dwells written so the controller reads the right unit, the spindle on before cutting, a lift to safe Z before the first sideways move after each tool change, no rotary (A) moves for a controller without a rotary axis, on a blank turned by hand no pause for a turn with the spindle running or the tool below safe Z, and the inverse-time (`G93`) rules: an F word on every `G93` move, no arcs in `G93`, `G94` back on before any stop, and a feed given again after it.
- **Against the toolpaths.** Every cutting move, arc direction and centre, feed, dwell, tool and spindle speed is compared with what the toolpaths asked for, and on a rotary job, the angle the blank is at (its A position, or the angle the last pause asked for when it's turned by hand) and every inverse-time F. This catches post bugs a simulation of the toolpaths can't, such as doubled coordinates or a dwell in the wrong unit.
- **Against the machine.** The whole program, retracts and park included, is measured against the machine's travel and Z travel with the tool's stick-out.

Errors ask you to confirm before exporting; the command line refuses to write a failing file without `--force`.

**File ▸ Export Air Cut…** (**⌥⌘E**) saves the same program with every Z, the safe height and the park height raised by an amount you choose, X and Y unchanged, marked by a comment at the top. **File ▸ Export Setup Sheet…** saves a printable HTML page with the machine, material and zero, tools in loading order, the run order with tool changes and times, clamps, and any open checks.

## Trying a new controller safely

The acceptance program has a square, circles from 1 to 50 mm radius in all four quadrants, a helix, a 3-second dwell and two tool changes. Run it in check mode first where the controller has one (Grbl's `$C`), then as an air cut, then 0.5 mm deep in scrap, and measure the circles: unit and arc errors show up in their sizes, and re-zero errors in the depth after each tool change. Save it from the last page of the setup assistant, or:

```bash
swift run -c release nativecam-cli acceptance --controller grbl --sender gSender --units mm
```

Results from your own machine are very welcome; they're what moves a controller from "from documentation" to tested.
