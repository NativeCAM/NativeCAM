# Spoilboard surfacing's air-cut file names (#200)

Inputs for `SurfacingAirCutNamingTests`. Since #199 every air cut is named `<file> (air cut).<ext>`; this checks spoilboard surfacing's air cut is too (`Surfacing.paths`, through `AirCut.paths`), from the command line (`surface`) and the engine the app's **File ▸ Surface Spoilboard…** sheet saves through, and that `AirCut.namingProblem` refuses the names it refuses for every other air cut.

- `names.txt`: the program's and the air cut's file names for each way of naming them, one per line as `case: program | air cut`. `-o` cases are the command line's `-o` (the sheet's save panel names the file the same way); `default` is the name with no `-o`, on the default PRO6060 bed.
- `real-cut.tap`: a short full-depth program with no AIR CUT line, standing in for a real cut already on disk. An air cut must never be written over it.
