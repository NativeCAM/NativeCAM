# Air-cut file names (#192)

Inputs for `AirCutNamingTests`. The projects are `projects/toolpath-groups-v1.nativecam` (the grouped sign) and `restart/sign.nativecam`.

- `names.txt`: the file each path writes, one per line as `path: name`, for the grouped sign saved as "Grouped sign.nativecam". Every air cut carries " (air cut)"; no real cut does.
- `real-cut.tap`: a short full-depth program with no AIR CUT line, standing in for a real cut already on disk. An air cut must never be written over it.
