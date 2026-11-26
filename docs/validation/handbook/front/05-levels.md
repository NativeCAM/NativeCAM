---
title: The test levels
---
# The test levels

Each test runs in up to four levels, from no risk to full risk. Do them in order, and don't move on until the level before has passed. Each test page lists the levels that apply to it and adds its own checks.

| Level | What you do | Risk | Material |
|---|---|---|---|
| **0** Read-only | Read the file, load it in the controller, simulate it | None: nothing moves | None |
| **1** Air cut | Run the program with every Z raised above the material | Low: the machine moves, the bit cuts nothing | None, or a scrap target |
| **2** Shallow cut | Cut in foam, or in MDF with the Z zero raised so cuts are shallow | Medium | Rigid foam or MDF |
| **3** Full cut | Cut as designed, at full depth | Full | MDF, plywood or hardwood as listed |

## Level 0: read-only

Do these for every file, on every test.

1. **Make the file** with the commands on the test page (or Export in the app), and keep `post`'s output. Note every `[warning]` and `[info]`; compare them with the ones printed on the test page. A file `post` refused (an `[error]`, exit status 1) is a failed test: never force it.
2. **Read the header.** Open the file in a text editor:
   - the post's name and your machine;
   - the units: `G20` (inches) or `G21` (mm) on the first motion line, or ShopBot's unit check;
   - the material size, XY zero and Z zero, matching the setup sheet;
   - the program extents: X, Y and Z ranges that fit your machine and your material;
   - the tool list, numbered as on the setup sheet.
3. **Read the tool changes.** For each tool: a retract, the spindle stopping, the change itself (`T#M6`, `T# M6`, an `M0` pause, or a new file per tool), the spindle restarting with an `S` word and, where set, a dwell.
4. **Read the end.** A retract, the park move, spindle off (`M5`), coolant or dust off (`M9`) and the program end (`M30`, or `END` on ShopBot).
5. **Load it in your controller** (or its sender) without running it: no errors on load, the toolpath preview where you expect it on the table, and the controller's extents matching the header's.
6. **Simulate it** in NativeCAM (**⌘R**, or `nativecam-cli sim project --png out.png`), and compare with the picture on the test page.

## Level 1: air cut

1. Export the **air cut** (**File ▸ Export Air Cut…**, or `post … --air-cut 1`): every Z, the safe height and the park height are raised by the amount you choose (1 in or 25 mm unless the page says otherwise); X and Y are unchanged. The file's first comment says it's an air cut.
2. Zero X, Y and Z exactly as for the real cut (on the material top), so the air cut runs where the real one will.
3. Run it with the spindle on (or off, if your controller allows and the page says so), watching:
   - every move goes where the setup sheet says, in the right order, inside the material's outline;
   - no move toward a clamp;
   - each tool change stops and waits, and you can re-zero Z;
   - the program ends at the park position with the spindle off.
4. Time it if the page asks, and compare with the estimate.

## Level 2: shallow cut

Cut in **rigid foam** with the real program, or in **MDF** with Z zeroed above the top: set Z zero, then raise the zero by about 80% of the deepest cut (so a 0.25 in pocket cuts about 0.05 in deep). In foam, use the real Z zero. Check positions and shapes: depths will be shallow by the amount you raised.

> **Warning.** Raising Z zero makes through-cuts shallow, so parts stay attached. That's intended at Level 2. Don't do it for drilling with pecks or helices you need to judge for chip clearing.

## Level 3: full cut

Cut the program as designed, in the material listed. Measure what the test page asks with calipers and a depth gauge, and fill in the **Measured** column. A dimension outside its tolerance is a failure: photograph it before you move the part.

## Tolerances

Unless a test says otherwise, judge sizes against the drawing with these limits. They allow for a hobby machine's rigidity and the bit's own deflection; tighter results are welcome.

| What | Tolerance |
|---|---|
| Lengths and diameters cut with an end mill | ±0.005 in (±0.13 mm) |
| Positions (hole centres, features against each other) | ±0.005 in (±0.13 mm) |
| Depths (pocket floors, grooves) | ±0.005 in (±0.13 mm) |
| V-carve depths and widths | ±0.010 in (±0.25 mm) |
| Tab thickness | ±0.010 in (±0.25 mm) |
| Run time against the estimate | ±15% (estimates use class defaults until calibrated) |
