# Machine travel and collet reach (#151)

The demo sign (format 1) on the default Avid PRO6060, changed one way each:

- `over-x.nativecam`: the sign outline moved to X 1700 mm, so the program spans 78.05 in of X against 61.375 in of travel. An export-check error; `post` refuses it without `--force`.
- `over-z.nativecam`: the machine's Z travel cut to 60 mm, less than the program's Z span plus the 1.5 in stickout. An export-check error.
- `collet-past-stickout.nativecam`: the cut-out profile 80 mm deep, past the 1/4" end mill's 1.5 in stickout. A job-check error (the collet nut would hit the stock).
- `just-inside-travel.nativecam`: the sign outline moved to X 1274 mm, so the program spans about 2.4 mm less than the X travel. No errors; `post` writes it.
