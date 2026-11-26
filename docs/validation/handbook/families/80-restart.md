---
family: restart
title: Restarts, air cuts and groups
---
# Restarts, air cuts and groups

A restart file is the rest of a job from a toolpath, a pass or a line, for after a broken bit, a power cut or an E-stop (**File ▸ Export Restart…**, or `post --restart-toolpath`, `--restart-pass` and `--restart-line`). It snaps back to the start of the pass, stops over the restart point with the spindle off for you to check, then feeds down. Toolpath groups export part of a job as its own file.

The machine questions here (does Z rise before XY, does G54 survive a power cut, how far does the highlighted line lead) are ones only your controller can answer.
