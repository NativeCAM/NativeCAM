# Machines

[← Back to the README](../README.md)

- [Setting up a machine](#setting-up-a-machine)
- [The machine catalogue](#the-machine-catalogue)
- [Importing controller settings](#importing-controller-settings)
- [Run-time estimates](#run-time-estimates)

## Setting up a machine

**Settings ▸ Machine ▸ Set Up a Machine…** (or the **Machine** menu in Job Setup) walks through what forum threads show people getting wrong:

1. **Machine.** Pick the vendor, model and size from the [built-in catalogue](#the-machine-catalogue), start from a generic machine, or import your controller's settings.
2. **Controller.** When a machine can run more than one (an Avid PRO on Mach4 or the newer EX, which runs Centroid CNC12), choose yours. For Grbl, say which program sends the files, since that decides whether a tool change can stop the job (see [Grbl family](controllers.md#grbl-family)).
3. **Setup.** The G-code units your controller runs in, how tools change, the spindle and the dust collector, and travel for a custom machine. Import `$$` or `Machine.ini` here for real speeds and accelerations.
4. **Summary.** A plain-language description of what NativeCAM will write ("Grbl can't stop for a tool change, so a job with several tools is saved as one file per tool…"), a preview of the [acceptance test program](controllers.md#trying-a-new-controller-safely), and a button to save it.

The machine goes into your machine library (`machines.json` beside `tools.json` in `~/Library/Application Support/NativeCAM/`). **Settings ▸ Machine** lists your saved machines and picks the one new documents start with; until you change it, that's an Avid PRO6060 on Mach4. Each document keeps its own copy, so it posts the same G-code later, and Job Setup offers the library's newer settings when a saved machine changes.

You can also set the controller directly under **Job Setup ▸ Machine ▸ Controller**, with **Sends files with** for Grbl-family machines.

## The machine catalogue

The catalogue holds 37 hobby and prosumer routers from 20 makers: Avid, Carbide 3D (Shapeoko, HDM, Nomad), Inventables (X-Carve), Sienci Labs (LongMill, AltMill), BobsCNC, Genmitsu, FoxAlien, TwoTrees, OpenBuilds, MillRight, Rat Rig, Maslow, Onefinity, ShopBot, Axiom, Stepcraft, Tormach, ShopSabre and generic full-sheet routers. Each entry lists the controllers that machine can run, its travel, spindle, speeds and defaults.

Every value has a source: the maker's published specs, the controller settings the maker ships, or a labelled estimate. Makers almost never publish acceleration, so those values are class defaults (for example, belt-driven Grbl machines about 500 mm/s² on X and Y) until you import your controller's settings. Machines without a published rapid speed use their maximum feed for estimates. Only the developer's own Avid PRO6060 is marked as tested.

## Importing controller settings

Controller settings are the only files that hold a machine's real per-axis speeds and accelerations. **Import Controller Settings…** in the machine's **Motion** section (or **Paste Grbl $$…**) reads:

| Source | What NativeCAM takes from it |
|---|---|
| Mach4 `Machine.ini` | Motor velocity and acceleration (stored in counts, divided by `CountsPerUnit`), axis-to-motor mapping (a gantry takes its slower motor), soft-limit travel, the spindle range and the G-code units. The A motor's velocity (in degrees, whatever the linear units) becomes the rotary axis's **Turn speed**, when the machine's rotary axis is on; its acceleration is shown in the notes but not used yet. Avid publishes no speed for its rotary: its Mach4 setup writes the A motor's tuning when you choose the rotary, so your own `Machine.ini` is where it comes from. |
| Grbl / grblHAL `$$` | `$110`–`$112` rates, `$120`–`$122` accelerations, `$130`–`$132` travel, `$11` junction deviation, `$30`/`$31` spindle range, with notes for laser mode, soft limits off and grblHAL's `$341` tool-change mode. Grbl 0.8's older numbering is refused. |
| LinuxCNC INI | `[AXIS_X]` (or `[AXIS_0]`) limits, velocities and accelerations (per second), `LINEAR_UNITS`, `[SPINDLE_0]` |
| FluidNC `config.yaml` | The `axes` map's rates, accelerations and travel, the spindle `speed_map`, and whether an ATC is configured |
| Fusion 360 `.mch` | Axis limits, controller speeds, spindle range and tool-change time (no acceleration) |

A sheet shows each value next to the current one, with where it came from; you pick which to apply. Each applied value records its source, so you can tell your own numbers from estimates. Mach3 profiles and Masso's `.htg` files are refused with the reason. The same import is on the command line: `nativecam-cli machine <file> --apply project.nativecam`.

## Run-time estimates

Estimates time the posted moves with a look-ahead motion planner model rather than dividing distance by feed:

- per-axis acceleration and rapid speeds, corner speeds from a junction tolerance, and arc speed limits
- the controller's own planner: Mach4's 20-line look-ahead with rapids in exact stop, Grbl's 16 blocks with blended rapids and a 0.01 mm junction deviation, and so on for each controller
- tool-change and spindle time
- on a rotary job, each turn of the blank at the rotary axis's turn speed (**Material & Machine ▸ Rotary Axis**), or 30 seconds for each turn by hand; wrapped moves (`G93`) take the time their inverse-time feed gives them

The simulation plays the job at the same pace, tool changes and the moves between toolpaths included, so its clock ends at the estimate.

Drive tier, acceleration and these settings live under **Material & Machine ▸ Motion**. The machine summary says where the acceleration came from. None of the estimates has been timed against a real machine yet.
