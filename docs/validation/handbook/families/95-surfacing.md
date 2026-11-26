---
family: surfacing
title: Spoilboard surfacing
---
# Spoilboard surfacing

**File ▸ Surface Spoilboard…** and `nativecam-cli surface` write a surfacing program for the whole bed or a board, with an air-cut copy. NativeCAM checks the program's size against the machine's travel, but it doesn't know where your machine homes or where its soft limits sit: the first air cut is how you find out.

> **Warning.** Before any surfacing run: every clamp off the bed, every screw head at least 1/8 in (3 mm) below the cut, Z zeroed on the **spoilboard's top** with the touch plate on the board, and the air cut first.
