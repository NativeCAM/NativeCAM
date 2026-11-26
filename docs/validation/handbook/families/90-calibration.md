---
family: calibration
title: Calibration programs
---
# Calibration programs

NativeCAM's run-time estimates and some of its feed choices rest on numbers the machine's maker doesn't publish: accelerations, corner tolerance, Z rapid rate, how the controller handles a change of feed, the rotary's turn speed. The calibration programs measure them. Make them with **File ▸ Calibration Programs…** or `nativecam-cli calibrate`, for your own machine (pass your project).

> **Warning.** Enter only times you measured with a stopwatch on your machine. A fitted value is marked *measured* in the machine settings: a guessed time makes a wrong value look trustworthy. Never fill in a times file "to try it".
