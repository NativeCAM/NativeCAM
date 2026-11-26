# The command line's `--controller` (#207)

Inputs for `ControllerOptionTests` and `ControllerOptionCommandLineTests`. `--controller mach4` is Avid's Mach4 profile: it keeps the machine's model and writes what leaving `--controller` out writes; any other name sets the model to Custom.

- `grbl-machine.nativecam`: an empty project on a Custom 30 × 30 × 4 in machine running Grbl via gSender, in millimetres. `acceptance` on it writes the Grbl program; with `--controller mach4` it writes the Avid Mach4 one.
- `pro4896-machine.nativecam`: an empty project on an Avid PRO4896 on Mach4 (no controller in the file). With `--controller mach4` its acceptance program still says `Machine: PRO4896`.

Both are written by `ControllerOptionTests.projectFixtures` when `NATIVECAM_UPDATE_GOLDENS=1`.
