// The built-in machine catalogue (see MachineCatalogue). Every value carries its source.
enum MachineCatalogueData {
    static let json = #"""
    {"schemaVersion": 1, "entries": [
      {
       "id": "avid-pro4848",
       "vendor": "Avid CNC",
       "family": "PRO",
       "model": "4848",
       "travel": [1257.3, 1257.3, 203.2],
       "controllers": [
         {"family": "mach4", "label": "Mach4 with ESS", "isDefault": true},
         {"family": "centroid", "label": "Avid EX (CNC12)"}
       ],
       "spindle": "vfdSpindle",
       "minRPM": 6000,
       "maxRPM": 24000,
       "rapidXY": 20320,
       "maxFeed": 10160,
       "accelerationXY": 1270,
       "units": "inch",
       "toolChange": "manualM6",
       "dustCollection": true,
       "sources": {
         "travel": {"kind": "vendor", "note": "Work area 49-1/2 × 49-1/2 × 8 in (12 in Z optional)", "url": "https://www.avidcnc.com/pro4848-4-x-4-cnc-router-machine-p-1335.html"},
         "minRPM": {"kind": "estimated", "note": "NativeCAM's default; Avid publishes no spindle speed range"},
         "maxRPM": {"kind": "estimated", "note": "NativeCAM's default for Avid's VFD spindles; Avid publishes no range, and a published Avid Mach4 profile (Machine.ini) caps the spindle at 18,000 RPM, so check your VFD", "url": "https://github.com/corbinstreehouse/Mach-4-Avid-CNC-Customizations/blob/HEAD/Profiles/AvidCNC/Machine.ini"},
         "rapidXY": {"kind": "vendor", "note": "800 IPM rapid with NEMA 34 steppers (500 IPM NEMA 23, 1,200 IPM ClearPath servo); NativeCAM's PRO presets assume NEMA 34", "url": "https://www.avidcnc.com/pro4848-4-x-4-cnc-router-machine-p-1335.html"},
         "maxFeed": {"kind": "vendor", "note": "400 IPM cut speed with NEMA 34 steppers (250 NEMA 23, 600 ClearPath)", "url": "https://www.avidcnc.com/pro4848-4-x-4-cnc-router-machine-p-1335.html"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: Avid-on-Mach4 class default, 50 in/s², the X/Y value owners report Avid's Mach4 profile ships with; Avid publishes none", "url": "https://forum.avidcnc.com/t/mach4-motor-accel-a-macro-and-post-combo/2505"},
         "controllers": {"kind": "vendor", "note": "Mach4 with an Ethernet SmoothStepper on machines sold before about December 2024; Avid's EX controller on Centroid CNC12 has been standard on new kits since then and is sold as an upgrade", "url": "https://www.mfgnewsweb.com/archives/4/67461/Controls-dec24/ad_info.aspx"}
       },
       "notes": "Drive tiers (cut / rapid): NEMA 23 250 / 500 IPM, NEMA 34 400 / 800, ClearPath servo 600 / 1,200; the values here are NEMA 34. New Avid kits ship with the EX controller (Centroid CNC12); Mach4 is the default here because NativeCAM's Avid post writes for it. Z acceleration and Z rapid aren't published, so NativeCAM's placeholders apply. A Smart Spindle and ATC are options.",
       "verified": false
      },
      {
       "id": "avid-pro4896",
       "vendor": "Avid CNC",
       "family": "PRO",
       "model": "4896",
       "travel": [1257.3, 2508.25, 203.2],
       "controllers": [
         {"family": "mach4", "label": "Mach4 with ESS", "isDefault": true},
         {"family": "centroid", "label": "Avid EX (CNC12)"}
       ],
       "spindle": "vfdSpindle",
       "minRPM": 6000,
       "maxRPM": 24000,
       "rapidXY": 20320,
       "maxFeed": 10160,
       "accelerationXY": 1270,
       "units": "inch",
       "toolChange": "manualM6",
       "dustCollection": true,
       "sources": {
         "travel": {"kind": "vendor", "note": "Work area 49-1/2 × 98-3/4 × 8 in (Avid also gives 1260 × 2508 × 203 mm; 12 in Z optional)", "url": "https://www.avidcnc.com/pro4896-4-x-8-cnc-router-machine-p-1337.html"},
         "minRPM": {"kind": "estimated", "note": "NativeCAM's default; Avid publishes no spindle speed range"},
         "maxRPM": {"kind": "estimated", "note": "NativeCAM's default for Avid's VFD spindles; Avid publishes no range, and a published Avid Mach4 profile (Machine.ini) caps the spindle at 18,000 RPM, so check your VFD", "url": "https://github.com/corbinstreehouse/Mach-4-Avid-CNC-Customizations/blob/HEAD/Profiles/AvidCNC/Machine.ini"},
         "rapidXY": {"kind": "vendor", "note": "800 IPM rapid with NEMA 34 steppers (500 IPM NEMA 23, 1,200 IPM ClearPath servo); NativeCAM's PRO presets assume NEMA 34", "url": "https://www.avidcnc.com/pro4896-4-x-8-cnc-router-machine-p-1337.html"},
         "maxFeed": {"kind": "vendor", "note": "400 IPM cut speed with NEMA 34 steppers (250 NEMA 23, 600 ClearPath)", "url": "https://www.avidcnc.com/pro4896-4-x-8-cnc-router-machine-p-1337.html"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: Avid-on-Mach4 class default, 50 in/s², the X/Y value owners report Avid's Mach4 profile ships with; Avid publishes none", "url": "https://forum.avidcnc.com/t/mach4-motor-accel-a-macro-and-post-combo/2505"},
         "controllers": {"kind": "vendor", "note": "Mach4 with an Ethernet SmoothStepper on machines sold before about December 2024; Avid's EX controller on Centroid CNC12 has been standard on new kits since then and is sold as an upgrade", "url": "https://www.mfgnewsweb.com/archives/4/67461/Controls-dec24/ad_info.aspx"}
       },
       "notes": "Drive tiers (cut / rapid): NEMA 23 250 / 500 IPM, NEMA 34 400 / 800, ClearPath servo 600 / 1,200; the values here are NEMA 34. New Avid kits ship with the EX controller (Centroid CNC12); Mach4 is the default here because NativeCAM's Avid post writes for it. Z acceleration and Z rapid aren't published, so NativeCAM's placeholders apply. A Smart Spindle and ATC are options.",
       "verified": false
      },
      {
       "id": "avid-pro6060",
       "vendor": "Avid CNC",
       "family": "PRO",
       "model": "6060",
       "travel": [1558.925, 1558.925, 203.2],
       "controllers": [
         {"family": "mach4", "label": "Mach4 with ESS", "isDefault": true},
         {"family": "centroid", "label": "Avid EX (CNC12)"}
       ],
       "spindle": "vfdSpindle",
       "minRPM": 6000,
       "maxRPM": 24000,
       "rapidXY": 20320,
       "maxFeed": 10160,
       "accelerationXY": 1270,
       "units": "inch",
       "toolChange": "manualM6",
       "dustCollection": true,
       "sources": {
         "travel": {"kind": "vendor", "note": "Work area 61-3/8 × 61-3/8 × 8 in (12 in Z optional)", "url": "https://www.avidcnc.com/pro6060-5-x-5-cnc-router-kit-p-634.html"},
         "minRPM": {"kind": "estimated", "note": "NativeCAM's default; Avid publishes no spindle speed range"},
         "maxRPM": {"kind": "estimated", "note": "NativeCAM's default for Avid's VFD spindles; Avid publishes no range, and a published Avid Mach4 profile (Machine.ini) caps the spindle at 18,000 RPM, so check your VFD", "url": "https://github.com/corbinstreehouse/Mach-4-Avid-CNC-Customizations/blob/HEAD/Profiles/AvidCNC/Machine.ini"},
         "rapidXY": {"kind": "vendor", "note": "800 IPM rapid with NEMA 34 steppers (500 IPM NEMA 23, 1,200 IPM ClearPath servo); NativeCAM's PRO presets assume NEMA 34", "url": "https://www.avidcnc.com/pro6060-5-x-5-cnc-router-kit-p-634.html"},
         "maxFeed": {"kind": "vendor", "note": "400 IPM cut speed with NEMA 34 steppers (250 NEMA 23, 600 ClearPath)", "url": "https://www.avidcnc.com/pro6060-5-x-5-cnc-router-kit-p-634.html"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: Avid-on-Mach4 class default, 50 in/s², the X/Y value owners report Avid's Mach4 profile ships with; Avid publishes none", "url": "https://forum.avidcnc.com/t/mach4-motor-accel-a-macro-and-post-combo/2505"},
         "controllers": {"kind": "vendor", "note": "Mach4 with an Ethernet SmoothStepper on machines sold before about December 2024; Avid's EX controller on Centroid CNC12 has been standard on new kits since then and is sold as an upgrade", "url": "https://www.mfgnewsweb.com/archives/4/67461/Controls-dec24/ad_info.aspx"}
       },
       "notes": "NativeCAM's reference machine (rack-and-pinion X/Y, ballscrew Z). Drive tiers (cut / rapid): NEMA 23 250 / 500 IPM, NEMA 34 400 / 800, ClearPath servo 600 / 1,200; the values here are NEMA 34. New Avid kits ship with the EX controller (Centroid CNC12); Mach4 is the default here because NativeCAM's Avid post writes for it. Z acceleration and Z rapid aren't published, so NativeCAM's placeholders apply. A Smart Spindle and ATC are options.",
       "verified": true
      },
      {
       "id": "avid-benchtop-pro-2436",
       "vendor": "Avid CNC",
       "family": "Benchtop PRO",
       "model": "2436",
       "travel": [660.4, 961.136, 152.4],
       "controllers": [
         {"family": "centroid", "label": "Avid EX (CNC12)", "isDefault": true},
         {"family": "mach4", "label": "Mach4 with ESS"}
       ],
       "spindle": "vfdSpindle",
       "rapidXY": 10160,
       "maxFeed": 6350,
       "accelerationXY": 500,
       "accelerationZ": 500,
       "units": "inch",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Work area 26 × 37.84 × 6 in; Z is 9 in with the other crossmember position", "url": "https://www.avidcnc.com/benchtop-pro-2436-2-x-3-cnc-machine-p-1333.html"},
         "rapidXY": {"kind": "vendor", "note": "400 IPM rapid with NEMA 34 steppers (300 IPM NEMA 23, 500 IPM ClearPath servo)", "url": "https://www.avidcnc.com/benchtop-pro-2436-2-x-3-cnc-machine-p-1333.html"},
         "maxFeed": {"kind": "vendor", "note": "250 IPM cut speed with NEMA 34 steppers (200 NEMA 23, 350 ClearPath)", "url": "https://www.avidcnc.com/benchtop-pro-2436-2-x-3-cnc-machine-p-1333.html"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: 500 mm/s² X/Y for Centroid CNC12 (Avid EX) machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: 500 mm/s² Z for Centroid CNC12 (Avid EX) machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "controllers": {"kind": "vendor", "note": "The product page lists the Avid EX control system with CNC12 control software", "url": "https://www.avidcnc.com/benchtop-pro-2436-2-x-3-cnc-machine-p-1333.html"}
       },
       "notes": "Avid's page lists only the EX control system with CNC12 for this machine; older benchtops may run Mach4 with an ESS. Spindle options are Hiteco and Smart Spindles with a VFD, or a router mount (set the spindle to router if you use one). Avid publishes no RPM range. The 50 in/s² Mach4 figure owners report is for PRO machines, so acceleration here is the Centroid class estimate. A Benchtop PRO 2424 exists, but its specifications weren't available.",
       "verified": false
      },
      {
       "id": "carbide3d-shapeoko-4-standard",
       "vendor": "Carbide 3D",
       "family": "Shapeoko 4",
       "model": "Standard",
       "travel": [444.5, 444.5, 101.6],
       "controllers": [
         {"family": "carbideMotion", "label": "Carbide Motion", "isDefault": true},
         {"family": "grbl", "sender": "gSender"}
       ],
       "spindle": "router",
       "rapidXY": 10000,
       "rapidZ": 1000,
       "accelerationXY": 500,
       "accelerationZ": 270,
       "junctionDeviation": 0.02,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cuttable area 17.5 × 17.5 × 4 in, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-4"},
         "rapidXY": {"kind": "estimated", "note": "Estimated: taken from an owner's $$ on a 2025 Shapeoko 4 XXL ($110/$111 = 10000 mm/min); assumed the same on every belt Shapeoko 4 size, which Carbide hasn't confirmed", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "rapidZ": {"kind": "estimated", "note": "Estimated: taken from an owner's $$ on a 2025 Shapeoko 4 XXL ($112 = 1000 mm/min); assumed the same on every belt Shapeoko 4 size, which Carbide hasn't confirmed", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: taken from an owner's $$ on a 2025 Shapeoko 4 XXL ($120/$121 = 500 mm/s², also the belt / V-wheel class default); assumed the same on every belt Shapeoko 4 size, which Carbide hasn't confirmed", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: taken from an owner's $$ on a 2025 Shapeoko 4 XXL ($122 = 270 mm/s²); assumed the same on every belt Shapeoko 4 size, which Carbide hasn't confirmed", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: taken from an owner's $$ on a 2025 Shapeoko 4 XXL ($11 = 0.02 mm); assumed the same on every belt Shapeoko 4 size, which Carbide hasn't confirmed", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "controllers": {"kind": "vendor", "note": "GRBL 1.1 on Carbide's controller, run from Carbide Motion (which handles M6); gSender also ships Shapeoko and Nomad profiles", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-4"}
       },
       "notes": "Belt-driven X/Y on V-wheels. Takes a 65 mm trim router (Carbide Compact Router or Makita RT0701C) or Carbide's VFD spindle; set the spindle to VFD if you fitted one. BitSetter and BitZero are options.",
       "verified": false
      },
      {
       "id": "carbide3d-shapeoko-4-xl",
       "vendor": "Carbide 3D",
       "family": "Shapeoko 4",
       "model": "XL",
       "travel": [838.2, 444.5, 101.6],
       "controllers": [
         {"family": "carbideMotion", "label": "Carbide Motion", "isDefault": true},
         {"family": "grbl", "sender": "gSender"}
       ],
       "spindle": "router",
       "rapidXY": 10000,
       "rapidZ": 1000,
       "accelerationXY": 500,
       "accelerationZ": 270,
       "junctionDeviation": 0.02,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cuttable area 33 × 17.5 × 4 in, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-4"},
         "rapidXY": {"kind": "estimated", "note": "Estimated: taken from an owner's $$ on a 2025 Shapeoko 4 XXL ($110/$111 = 10000 mm/min); assumed the same on every belt Shapeoko 4 size, which Carbide hasn't confirmed", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "rapidZ": {"kind": "estimated", "note": "Estimated: taken from an owner's $$ on a 2025 Shapeoko 4 XXL ($112 = 1000 mm/min); assumed the same on every belt Shapeoko 4 size, which Carbide hasn't confirmed", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: taken from an owner's $$ on a 2025 Shapeoko 4 XXL ($120/$121 = 500 mm/s², also the belt / V-wheel class default); assumed the same on every belt Shapeoko 4 size, which Carbide hasn't confirmed", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: taken from an owner's $$ on a 2025 Shapeoko 4 XXL ($122 = 270 mm/s²); assumed the same on every belt Shapeoko 4 size, which Carbide hasn't confirmed", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: taken from an owner's $$ on a 2025 Shapeoko 4 XXL ($11 = 0.02 mm); assumed the same on every belt Shapeoko 4 size, which Carbide hasn't confirmed", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "controllers": {"kind": "vendor", "note": "GRBL 1.1 on Carbide's controller, run from Carbide Motion (which handles M6); gSender also ships Shapeoko and Nomad profiles", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-4"}
       },
       "notes": "Belt-driven X/Y on V-wheels. Takes a 65 mm trim router (Carbide Compact Router or Makita RT0701C) or Carbide's VFD spindle; set the spindle to VFD if you fitted one. BitSetter and BitZero are options.",
       "verified": false
      },
      {
       "id": "carbide3d-shapeoko-4-xxl",
       "vendor": "Carbide 3D",
       "family": "Shapeoko 4",
       "model": "XXL",
       "travel": [838.2, 838.2, 101.6],
       "controllers": [
         {"family": "carbideMotion", "label": "Carbide Motion", "isDefault": true},
         {"family": "grbl", "sender": "gSender"}
       ],
       "spindle": "router",
       "rapidXY": 10000,
       "rapidZ": 1000,
       "accelerationXY": 500,
       "accelerationZ": 270,
       "junctionDeviation": 0.02,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cuttable area 33 × 33 × 4 in, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-4"},
         "rapidXY": {"kind": "controllerSettings", "note": "an owner's $$ on a 2025 Shapeoko 4 XXL ($110/$111 = 10000 mm/min); Carbide publishes no table of shipped settings", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "rapidZ": {"kind": "controllerSettings", "note": "an owner's $$ on a 2025 Shapeoko 4 XXL ($112 = 1000 mm/min); Carbide publishes no table of shipped settings", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "accelerationXY": {"kind": "controllerSettings", "note": "an owner's $$ on a 2025 Shapeoko 4 XXL ($120/$121 = 500 mm/s²); Carbide publishes no table of shipped settings", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "accelerationZ": {"kind": "controllerSettings", "note": "an owner's $$ on a 2025 Shapeoko 4 XXL ($122 = 270 mm/s²); Carbide publishes no table of shipped settings", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "junctionDeviation": {"kind": "controllerSettings", "note": "an owner's $$ on a 2025 Shapeoko 4 XXL ($11 = 0.02 mm); Carbide publishes no table of shipped settings", "url": "https://community.carbide3d.com/t/shapoko-4-xxl-initial-setup/96528"},
         "controllers": {"kind": "vendor", "note": "GRBL 1.1 on Carbide's controller, run from Carbide Motion (which handles M6); gSender also ships Shapeoko and Nomad profiles", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-4"}
       },
       "notes": "Belt-driven X/Y on V-wheels. Takes a 65 mm trim router (Carbide Compact Router or Makita RT0701C) or Carbide's VFD spindle; set the spindle to VFD if you fitted one. BitSetter and BitZero are options.",
       "verified": false
      },
      {
       "id": "carbide3d-shapeoko-5-pro-4x4",
       "vendor": "Carbide 3D",
       "family": "Shapeoko 5 Pro",
       "model": "4×4",
       "travel": [1236.98, 1236.98, 154.94],
       "controllers": [
         {"family": "carbideMotion", "label": "Carbide Motion", "isDefault": true},
         {"family": "grbl", "sender": "gSender"}
       ],
       "spindle": "router",
       "rapidXY": 5080,
       "rapidZ": 2540,
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cuttable area 48.7 × 48.7 × 6.1 in, as listed on Easel's partner page (Carbide's own spec page leaves travel blank); Z is 5.51 in with the Sweepy Pro dust boot", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-5-pro"},
         "rapidXY": {"kind": "controllerSettings", "note": "200 IPM X/Y as configured, reported by owners; another owner found $110/$111 capped at 7,000 mm/min (Carbide limits the 5 Pro's feed because of its ballscrew ratio)", "url": "https://community.carbide3d.com/t/maximum-speed-shapeoko-5-pro/91269"},
         "rapidZ": {"kind": "controllerSettings", "note": "100 IPM Z as configured, reported by owners", "url": "https://community.carbide3d.com/t/maximum-speed-shapeoko-5-pro/91269"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (500 mm/s² X/Y); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (300 mm/s² Z); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (0.01 mm junction deviation); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "Carbide's spec page lists Carbide Motion control software; Easel's page describes it as GRBL", "url": "https://carbide3d.com/shapeoko/shapeoko5pro-specs/"}
       },
       "notes": "Shapeoko 5 / 5.1 Pro: 16 mm ballscrews and HG-15 rails on every axis; BitSetter included. Customer-supplied 65 mm router or Carbide's VFD spindle. Also sold as 4×2 (48.7 × 24.53 in) and 2×2 (24.53 × 24.53 in).",
       "verified": false
      },
      {
       "id": "carbide3d-shapeoko-hdm",
       "vendor": "Carbide 3D",
       "family": "Shapeoko HDM",
       "model": "",
       "travel": [690, 610, 145],
       "controllers": [
         {"family": "carbideMotion", "label": "Carbide Motion", "isDefault": true},
         {"family": "grbl", "sender": "gSender"}
       ],
       "spindle": "vfdSpindle",
       "minRPM": 8000,
       "maxRPM": 24000,
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "HDM V3 work area 690 × 610 × 145 mm, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-hdm"},
         "minRPM": {"kind": "vendor", "note": "80 mm water-cooled VFD spindle, 8,000–24,000 RPM (1.5 kW 110 V or 2.2 kW 220 V), as listed on Easel's partner page", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-hdm"},
         "maxRPM": {"kind": "vendor", "note": "80 mm water-cooled VFD spindle, 8,000–24,000 RPM, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-hdm"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (500 mm/s² X/Y); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (300 mm/s² Z); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (0.01 mm junction deviation); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "Carbide Motion on a Grbl-based controller", "url": "https://carbide3d.com/hub/docs/shapeoko-hdm-v3/"}
       },
       "notes": "Figures are for the HDM V3 (Carbide Motion 6.49 or later). No rapid rate is published.",
       "verified": false
      },
      {
       "id": "carbide3d-nomad-3",
       "vendor": "Carbide 3D",
       "family": "Nomad 3",
       "model": "",
       "travel": [203.2, 203.2, 76.2],
       "controllers": [
         {"family": "carbideMotion", "label": "Carbide Motion", "isDefault": true},
         {"family": "grbl", "sender": "gSender"}
       ],
       "spindle": "vfdSpindle",
       "maxRPM": 24000,
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cutting area 8 × 8 × 3 in", "url": "https://shop.carbide3d.com/products/nomad-3"},
         "maxRPM": {"kind": "vendor", "note": "24,000 RPM spindle, 130 W (a retailer Q&A says 70 W)", "url": "https://shop.carbide3d.com/products/nomad-3"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: rigid enclosed desktop (the ball-screw desktop values) Grbl class default (500 mm/s² X/Y); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: rigid enclosed desktop (the ball-screw desktop values) Grbl class default (300 mm/s² Z); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: rigid enclosed desktop (the ball-screw desktop values) Grbl class default (0.01 mm junction deviation); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "GRBL 1.1 on Carbide's controller, run from Carbide Motion (which handles M6); gSender also ships Shapeoko and Nomad profiles", "url": "https://easel.com/partners/machines/carbide3d-shapeoko-4"}
       },
       "notes": "Enclosed desktop mill. Its spindle speed follows the S word, so it's set up as a speed-controlled spindle. Carbide Motion runs M6 and probes the tool length sensor. No rapid rate is published.",
       "verified": false
      },
      {
       "id": "inventables-x-carve-2021",
       "vendor": "Inventables",
       "family": "X-Carve",
       "model": "2021",
       "travel": [749.3, 749.3, 114.3],
       "controllers": [
         {"family": "grbl", "sender": "Easel", "label": "X-Controller", "isDefault": true},
         {"family": "grbl", "sender": "gSender"}
       ],
       "spindle": "router",
       "minRPM": 10000,
       "maxRPM": 30000,
       "rapidXY": 8000,
       "rapidZ": 500,
       "accelerationXY": 500,
       "accelerationZ": 50,
       "junctionDeviation": 0.02,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cuttable area 29.5 × 29.5 × 4.5 in for the 2021 upgrade, as listed on Easel (Inventables' own software)", "url": "https://easel.com/partners/machines/inventables-x-carve-nov2021/"},
         "minRPM": {"kind": "vendor", "note": "Makita 1.25 HP (800 W) router, rated 10,000–30,000 RPM", "url": "https://easel.com/partners/machines/inventables-x-carve-nov2021/"},
         "maxRPM": {"kind": "vendor", "note": "Makita 1.25 HP (800 W) router, rated 10,000–30,000 RPM", "url": "https://easel.com/partners/machines/inventables-x-carve-nov2021/"},
         "rapidXY": {"kind": "estimated", "note": "Estimated: upstream Grbl's X-Carve 500 mm and 1000 mm profiles set $110/$111 = 8000 mm/min; Inventables' own X-Controller settings aren't published", "url": "https://github.com/gnea/grbl/blob/master/grbl/defaults.h"},
         "rapidZ": {"kind": "estimated", "note": "Estimated: upstream Grbl's X-Carve profiles set $112 = 500 mm/min", "url": "https://github.com/gnea/grbl/blob/master/grbl/defaults.h"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: upstream Grbl's X-Carve profiles set 500 mm/s² X/Y (also the belt / V-wheel class default)", "url": "https://github.com/gnea/grbl/blob/master/grbl/defaults.h"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: upstream Grbl's X-Carve profiles set 50 mm/s² Z", "url": "https://github.com/gnea/grbl/blob/master/grbl/defaults.h"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: upstream Grbl's X-Carve profiles set $11 = 0.02 mm", "url": "https://github.com/gnea/grbl/blob/master/grbl/defaults.h"},
         "controllers": {"kind": "vendor", "note": "Inventables X-Controller, a GRBL controller, run from Easel; gSender ships X-Carve profiles", "url": "https://easel.com/partners/machines/inventables-x-carve-nov2021/"}
       },
       "notes": "Belt-driven X-Carve, no longer sold: Inventables stopped selling the belt kits around December 2024. Earlier X-Carves came in 500, 750 and 1000 mm rail sizes; upstream Grbl's profiles give 290 × 290 × 100 mm (500 mm) and 740 × 790 × 100 mm (1000 mm) travel.",
       "verified": false
      },
      {
       "id": "inventables-x-carve-pro-4x4",
       "vendor": "Inventables",
       "family": "X-Carve Pro",
       "model": "4×4",
       "travel": [1219.2, 1219.2, 101.6],
       "controllers": [
         {"family": "grbl", "sender": "Easel", "label": "X-Carve Pro controller", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "minRPM": 8000,
       "maxRPM": 24000,
       "maxFeed": 7620,
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cutting area 48 × 48 × 4 in; Z max travel 6.5 in, gantry clearance 5 in", "url": "https://inventables.com/pages/x-carve-tech-specs"},
         "minRPM": {"kind": "vendor", "note": "2 HP (1.5 kW) air-cooled spindle with pre-programmed VFD, 8,000–24,000 RPM, ER16", "url": "https://inventables.com/pages/x-carve-tech-specs"},
         "maxRPM": {"kind": "vendor", "note": "2 HP (1.5 kW) air-cooled spindle with pre-programmed VFD, 8,000–24,000 RPM", "url": "https://inventables.com/pages/x-carve-tech-specs"},
         "maxFeed": {"kind": "vendor", "note": "Max cutting speed 300 in/min, from MatterHackers' listing (a retailer); not on Inventables' page", "url": "https://www.matterhackers.com/store/l/inventables-x-carve-pro-cnc-router"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (500 mm/s² X/Y); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (300 mm/s² Z); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (0.01 mm junction deviation); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "Inventables' custom Grbl 1.1h (1.1h-XCPd.20230214a), run from Easel", "url": "https://easel.com/partners/machines/inventables-x-carve-pro/"}
       },
       "notes": "1 in ball screws on linear guides with NEMA 23 steppers. Also sold as 4×2 (48 × 24 × 4 in). No rapid rate is published.",
       "verified": false
      },
      {
       "id": "sienci-longmill-mk2-30x30",
       "vendor": "Sienci Labs",
       "family": "LongMill MK2",
       "model": "30×30",
       "travel": [820, 872, 114],
       "controllers": [
         {"family": "grblHAL", "sender": "gSender", "label": "SuperLongBoard", "isDefault": true},
         {"family": "grbl", "sender": "gSender", "label": "LongBoard"}
       ],
       "spindle": "router",
       "rapidXY": 4000,
       "rapidZ": 4000,
       "maxFeed": 4000,
       "accelerationXY": 750,
       "accelerationZ": 750,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cutting area 820 × 872 × 114 mm", "url": "https://resources.sienci.com/view/lmk2-mk2-specs/"},
         "rapidXY": {"kind": "controllerSettings", "note": "gSender's LongMill default for the SuperLongBoard (grblHAL) ($110/$111 = 4000 mm/min)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/longmill.js"},
         "rapidZ": {"kind": "controllerSettings", "note": "gSender's LongMill default for the SuperLongBoard (grblHAL) ($112 = 4000 mm/min; the LongBoard's grbl default is 3000)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/longmill.js"},
         "maxFeed": {"kind": "vendor", "note": "Max cutting speed 4000 mm/min X/Y (3000 mm/min Z)", "url": "https://resources.sienci.com/view/lmk2-mk2-specs/"},
         "accelerationXY": {"kind": "controllerSettings", "note": "gSender's LongMill default for the SuperLongBoard (grblHAL) (750 mm/s²)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/longmill.js"},
         "accelerationZ": {"kind": "controllerSettings", "note": "gSender's LongMill default for the SuperLongBoard (grblHAL) (750 mm/s²; the LongBoard's grbl default is 500)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/longmill.js"},
         "junctionDeviation": {"kind": "controllerSettings", "note": "gSender's LongMill default for the SuperLongBoard (grblHAL) ($11 = 0.010 mm)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/longmill.js"},
         "controllers": {"kind": "vendor", "note": "LongBoard (Arduino, grbl 1.1h) or SuperLongBoard (STM32, grblHAL), both run from gSender", "url": "https://resources.sienci.com/view/lmk2-handbook/"}
       },
       "notes": "Superseded by the LongMill MK3 in 2026; large installed base. Also sold as 12×30 and 48×30 (1280 × 872 × 114 mm). Takes an owner-supplied router.",
       "verified": false
      },
      {
       "id": "sienci-longmill-mk3-48x30",
       "vendor": "Sienci Labs",
       "family": "LongMill MK3",
       "model": "48×30",
       "travel": [1244.6, 812.8, 129.54],
       "controllers": [
         {"family": "grblHAL", "sender": "gSender", "label": "SLB-LITE", "isDefault": true}
       ],
       "spindle": "router",
       "rapidXY": 7000,
       "rapidZ": 4000,
       "accelerationXY": 750,
       "accelerationZ": 750,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cutting area 49 × 32 in with 5.1 in Z", "url": "https://sienci.com/2026/05/06/everything-you-need-to-know-about-the-longmill-mk3/"},
         "rapidXY": {"kind": "controllerSettings", "note": "gSender's LongMill MK3 default (grblHAL) ($110/$111 = 7000 mm/min, the same 275 IPM Sienci's MK3 article gives)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/longmill.js"},
         "rapidZ": {"kind": "controllerSettings", "note": "gSender's LongMill MK3 default (grblHAL) ($112 = 4000 mm/min, overriding 3000 in the base file); Sienci's MK3 article says 6000 mm/min", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/longmill.js"},
         "accelerationXY": {"kind": "controllerSettings", "note": "gSender's LongMill MK3 default (grblHAL) (750 mm/s²)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/longmill.js"},
         "accelerationZ": {"kind": "controllerSettings", "note": "gSender's LongMill MK3 default (grblHAL) (750 mm/s²)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/longmill.js"},
         "junctionDeviation": {"kind": "controllerSettings", "note": "gSender's LongMill MK3 default (grblHAL) ($11 = 0.010 mm)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/longmill.js"},
         "controllers": {"kind": "vendor", "note": "SLB-LITE controller running grblHAL, run from gSender", "url": "https://sienci.com/2026/05/06/everything-you-need-to-know-about-the-longmill-mk3/"}
       },
       "notes": "Released 2026. Also sold as 30×30 (32 × 32 × 5.1 in). Sienci recommends its AutoSpin T1 router (800 W).",
       "verified": false
      },
      {
       "id": "sienci-altmill-4x4",
       "vendor": "Sienci Labs",
       "family": "AltMill",
       "model": "4×4",
       "travel": [1260, 1248, 170],
       "controllers": [
         {"family": "grblHAL", "sender": "gSender", "label": "SuperLongBoard EXT", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "rapidXY": 15000,
       "rapidZ": 6000,
       "accelerationXY": 1500,
       "accelerationZ": 1500,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Sienci's own gSender machine defaults ($130 = 1260, $131 = 1248, $132 = 170 mm); Kiri:Moto's AltMill profile has the same bed", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "rapidXY": {"kind": "controllerSettings", "note": "gSender's AltMill default (grblHAL) ($110/$111 = 15000 mm/min)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "rapidZ": {"kind": "controllerSettings", "note": "gSender's AltMill default (grblHAL) ($112 = 6000 mm/min)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "accelerationXY": {"kind": "controllerSettings", "note": "gSender's AltMill default (grblHAL) (1500 mm/s²)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "accelerationZ": {"kind": "controllerSettings", "note": "gSender's AltMill default (grblHAL) (1500 mm/s²)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "junctionDeviation": {"kind": "controllerSettings", "note": "gSender's AltMill default (grblHAL) ($11 = 0.010 mm)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "controllers": {"kind": "vendor", "note": "SLB-Ext 32-bit controller running grblHAL, run from gSender", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"}
       },
       "notes": "Closed-loop steppers. The spindle is a required add-on: 1.5 kW, 2.2 kW or a 2.2 kW ATC spindle (set the tool change to automatic if you have Sienci's tool changer). Sienci warns that default Z acceleration caused false closed-loop alarms on early machines. Also sold as 2×4 (Y 648 mm).",
       "verified": false
      },
      {
       "id": "sienci-altmill-4x8",
       "vendor": "Sienci Labs",
       "family": "AltMill",
       "model": "4×8",
       "travel": [1260, 2661, 220],
       "controllers": [
         {"family": "grblHAL", "sender": "gSender", "label": "SuperLongBoard EXT", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "rapidXY": 15000,
       "rapidZ": 6000,
       "accelerationXY": 1500,
       "accelerationZ": 1500,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Sienci's own gSender machine defaults ($130 = 1260, $131 = 2661, $132 = 220 mm); see also Sienci's AltMill 4×8 specifications", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "rapidXY": {"kind": "controllerSettings", "note": "gSender's AltMill default (grblHAL): X 15,000 and Y 25,000 mm/min ($110/$111). One X/Y rapid is stored, so this is the slower X; Sienci's spec page lists X 16,000 and Y 25,000", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "rapidZ": {"kind": "controllerSettings", "note": "gSender's AltMill default (grblHAL) ($112 = 6000 mm/min)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "accelerationXY": {"kind": "controllerSettings", "note": "gSender's AltMill default (grblHAL) (1500 mm/s²)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "accelerationZ": {"kind": "controllerSettings", "note": "gSender's AltMill default (grblHAL) (1500 mm/s²)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "junctionDeviation": {"kind": "controllerSettings", "note": "gSender's AltMill default (grblHAL) ($11 = 0.010 mm)", "url": "https://github.com/Sienci-Labs/gsender/blob/master/src/app/src/features/Config/assets/MachineDefaults/grblHAL/Altmill.js"},
         "controllers": {"kind": "vendor", "note": "SLB-Ext 32-bit controller running grblHAL, run from gSender", "url": "https://resources.sienci.com/view/am4x8-specifications/"}
       },
       "notes": "Closed-loop steppers. The spindle is a required add-on: 1.5 kW, 2.2 kW or a 2.2 kW ATC spindle (set the tool change to automatic if you have Sienci's tool changer). Sienci warns that default Z acceleration caused false closed-loop alarms on early machines.",
       "verified": false
      },
      {
       "id": "bobscnc-evolution-4",
       "vendor": "BobsCNC",
       "family": "Evolution",
       "model": "4",
       "travel": [609.6, 609.6, 83.82],
       "controllers": [
         {"family": "grbl", "label": "GRBL 1.1 (Arduino)", "isDefault": true},
         {"family": "grbl", "sender": "gSender"},
         {"family": "grbl", "sender": "Easel"}
       ],
       "spindle": "router",
       "rapidXY": 10000,
       "rapidZ": 500,
       "maxFeed": 5080,
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cutting area 24 × 24 × 3.3 in (upstream Grbl's E4 profile uses 610 × 610 × 85 mm)", "url": "https://cdn.shopify.com/s/files/1/1563/9873/files/E4_Manual_1.11.pdf"},
         "rapidXY": {"kind": "controllerSettings", "note": "upstream Grbl 1.1's BobsCNC E4 profile ($110/$111 = 10000 mm/min); whether BobsCNC flashes exactly these values isn't confirmed", "url": "https://github.com/gnea/grbl/blob/master/grbl/defaults.h"},
         "rapidZ": {"kind": "controllerSettings", "note": "upstream Grbl 1.1's BobsCNC E4 profile ($112 = 500 mm/min); whether BobsCNC flashes exactly these values isn't confirmed", "url": "https://github.com/gnea/grbl/blob/master/grbl/defaults.h"},
         "maxFeed": {"kind": "vendor", "note": "200 IPM (5080 mm/min) max feed in All3DP's spec summary", "url": "https://all3dp.com/1/bobscnc-evolution-4-cnc-router-kit-review-the-specs/"},
         "accelerationXY": {"kind": "controllerSettings", "note": "upstream Grbl 1.1's BobsCNC E4 profile (500 mm/s² X/Y); whether BobsCNC flashes exactly these values isn't confirmed", "url": "https://github.com/gnea/grbl/blob/master/grbl/defaults.h"},
         "accelerationZ": {"kind": "controllerSettings", "note": "upstream Grbl 1.1's BobsCNC E4 profile (300 mm/s² Z); whether BobsCNC flashes exactly these values isn't confirmed", "url": "https://github.com/gnea/grbl/blob/master/grbl/defaults.h"},
         "junctionDeviation": {"kind": "controllerSettings", "note": "upstream Grbl 1.1's BobsCNC E4 profile ($11 = 0.01 mm); whether BobsCNC flashes exactly these values isn't confirmed", "url": "https://github.com/gnea/grbl/blob/master/grbl/defaults.h"},
         "controllers": {"kind": "vendor", "note": "GRBL 1.1 on an Arduino; Easel and gSender both have BobsCNC profiles", "url": "https://cdn.shopify.com/s/files/1/1563/9873/files/E4_Manual_1.11.pdf"}
       },
       "notes": "Takes an owner-supplied router. The Evolution 3 is smaller (upstream Grbl's profile: 450 × 390 × 85 mm).",
       "verified": false
      },
      {
       "id": "bobscnc-kl744",
       "vendor": "BobsCNC",
       "family": "KL744",
       "model": "",
       "travel": [1219.2, 1219.2, 127],
       "controllers": [
         {"family": "grbl", "label": "GRBL 1.1 (Arduino)", "isDefault": true},
         {"family": "grbl", "sender": "gSender"},
         {"family": "grbl", "sender": "Easel"}
       ],
       "spindle": "router",
       "minRPM": 16000,
       "maxRPM": 27000,
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "48 × 48 in; Easel's partner page lists 1219 × 1219 × 127 mm", "url": "https://easel.com/partners/machines/bobscnc-kl744"},
         "minRPM": {"kind": "vendor", "note": "Router speed range 16,000–27,000 RPM as listed (10,000–30,000 for some routers)", "url": "https://cdn.shopify.com/s/files/1/1563/9873/files/Manual_1_744_Getting_Started_2.5.pdf"},
         "maxRPM": {"kind": "vendor", "note": "Router speed range 16,000–27,000 RPM as listed (10,000–30,000 for some routers)", "url": "https://cdn.shopify.com/s/files/1/1563/9873/files/Manual_1_744_Getting_Started_2.5.pdf"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: BobsCNC (upstream Grbl's E-series values; the research groups BobsCNC with the ball-screw desktops) Grbl class default (500 mm/s² X/Y); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: BobsCNC (upstream Grbl's E-series values; the research groups BobsCNC with the ball-screw desktops) Grbl class default (300 mm/s² Z); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: BobsCNC (upstream Grbl's E-series values; the research groups BobsCNC with the ball-screw desktops) Grbl class default (0.01 mm junction deviation); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "GRBL 1.1 on an Arduino Uno; Easel and gSender both have BobsCNC profiles", "url": "https://easel.com/partners/machines/bobscnc-kl744"}
       },
       "notes": "4×4 kit. No feed or rapid rate is published.",
       "verified": false
      },
      {
       "id": "sainsmart-genmitsu-3018-prover-v2",
       "vendor": "SainSmart",
       "family": "Genmitsu",
       "model": "3018-PROVer V2",
       "travel": [290, 180, 40],
       "controllers": [
         {"family": "grbl", "label": "GRBL 1.1", "isDefault": true},
         {"family": "grbl", "sender": "gSender"},
         {"family": "grbl", "sender": "Easel"}
       ],
       "spindle": "vfdSpindle",
       "maxRPM": 10000,
       "rapidXY": 1000,
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "290 × 180 × 40 mm per SainSmart (retailers list 284 × 180 × 40 mm)", "url": "https://www.sainsmart.com/collections/genmitsu-cnc-router/products/sainsmart-genmitsu-cnc-router-3018-prover-kit"},
         "maxRPM": {"kind": "vendor", "note": "775 DC spindle motor, 10,000 RPM", "url": "https://www.sainsmart.com/collections/genmitsu-cnc-router/products/sainsmart-genmitsu-cnc-router-3018-prover-kit"},
         "rapidXY": {"kind": "controllerSettings", "note": "Community $$ dumps give about 1,000–1,100 mm/min ($110/$111); SainSmart publishes no rate", "url": "https://softsolder.com/2019/08/22/cnc-3018-pro-grbl-configuration/"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: lead-screw desktop (the ball-screw desktop values; community $$ dumps give 30, 50 or 3,000 mm/s², so none was used) Grbl class default (500 mm/s² X/Y); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: lead-screw desktop (the ball-screw desktop values; community $$ dumps give 30, 50 or 3,000 mm/s², so none was used) Grbl class default (300 mm/s² Z); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: lead-screw desktop (the ball-screw desktop values; community $$ dumps give 30, 50 or 3,000 mm/s², so none was used) Grbl class default (0.01 mm junction deviation); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "GRBL 1.1; gSender ships SainSmart profiles and Easel supports Genmitsu machines", "url": "https://www.sainsmart.com/collections/genmitsu-cnc-router/products/sainsmart-genmitsu-cnc-router-3018-prover-kit"}
       },
       "notes": "Entry-level machine. Its 775 motor's speed follows the S word (PWM), so it's set up as a speed-controlled spindle.",
       "verified": false
      },
      {
       "id": "sainsmart-genmitsu-proverxl-4030-v2",
       "vendor": "SainSmart",
       "family": "Genmitsu",
       "model": "PROVerXL 4030 V2",
       "travel": [400, 300, 110],
       "controllers": [
         {"family": "grbl", "label": "GRBL 1.1h", "isDefault": true},
         {"family": "grbl", "sender": "gSender"},
         {"family": "grbl", "sender": "Easel"}
       ],
       "spindle": "vfdSpindle",
       "maxRPM": 10000,
       "rapidXY": 5000,
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Working area 400 × 300 × 110 mm, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/sainsmart-proverxl-4030-v2"},
         "maxRPM": {"kind": "vendor", "note": "400 W spindle, 10,000 RPM, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/sainsmart-proverxl-4030-v2"},
         "rapidXY": {"kind": "vendor", "note": "5,000 mm/min rated; one owner runs 6,000 and reports the steppers locking at 7,000", "url": "https://shop.sainsmart.com/blogs/news/first-impression-on-proverxl-4030-v2-cnc-router"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (500 mm/s² X/Y); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (300 mm/s² Z); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: ball-screw desktop Grbl class default (0.01 mm junction deviation); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "GRBL 1.1h; gSender ships SainSmart profiles and Easel supports it", "url": "https://easel.com/partners/machines/sainsmart-proverxl-4030-v2"}
       },
       "notes": "Also sold as 6050 and 4030S. Its spindle speed follows the S word (PWM).",
       "verified": false
      },
      {
       "id": "foxalien-4040-xe",
       "vendor": "FoxAlien",
       "family": "4040-XE",
       "model": "",
       "travel": [400, 400, 55],
       "controllers": [
         {"family": "grbl", "label": "GRBL", "isDefault": true},
         {"family": "grbl", "sender": "Easel"}
       ],
       "spindle": "vfdSpindle",
       "maxRPM": 10000,
       "rapidXY": 2000,
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "400 × 400 × 55 mm per a FoxAlien bundle listing; Easel lists the Masuter 4040 at 400 × 380 × 55 mm and the Masuter Pro is 400 × 400 × 60 mm", "url": "https://spetools.com/products/foxalien-cnc-router-4040-xe-with-40w-laser-and-r57-rotary-roller-kit"},
         "maxRPM": {"kind": "vendor", "note": "300 W spindle, 0–10,000 RPM, per a FoxAlien bundle listing", "url": "https://spetools.com/products/foxalien-cnc-router-4040-xe-with-40w-laser-and-r57-rotary-roller-kit"},
         "rapidXY": {"kind": "vendor", "note": "'Maximum moving speed' 2,000 mm/min, per a FoxAlien bundle listing", "url": "https://spetools.com/products/foxalien-cnc-router-4040-xe-with-40w-laser-and-r57-rotary-roller-kit"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: lead-screw desktop (the ball-screw desktop values) Grbl class default (500 mm/s² X/Y); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: lead-screw desktop (the ball-screw desktop values) Grbl class default (300 mm/s² Z); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: lead-screw desktop (the ball-screw desktop values) Grbl class default (0.01 mm junction deviation); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "GRBL; FoxAlien machines are Easel partners", "url": "https://spetools.com/products/foxalien-cnc-router-4040-xe-with-40w-laser-and-r57-rotary-roller-kit"}
       },
       "notes": "Budget machine. Its spindle speed follows the S word (PWM).",
       "verified": false
      },
      {
       "id": "twotrees-ttc450-pro",
       "vendor": "TwoTrees",
       "family": "TTC450",
       "model": "Pro",
       "travel": [460, 460, 80],
       "controllers": [
         {"family": "grbl", "label": "Grbl_ESP32 (MKS DLC32)", "isDefault": true},
         {"family": "grbl", "sender": "Easel"}
       ],
       "spindle": "vfdSpindle",
       "maxFeed": 800,
       "accelerationXY": 1000,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Working area 460 × 460 × 80 mm, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/twotrees-ttc450-pro"},
         "maxFeed": {"kind": "vendor", "note": "'Maximum engraving speed' 800 mm/min as TwoTrees lists it, quoted in a review", "url": "https://3dwithus.com/twotrees-ttc450-pro-review-cnc-router-testing"},
         "accelerationXY": {"kind": "vendor", "note": "'Maximum acceleration' 1,000 mm/s² as TwoTrees lists it, quoted in a review; probably the firmware's cap rather than a tuned value", "url": "https://3dwithus.com/twotrees-ttc450-pro-review-cnc-router-testing"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: lead-screw desktop Grbl class default (300 mm/s² Z); TwoTrees publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: lead-screw desktop Grbl class default (0.01 mm); TwoTrees publishes none"},
         "controllers": {"kind": "vendor", "note": "Grbl_ESP32 on an MKS DLC32 V2.1 board (sources differ on the variant)", "url": "https://3dwithus.com/twotrees-ttc450-pro-review-cnc-router-testing"}
       },
       "notes": "Budget machine with a 775 brushed motor; listings disagree on its speed (74 W 8,000 RPM vs 8,000–30,000 RPM), so no RPM range is given. Grbl_ESP32, FluidNC's predecessor, follows Grbl 1.1's G-code, so it's set up as Grbl. Also sold as the TTC6050.",
       "verified": false
      },
      {
       "id": "onefinity-journeyman-x-50",
       "vendor": "Onefinity",
       "family": "Journeyman",
       "model": "X-50",
       "travel": [1222.375, 815.975, 133.35],
       "controllers": [
         {"family": "buildbotics", "label": "Onefinity BB (Buildbotics)", "isDefault": true}
       ],
       "spindle": "router",
       "rapidXY": 10160,
       "accelerationXY": 750,
       "accelerationZ": 750,
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cutting area 48-1/8 × 32-1/8 × 5-1/4 in, as listed on Easel's partner page (Pro-series pages give 6-1/4 in Z)", "url": "https://www.easel.com/partners/machines/onefinity-original-x50"},
         "rapidXY": {"kind": "vendor", "note": "400 in/min rapid, Onefinity's official value for Vectric", "url": "https://forum.onefinitycnc.com/t/machine-configuration-management-acceleration-vectric-12-5-values-faq/33544"},
         "accelerationXY": {"kind": "vendor", "note": "29.528 in/s² (750 mm/s²), Onefinity's official value for Vectric's run-time estimates", "url": "https://forum.onefinitycnc.com/t/machine-configuration-management-acceleration-vectric-12-5-values-faq/33544"},
         "accelerationZ": {"kind": "vendor", "note": "29.528 in/s² (750 mm/s²), Onefinity's official value for Vectric's run-time estimates", "url": "https://forum.onefinitycnc.com/t/machine-configuration-management-acceleration-vectric-12-5-values-faq/33544"},
         "controllers": {"kind": "vendor", "note": "Gen 1 Original (2020) and Pro (2022) machines use the BB Buildbotics controller, discontinued in 2025; Redline upgrade kits exist", "url": "https://www.onefinitycnc.com/post/which-controller-does-my-onefinity-machine-use"}
       },
       "notes": "Gen 1 Original and Pro series, no longer sold; large installed base. The Woodworker X-50 is 32-1/8 × 32-1/8 × 5-1/4 in. Onefinity sells Redline upgrade kits (RealTime RTX motion control), but NativeCAM has no controller family for Redline yet, so it isn't listed. Takes an owner-supplied 65 mm router.",
       "verified": false
      },
      {
       "id": "onefinity-elite-gen1-foreman",
       "vendor": "Onefinity",
       "family": "Elite Gen 1",
       "model": "Foreman",
       "travel": [1219.2, 1219.2, 165],
       "controllers": [
         {"family": "masso", "label": "Masso G3 Touch", "isDefault": true}
       ],
       "spindle": "router",
       "rapidXY": 15240,
       "accelerationXY": 500,
       "accelerationZ": 500,
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "48 × 48 in cutting area as listed on Easel's partner page; 165 mm Z travel (Z-20 slider) per Onefinity's Elite material", "url": "https://www.easel.com/partners/machines/onefinity-elite-series"},
         "rapidXY": {"kind": "vendor", "note": "600 IPM rapid, Onefinity's official value", "url": "https://forum.onefinitycnc.com/t/machine-configuration-management-acceleration-vectric-12-5-values-faq/33544"},
         "accelerationXY": {"kind": "vendor", "note": "19.685 in/s² (500 mm/s²) on every axis, Onefinity's official value for Vectric's run-time estimates", "url": "https://forum.onefinitycnc.com/t/machine-configuration-management-acceleration-vectric-12-5-values-faq/33544"},
         "accelerationZ": {"kind": "vendor", "note": "19.685 in/s² (500 mm/s²) on every axis, Onefinity's official value for Vectric's run-time estimates", "url": "https://forum.onefinitycnc.com/t/machine-configuration-management-acceleration-vectric-12-5-values-faq/33544"},
         "controllers": {"kind": "vendor", "note": "Elite Gen 1 (2023) machines use the Masso G3 Touch; Redline upgrade kits exist", "url": "https://www.onefinitycnc.com/post/which-controller-does-my-onefinity-machine-use"}
       },
       "notes": "Gen 1 Elite (2023) with closed-loop steppers; also sold as Woodworker (32 × 32 in) and Journeyman (48 × 32 in). Superseded by the Gen 2 Elite, which runs the Redline Control System on RealTime RTX-2; NativeCAM has no controller family for Redline yet, so Gen 2 isn't in the catalogue and Redline isn't listed here. Onefinity's Masso post supports a RapidChange ATC.",
       "verified": false
      },
      {
       "id": "shopbot-desktop",
       "vendor": "ShopBot",
       "family": "Desktop",
       "model": "",
       "travel": [609.6, 457.2, 88.9],
       "controllers": [
         {"family": "openSBP", "label": "ShopBot Control System", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "minRPM": 9000,
       "maxRPM": 18000,
       "rapidXY": 9144,
       "maxFeed": 6096,
       "accelerationXY": 500,
       "accelerationZ": 500,
       "units": "inch",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cutting volume 24 × 18 × 3.5 in on the vacuum or T-slot deck (23 × 17 × 8 in with the lower deck); XYZ travel 25 × 20 × 5 in", "url": "https://shopbottools.com/products/desktop/"},
         "minRPM": {"kind": "vendor", "note": "Industrial 1 HP spindle, 9,000–18,000 RPM", "url": "https://shopbottools.com/products/"},
         "maxRPM": {"kind": "vendor", "note": "Industrial 1 HP spindle, 9,000–18,000 RPM", "url": "https://shopbottools.com/products/"},
         "rapidXY": {"kind": "vendor", "note": "Max rapid speed 360 in/min", "url": "https://shopbottools.com/products/desktop/"},
         "maxFeed": {"kind": "vendor", "note": "Max cut speed 240 in/min", "url": "https://shopbottools.com/products/desktop/"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: 500 mm/s² X/Y for ShopBot machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: 500 mm/s² Z for ShopBot machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "controllers": {"kind": "vendor", "note": "ShopBot's own control software (OpenSBP)", "url": "https://shopbottools.com/products/desktop/"}
       },
       "notes": "ShopBot's control software runs OpenSBP (.sbp) part files rather than G-code.",
       "verified": false
      },
      {
       "id": "shopbot-desktop-max",
       "vendor": "ShopBot",
       "family": "Desktop MAX",
       "model": "",
       "travel": [914.4, 609.6, 88.9],
       "controllers": [
         {"family": "openSBP", "label": "ShopBot Control System", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "minRPM": 9000,
       "maxRPM": 18000,
       "rapidXY": 9144,
       "maxFeed": 6096,
       "accelerationXY": 500,
       "accelerationZ": 500,
       "units": "inch",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cutting area 36 × 24 × 3.5 in on the vacuum or T-slot deck (35 × 23 × 8 in with the lower deck); XYZ travel 41 × 25 × 5 in", "url": "https://shopbottools.com/products/desktop-max/"},
         "minRPM": {"kind": "vendor", "note": "Industrial 1 HP spindle, 9,000–18,000 RPM", "url": "https://shopbottools.com/products/"},
         "maxRPM": {"kind": "vendor", "note": "Industrial 1 HP spindle, 9,000–18,000 RPM", "url": "https://shopbottools.com/products/"},
         "rapidXY": {"kind": "vendor", "note": "Max rapid speed 360 in/min", "url": "https://shopbottools.com/products/desktop-max/"},
         "maxFeed": {"kind": "vendor", "note": "Max cut speed 240 in/min", "url": "https://shopbottools.com/products/desktop-max/"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: 500 mm/s² X/Y for ShopBot machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: 500 mm/s² Z for ShopBot machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "controllers": {"kind": "vendor", "note": "ShopBot's own control software (OpenSBP)", "url": "https://shopbottools.com/products/desktop-max/"}
       },
       "notes": "ShopBot's control software runs OpenSBP (.sbp) part files rather than G-code. A Desktop MAX ATC version exists; set the tool change to automatic for it.",
       "verified": false
      },
      {
       "id": "axiom-autoroute-ar8-elite",
       "vendor": "Axiom Precision",
       "family": "AutoRoute",
       "model": "AR8 Elite",
       "travel": [609.6, 1219.2, 190],
       "controllers": [
         {"family": "richAuto", "label": "RichAuto B58 DSP", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "maxRPM": 24000,
       "rapidXY": 8128,
       "accelerationXY": 500,
       "accelerationZ": 500,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "X 24 × Y 48 in with 7.48 in Z on the Elite (5.9 in on the Pro), per Rockler's listing of Axiom's specifications", "url": "https://www.rockler.com/axiom-ar8-elite-cnc-router"},
         "maxRPM": {"kind": "vendor", "note": "2.2 kW (3 HP) ER20 spindle, 0–24,000 RPM, per Rockler's listing", "url": "https://www.rockler.com/axiom-ar8-elite-cnc-router"},
         "rapidXY": {"kind": "vendor", "note": "Rapid 320 IPM on the Elite (300 IPM on the Pro), per Rockler's listing", "url": "https://www.rockler.com/axiom-ar8-elite-cnc-router"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: 500 mm/s² X/Y for RichAuto DSP controllers, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: 500 mm/s² Z for RichAuto DSP controllers, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "controllers": {"kind": "vendor", "note": "RichAuto B58 handheld DSP on the Elite (B18 on the Pro)", "url": "https://www.rockler.com/axiom-ar8-elite-cnc-router"}
       },
       "notes": "Files load from USB on the handheld DSP. Axiom's Vectric post is reported as 'Axiom HHC CNC (mm) (*.mmg)'. AR4 and AR16 sizes and the Pro (RichAuto B18) aren't listed separately.",
       "verified": false
      },
      {
       "id": "stepcraft-d-series-d600",
       "vendor": "Stepcraft",
       "family": "D-Series",
       "model": "D.600",
       "travel": [417, 596, 132],
       "controllers": [
         {"family": "uccnc", "label": "UCCNC for Stepcraft", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "rapidXY": 4200,
       "accelerationXY": 500,
       "accelerationZ": 500,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Machine table range X 0–417, Y 0–596, Z 0–132 mm in Stepcraft's machine-parameter tables (seen through a search summary; earlier D-series manuals give Z 0–137 mm and the comparison table 416 × 595 × 135 mm)", "url": "https://www.stepcraft-systems.com/en/services/maschinenparameter-en"},
         "rapidXY": {"kind": "vendor", "note": "Fast traverse 70 mm/s at 1,600 steps/rev in Stepcraft's D-series parameter sheet; a makerspace lists 3,000 mm/min", "url": "https://oldjoomla.stepcraft-systems.com/images/SC-Service/SC_Machine_parameters_D-Series_EN.pdf"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: 500 mm/s² X/Y for UCCNC machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: 500 mm/s² Z for UCCNC machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "controllers": {"kind": "vendor", "note": "Stepcraft ships the D-series with UCCNC for Stepcraft", "url": "https://oldjoomla.stepcraft-systems.com/images/SC-Service/SC_Machine_parameters_D-Series_EN.pdf"}
       },
       "notes": "Spindle not included; Stepcraft's HF-500 and MM-1000 DI take their speed from UCCNC (set the spindle to router if you fit a plain trim router). D.420 and D.840 sizes and the ATC-equipped Q-series aren't listed: their travel wasn't available.",
       "verified": false
      },
      {
       "id": "tormach-24r",
       "vendor": "Tormach",
       "family": "24R",
       "model": "",
       "travel": [628.65, 1416.05, 170.18],
       "controllers": [
         {"family": "linuxCNC", "label": "PathPilot (LinuxCNC)", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "minRPM": 10000,
       "maxRPM": 24000,
       "rapidXY": 5080,
       "rapidZ": 5080,
       "maxFeed": 5080,
       "accelerationXY": 500,
       "accelerationZ": 500,
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Travel X 24.75 × Y 55.75 × Z 6.7 in", "url": "https://knowledgebase.tormach.com/24r/machine-specifications"},
         "minRPM": {"kind": "vendor", "note": "2 hp (1.5 kW) liquid-cooled ER20 spindle, 10,000–24,000 RPM", "url": "https://knowledgebase.tormach.com/24r/machine-specifications"},
         "maxRPM": {"kind": "vendor", "note": "2 hp (1.5 kW) liquid-cooled ER20 spindle, 10,000–24,000 RPM", "url": "https://knowledgebase.tormach.com/24r/machine-specifications"},
         "rapidXY": {"kind": "vendor", "note": "Tormach gives one maximum, 200 IPM (5.0 m/min) on X/Y/Z, which also caps rapids", "url": "https://knowledgebase.tormach.com/24r/machine-specifications"},
         "rapidZ": {"kind": "vendor", "note": "Tormach gives one maximum, 200 IPM (5.0 m/min) on X/Y/Z, which also caps rapids", "url": "https://knowledgebase.tormach.com/24r/machine-specifications"},
         "maxFeed": {"kind": "vendor", "note": "Max feed 200 IPM (5.0 m/min) on X/Y/Z", "url": "https://knowledgebase.tormach.com/24r/machine-specifications"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: 500 mm/s² X/Y for PathPilot machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: 500 mm/s² Z for PathPilot machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "controllers": {"kind": "vendor", "note": "PathPilot v2.4.x or later, which is based on LinuxCNC", "url": "https://knowledgebase.tormach.com/24r/machine-specifications"}
       },
       "notes": "2×4 ft router. An ATC kit (ISO20 1.5 kW spindle, power drawbar, 10-tool rack) is available; set the tool change to automatic if fitted.",
       "verified": false
      },
      {
       "id": "tormach-xstech",
       "vendor": "Tormach",
       "family": "xsTECH",
       "model": "",
       "travel": [218.44, 160.02, 60.96],
       "controllers": [
         {"family": "linuxCNC", "label": "PathPilot (LinuxCNC)", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "minRPM": 3000,
       "maxRPM": 15000,
       "accelerationXY": 500,
       "accelerationZ": 500,
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Travel 8.6 × 6.3 × 2.4 in", "url": "https://knowledgebase.tormach.com/xstech/xstech-machine-specifications"},
         "minRPM": {"kind": "vendor", "note": "80 W BLDC spindle, 3,000–15,000 RPM", "url": "https://knowledgebase.tormach.com/xstech/xstech-machine-specifications"},
         "maxRPM": {"kind": "vendor", "note": "80 W BLDC spindle, 3,000–15,000 RPM", "url": "https://knowledgebase.tormach.com/xstech/xstech-machine-specifications"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: 500 mm/s² X/Y for PathPilot machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: 500 mm/s² Z for PathPilot machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "controllers": {"kind": "vendor", "note": "PathPilot (LinuxCNC-based)", "url": "https://knowledgebase.tormach.com/xstech/xstech-machine-specifications"}
       },
       "notes": "Small desktop router. The xsTECH Pro (announced October 2025) adds a standard ATC. No feed or rapid rate is published.",
       "verified": false
      },
      {
       "id": "shopsabre-pro-408",
       "vendor": "ShopSabre",
       "family": "PRO",
       "model": "408",
       "travel": [1524, 2540, 304.8],
       "controllers": [
         {"family": "winCNC", "label": "WinCNC", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "rapidXY": 30480,
       "accelerationXY": 1000,
       "accelerationZ": 500,
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cut area 60 × 100 × 12 in (older catalogs list 55 × 100 × 12 in)", "url": "https://www.shopsabre.com/shopsabre-cnc-router-of-the-month-pro-series/"},
         "rapidXY": {"kind": "vendor", "note": "1,200 IPM rapid", "url": "https://www.shopsabre.com/shopsabre-cnc-router-of-the-month-pro-series/"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: 1000 mm/s² X/Y for full-sheet WinCNC machines, which publish no acceleration; the top of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: 500 mm/s² Z for full-sheet WinCNC machines, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "controllers": {"kind": "vendor", "note": "Used-machine listings name ShopSabre's WinCNC industrial control; ShopSabre's product page doesn't name the controller", "url": "https://www.machinetools.com/en/for-sale/706824-shopsabre-pro408-routers"}
       },
       "notes": "Spindle size and speed depend on the configuration (listings show 4–10 HP, 18,000–24,000 RPM), so no RPM range is given. An automatic tool changer is an upgrade; set the tool change to automatic if fitted.",
       "verified": false
      },
      {
       "id": "lunyee-1325-pro",
       "vendor": "Lunyee",
       "family": "1325",
       "model": "Pro",
       "travel": [1300, 2500, 200],
       "controllers": [
         {"family": "mach3", "label": "Mach3", "isDefault": true}
       ],
       "spindle": "vfdSpindle",
       "maxRPM": 24000,
       "accelerationXY": 1000,
       "accelerationZ": 500,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Working area 1300 × 2500 × 200 mm, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/lunyee-cnc-1325-pro"},
         "maxRPM": {"kind": "vendor", "note": "2.2, 3 or 5.5 kW water-cooled spindle, 0–24,000 RPM, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/lunyee-cnc-1325-pro"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: 1000 mm/s² X/Y for full-sheet Mach3 and DSP routers, which publish no acceleration; the top of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: 500 mm/s² Z for full-sheet Mach3 and DSP routers, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "controllers": {"kind": "vendor", "note": "Runs Mach3 (Easel's page says it isn't a GRBL machine)", "url": "https://easel.com/partners/machines/lunyee-cnc-1325-pro"}
       },
       "notes": "4×8 router. No feed or rapid rate is published.",
       "verified": false
      },
      {
       "id": "generic-1325-router",
       "vendor": "Generic",
       "family": "1325 router",
       "model": "",
       "travel": [1300, 2500, 200],
       "controllers": [
         {"family": "richAuto", "label": "RichAuto A11 DSP", "isDefault": true},
         {"family": "mach3", "label": "Mach3"},
         {"family": "masso", "label": "Masso G3 (retrofit)"},
         {"family": "mach4", "label": "Mach4 (retrofit)"},
         {"family": "centroid", "label": "Centroid (retrofit)"}
       ],
       "spindle": "vfdSpindle",
       "maxRPM": 24000,
       "rapidXY": 25000,
       "maxFeed": 18000,
       "accelerationXY": 1000,
       "accelerationZ": 500,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "About 1300 × 2500 × 200 mm, per a seller listing; typical of 1325 (4×8) routers", "url": "https://www.alibaba.com/product-introduction/With-NK105-CNC-Controller-1325-Router_62390215244.html"},
         "maxRPM": {"kind": "vendor", "note": "About 3 kW water-cooled spindle, 0–24,000 RPM, per a seller listing", "url": "https://www.alibaba.com/product-introduction/With-NK105-CNC-Controller-1325-Router_62390215244.html"},
         "rapidXY": {"kind": "vendor", "note": "Seller's claimed rapid, 25,000 mm/min (another seller claims 35 m/min)", "url": "https://www.alibaba.com/product-introduction/With-NK105-CNC-Controller-1325-Router_62390215244.html"},
         "maxFeed": {"kind": "vendor", "note": "Seller's claimed working speed, 18,000 mm/min", "url": "https://www.alibaba.com/product-introduction/With-NK105-CNC-Controller-1325-Router_62390215244.html"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: 1000 mm/s² X/Y for full-sheet DSP routers, which publish no acceleration; the top of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: 500 mm/s² Z for full-sheet DSP routers, which publish no acceleration; the low end of the research's 500–1,000 mm/s² band for DSP, WinCNC, ShopBot and Centroid machines. Enter your controller's real value"},
         "controllers": {"kind": "estimated", "note": "Typical of the class, from seller listings: RichAuto A11 DSPs are the most common, NK105 and Mach3 also ship, and Masso, Mach4 and Centroid are frequent retrofits. Check yours", "url": "https://www.alibaba.com/product-introduction/With-NK105-CNC-Controller-1325-Router_62390215244.html"}
       },
       "notes": "A template for the many Chinese 4×8 routers (StyleCNC and others); check your own controller and speeds, since sellers' figures vary widely. Weihong NK105 DSPs are also common, but NativeCAM has no controller family for them yet.",
       "verified": false
      },
      {
       "id": "openbuilds-lead-1010",
       "vendor": "OpenBuilds",
       "family": "LEAD",
       "model": "1010",
       "travel": [730, 810, 100],
       "controllers": [
         {"family": "grblHAL", "sender": "OpenBuilds CONTROL", "label": "BlackBox X32", "isDefault": true}
       ],
       "spindle": "router",
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.02,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Working area 730 × 810 × 100 mm (29 × 32 × 4 in), as listed on Easel's partner page", "url": "https://easel.com/partners/machines/openbuilds-lead-cnc-1010"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: belt / V-wheel Grbl class default (500 mm/s² X/Y); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: belt / V-wheel Grbl class default (300 mm/s² Z); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: belt / V-wheel Grbl class default (0.02 mm junction deviation); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "grblHAL on the BlackBox X32, run from OpenBuilds CONTROL", "url": "https://easel.com/partners/machines/openbuilds-lead-cnc-1010"}
       },
       "notes": "No longer sold: OpenBuilds has shut down. Lead screws on V-wheels; takes a 65 mm compact router. No feed or rapid rate is published.",
       "verified": false
      },
      {
       "id": "millright-mega-v2-xl",
       "vendor": "MillRight CNC",
       "family": "Mega V2",
       "model": "XL",
       "travel": [889, 889, 133.35],
       "controllers": [
         {"family": "grbl", "sender": "Easel", "label": "GRBL", "isDefault": true},
         {"family": "masso", "label": "Masso G3 Touch"}
       ],
       "spindle": "router",
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.02,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cuttable area 35 × 35 × 5.25 in (6.25 in Z stroke), as listed on Easel's partner page", "url": "https://easel.com/partners/machines/millright-mega-v2"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: belt / V-wheel Grbl class default (500 mm/s² X/Y, the nearest class for an open-loop rack-and-pinion Grbl frame); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: belt / V-wheel Grbl class default (300 mm/s² Z, the nearest class for an open-loop rack-and-pinion Grbl frame); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: belt / V-wheel Grbl class default (0.02 mm junction deviation, the nearest class for an open-loop rack-and-pinion Grbl frame); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "GRBL (standard) or Masso G3 Touch (selectable)", "url": "https://easel.com/partners/machines/millright-mega-v2"}
       },
       "notes": "Rack and pinion on X/Y, screw-driven Z, linear rails. Also sold as Standard (19 × 19 in) and XXL (50 × 50 in). Router mount for a Makita RT0701C or DeWalt DW618, or an optional 1.5 / 2.2 kW VFD spindle. No feed or rapid rate is published.",
       "verified": false
      },
      {
       "id": "ratrig-stronghold-one-750",
       "vendor": "Rat Rig",
       "family": "StrongHold ONE",
       "model": "750",
       "travel": [744, 750, 105],
       "controllers": [
         {"family": "fluidNC", "label": "Rat Rig Rodent", "isDefault": true},
         {"family": "grblHAL", "label": "BlackBox X32"}
       ],
       "spindle": "router",
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.01,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Work area 744 × 750 mm with 105 mm maximum Z travel (the 1250 size is 1244 × 1250 mm), from Rat Rig's documentation as seen through a search summary", "url": "https://docs.ratrig.com/product-details/stronghold-one"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: screw-driven desktop (the ball-screw desktop values) Grbl class default (500 mm/s² X/Y); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: screw-driven desktop (the ball-screw desktop values) Grbl class default (300 mm/s² Z); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: screw-driven desktop (the ball-screw desktop values) Grbl class default (0.01 mm junction deviation); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "FluidNC is the officially supported firmware for Rat Rig's Rodent controller (grblHAL listed as coming); the standard kit's electronics are a BlackBox X32", "url": "https://docs.ratrig.com/product-details/stronghold-one"}
       },
       "notes": "Kit machine with TR8 lead screws. Bundles range from a 230 V router to a 2.2 kW water-cooled spindle. No feed or rapid rate is published.",
       "verified": false
      },
      {
       "id": "maslow-maslow-4",
       "vendor": "Maslow CNC",
       "family": "Maslow 4",
       "model": "",
       "travel": [1200, 2400, 50],
       "controllers": [
         {"family": "fluidNC", "sender": "Easel", "label": "Maslow FluidNC", "isDefault": true}
       ],
       "spindle": "router",
       "rapidXY": 2500,
       "rapidZ": 300,
       "maxFeed": 2500,
       "accelerationXY": 500,
       "accelerationZ": 300,
       "junctionDeviation": 0.02,
       "units": "mm",
       "toolChange": "manualM6",
       "sources": {
         "travel": {"kind": "vendor", "note": "Cuttable area 1.2 × 2.4 m (4 × 8 ft) X/Y as listed on Easel's partner page; Easel gives Z as 65 mm in one place and 50 mm in another, so this uses 50", "url": "https://easel.com/partners/machines/maslow-maslow-4/"},
         "rapidXY": {"kind": "vendor", "note": "Up to 2,500 mm/min (100 IPM) X/Y, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/maslow-maslow-4/"},
         "rapidZ": {"kind": "vendor", "note": "Up to 300 mm/min (11 IPM) Z, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/maslow-maslow-4/"},
         "maxFeed": {"kind": "vendor", "note": "Up to 2,500 mm/min (100 IPM) X/Y, as listed on Easel's partner page", "url": "https://easel.com/partners/machines/maslow-maslow-4/"},
         "accelerationXY": {"kind": "estimated", "note": "Estimated: belt / V-wheel Grbl class default (500 mm/s² X/Y, a loose guess for a cable-driven frame); the vendor publishes none"},
         "accelerationZ": {"kind": "estimated", "note": "Estimated: belt / V-wheel Grbl class default (300 mm/s² Z, a loose guess for a cable-driven frame); the vendor publishes none"},
         "junctionDeviation": {"kind": "estimated", "note": "Estimated: belt / V-wheel Grbl class default (0.02 mm junction deviation, a loose guess for a cable-driven frame); the vendor publishes none"},
         "controllers": {"kind": "vendor", "note": "Maslow's FluidNC fork (v1.22.0 confirmed), run from Easel or from exported G-code", "url": "https://easel.com/partners/machines/maslow-maslow-4/"}
       },
       "notes": "Maslow 4.1, a cable-driven frameless machine that sits on the sheet. Its FluidNC fork needs Maslow's calibration before cutting. Takes a DeWalt DW611 router (D26200 for 240 V).",
       "verified": false
      }
    ]}
    """#
}
