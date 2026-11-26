---
title: Sign-off
---
# Sign-off

## Your setup

| Item | Value |
|---|---|
| Machine (maker, model, size) | |
| Controller and version | |
| Program that sends files (if any) | |
| Spindle or router, and its speed range | |
| G-code units the controller runs in | |
| How tools change (M6 macro, pause, tool changer, one file per tool) | |
| Touch plate or other Z zero method | |
| Rotary axis (model, along X or Y, chuck end) | |
| NativeCAM build (commit or version) | |
| Date(s) tested | |

## What your machine told you

| Question | Answer |
|---|---|
| Gantry square (diagonals over 12 in differ by) | |
| Tram (from VH-SRF-01) | |
| Steps per unit corrected? | |
| +A turns the top of the blank toward | |
| `G93 G01 A360 F10` took (s) | |
| Rotary centre height above the spoilboard | |
| Rotary turn speed (fitted or from the controller) | |
| M6 macro raises Z before moving? | |
| M6 macro in rotary mode zeroes Z on the axis or the face? | |
| M6 macro copes with the tool already loaded? | |
| Controller keeps blending through an F change? | |
| G54 survives a power cut? A position? | |
| Highlighted line runs ahead of the tool by (lines) | |
| Machine homes at (corner) | |

## Summary

| | Count |
|---|---|
| Tests passed | |
| Tests failed (each reported) | |
| Tests not run | |

I ran these tests on the machine described above, and the results recorded in this handbook are what I measured.

| Name | Signature | Date |
|---|---|---|
| | | |
