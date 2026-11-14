# Head-tracked parallax: 2026 projects

Webcam head-coupled perspective ("the screen is a window") made in 2026, for
Lerping's Track Head, Desktop Mode and pointer fallback. Dates are each repo's
GitHub `created_at` / last push, or a page's `article:published_time`, checked
2026-11-14.

Nearly all of them use the same method: **MediaPipe Face Landmarker** (iris
landmarks 468/473) → **Kooima off-axis (asymmetric frustum) projection** →
**One Euro filter**, mostly in Three.js in the browser.

## Most relevant to Lerping

| Project | Dates | Why |
|---|---|---|
| [VintagePhebe/head-tracked-3d-display](https://github.com/VintagePhebe/head-tracked-3d-display) | 2026-10-25 → 10-26 | The most complete pipeline. `HeadPoseFilter` (`Sources/Playground/HeadTracker.swift`) ports its `src/tracking/headPose.ts`. It also has `src/desktop/` (desktop capture as a 3D surface) and `src/tracking/mouseSim.ts` (a mouse stand-in), the same ideas as Desktop Mode and `PointerViewer`. Those two have not been read yet. |
| [icurtis1/off-axis-sneaker](https://github.com/icurtis1/off-axis-sneaker) | 2026-01-12 → 04-01, ★434 | The one that went viral: Ian Curtis's 3D-scanned shoe, MediaPipe + Three.js, a splat via World Labs. [X post, 2026-01-05](https://x.com/XRarchitect/status/2008221154100580600) (~264K views); [80.lv write-up](https://80.lv/articles/check-out-this-off-axis-projection-demo-that-uses-face-tracking-to-create-a-3d-illusion); [pIXELsHAM, 2026-01-25](https://www.pixelsham.com/2026/01/25/ian-curtis-an-off-axis-projection-demo-using-mediapipe-for-face-tracking/). |
| [V4C38/sensai-off-axis](https://github.com/V4C38/sensai-off-axis) | 2026-04-01 → 04-05, ★20 | A fork of off-axis-sneaker that shows Gaussian splats, which is what Lerping's splat looks are. |
| [shaal/LookAround](https://github.com/shaal/LookAround) | 2026-11-01 → 11-07 | Head tracking plus eye direction, with ordinary mouse navigation as the alternative. |
| [jasondecamp/desktop-vr](https://github.com/jasondecamp/desktop-vr) | 2026-03-26 → 10-28 | "Head-tracking parallax 3D display engine", Three.js integration. |

## The rest

| Project | Dates | Notes |
|---|---|---|
| [MindDock/off-axis-demo](https://github.com/MindDock/off-axis-demo) | 2026-01-07 → 01-10, ★36 | MediaPipe FaceMesh, irises 468/473, smoothed with a lerp. |
| [Harkiran-P/matrix-perspective-portal](https://github.com/Harkiran-P/matrix-perspective-portal) | 2026-01-11 → 01-13 | Python + OpenCV + MediaPipe, cyberpunk look. |
| [ordinarykids/parallax-view](https://github.com/ordinarykids/parallax-view) | 2026-01-11 → 01-12 | Head position plus gaze, physics-based animation. |
| [TheSeanLavery/LeanTrack3D](https://github.com/TheSeanLavery/LeanTrack3D) | 2026-03-11 | WebGPU + MediaPipe. |
| [Depth Window (Chris Pirillo)](https://arcade.pirillo.com/depth-window.html) | published 2026-04-03 | Browser; loads STL/OBJ/3MF models. |
| [saint2706/off-axis-experiments](https://github.com/saint2706/off-axis-experiments) | 2026-04-29 → 07-21 | Kooima-style projection. |
| [AralimNGA/head-tracking-3d](https://github.com/AralimNGA/head-tracking-3d) | 2026-06-10 → 10-18 | Fish-tank VR, Face Landmarker + Three.js. |
| [Danyals-code/head-tracked-perspective](https://github.com/Danyals-code/head-tracked-perspective) | 2026-07-02 → 07-03 | A cuboid room; has MacBook screen presets and an x-sign flip. |
| [neumont-gamedev/looking-glass](https://github.com/neumont-gamedev/looking-glass) | 2026-09-09 → 09-17 | One Euro filter, Kooima projection. |
| [alaabelghith/world-window](https://github.com/alaabelghith/world-window) | 2026-10-06 → 10-11 | Depth from the outer eye corners; its README calls that rough and uncalibrated. |
| [arpitmann/offaxis-robot](https://github.com/arpitmann/offaxis-robot) | 2026-10-13 | A robot that mirrors your face, hands and body, off-axis. |
| [TalibIbrahim/peekaboo-3d-parallax-window](https://github.com/TalibIbrahim/peekaboo-3d-parallax-window) | 2026-10-14 → 11-06 | "Living window", asymmetric frustum. |
| [liaru-lab/web-parallax](https://github.com/liaru-lab/web-parallax) | 2026-10-29, ★3 | Off-axis frustum plus device sensors; motion parallax for one viewer only. |
| [martinerlam/head-parallax](https://github.com/martinerlam/head-parallax) | 2026-11-03 | Three.js eye-position camera, Face Landmarker. |

## Checked and not 2026

- [Parallax Window (emptyhead.dev)](https://www.emptyhead.dev/assets/projects/docs/parallax_window?lang=en): Python desktop app, published 2025-12-24 (page modified 2026-10-07).
- [True3D (Daniel Habib)](https://digitalproduction.com/2025/10/02/your-screen-now-a-window-former-meta-engineer-revives-head-coupled-3d/): article published 2025-10-02, modified 2026-10-14.
- [munrocket/parallax-effect](https://github.com/munrocket/parallax-effect): 2020, last push 2022.
- [adewinter/perspective](https://github.com/adewinter/perspective): 2022.
