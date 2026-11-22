# The Loading Screen of Your Life

> Look at why those frames from the video work so well: one hyper-specific mundane object floating in smoky black void, dramatic rim light, a quiet `LEVEL` bar, and deadpan RPG lore on the right.
>
> Half the shock and delight isn’t the 3D tech—it’s the museum-grade reverence given to ordinary, private pieces of your actual life.

## The Thesis

Most screensavers are wallpaper in motion. Most personalization is a settings panel with sliders and file pickers.

**The Loading Screen of Your Life** takes a different premise: your real life and your digital life already do the work. You do not configure a shrine—you live on your Mac, and when you step away, the screen quietly returns pieces of your own life to you with the dramatic lighting, floating stillness, and observational humor of a loading screen that just states what is actually happening.

Because the **stage** is always the same—pitch-black atmospheric void, drifting low mist, crisp rim light, slow orbit (and drag-to-spin / pinch-to-zoom), a quiet `LEVEL` bar, and plain observational copy on the right—an artifact does not depend on any single rendering technology. A Gaussian splat, a sculpted 3D mesh, a procedural shader object, and an auto-segmented photograph with depth relief all share the exact same dark glass museum case.

---

## Five Categories of Personal Artifacts

### 1. Auto-Harvested Photo Relics
Zero manual 3D scanning. macOS Vision's native foreground subject segmentation (`VNGenerateForegroundInstanceMaskRequest`) paired with local monocular depth (`Depth Anything V2` or relief fallback) lifts *just the subject* out of an ordinary photograph—a sleeping dog, a coffee cup on a café table, a street sign from a trip, a pair of sneakers—and suspends it inside the smoky void with edge rim lighting and parallax.

> *"Taken Oct 14, 2023 · 6:14 PM. You forgot this was still on your Mac."*

### 2. Digital Life Cast as Worn Physical Objects
Purely digital habits materialized as scuffed, tangible RPG loot:

- **Weathered Memory Cartridge** — a matte retro cartridge stamped with your active project/level and brass edge pins, scarred by how long the session has been running.
- **Worn Mechanical Keycap (`⌘S`)** — a single backlit PBT keycap on a tactile switch stem, polished by hours in editors and terminals.
- **Chrome-Bias Mixtape** — a translucent smoked-shell cassette whose twin reels turn quietly in the dark.

### 3. Everyday Talismans
Ordinary real-world objects elevated to cathedral lighting, surfaced automatically by your real rhythm from `LerpPulse`:

- **Ceramic Vessel of Late Hours** — a chipped matte mug favored during late-night sessions and deep `make` streaks.
- **Blue-Ribbon Achievement Trophy** — an engraved gold cup and royal-blue rosette that rises into focus after your longest uninterrupted streak.
- **Cracked Brass Hourglass** — turned dark brass and falling golden sand that appears on high context-switch days or marathon runs without a break.

### 4. Quest Items from Your Own Brain
Drop one-line reminders, half-finished ambitions, or personal mantras into:

```text
~/Library/Application Support/Lerping/Artifacts/quests.txt
```

Each line becomes a live lore / active-quest entry woven into the loading screen alongside your real telemetry—never preachy, always dry and quiet.

### 5. The Voice: Observational Humor, No Character
No RPG cosplay, no "in this realm", no mascot voice. Reality is funny enough when stated plainly next to museum lighting:

- **Top-right `LEVEL` bar:** Driven privately on-device by `LerpPulse` (`CritterLedger`), turning accumulated hours, days lived, and focus streaks into quiet progression.
- **Right-side Notes:** Straight, specific observations built from your real day:
  1. **True telemetry, stated plainly** — *"You've been at this computer for 3h 15m today, switched apps 29 times, and took 3 breaks. 42 minutes of that was after midnight."*
  2. **Everyday habits** — *"You already saved this file twice in the last four seconds. You are going to press it one more time just in case."* / *"You put on music to focus and spent the next twelve minutes reorganizing the queue."*
  3. **Real moments** — *"There is a full moon outside right now. You are looking at a screensaver."* / *"It is 3:00 AM. Whatever you are fixing right now is going to look much simpler after breakfast."*

---

## Design Principles

1. **Zero configuration.** It becomes personal from what already happens on your Mac (`LerpPulse`, clock, local photos, optional `quests.txt`), without asking you to tweak uniforms.
2. **Non-literal.** From across the room it reads as stark, atmospheric art. Only *you* know why the trophy, the hourglass, or that ceramic mug showed up tonight.
3. **Private & local.** All telemetry (`~/Library/Application Support/Lerping/Critter/ledger.json`), photo cutouts, and lore stay on this Mac. No cloud, no accounts, no screenshots.
4. **Pure & reproducible stills.** Gallery thumbnails and `LerpPreview --snapshot` render against a fixed `.still` fixture so hover previews and stills remain deterministic, while live sessions in the screensaver and playground reflect your real day.

---

## How It Lives in Lerping@Home

Everything here is purely additive alongside the rest of the shader library:

| Piece | Role |
|---|---|
| `Sources/Shaders/life-artifacts.metal` | Flagship look on the **Artifacts** shelf (`// lerp-data: artifacts`): smoky void, volumetric mist, depth-aware relic compositing, photo-relic relief raymarch, and Skyrim HUD overlay. Supports drag-to-spin (`yaw`/`pitch`), pinch-to-zoom (`magnify`), and head parallax (`u.viewer`). |
| `Sources/LerpCore/ArtifactLedger.swift` | Reads `LerpPulse` (`CritterLedger`), local photo relics, and optional `quests.txt`; computes RPG `LEVEL`/XP, selects artifacts from your day, and generates deadpan lore. |
| `Sources/LerpCore/ArtifactScene.swift` | Offscreen 4× MSAA SceneKit studio rendering the 6 sculpted procedural 3D relics with dramatic rim lighting and dynamic engraved/printed labels. |
| `Sources/LerpCore/ArtifactHUD.swift` | CoreText/CoreGraphics mipmapped HUD renderer for the top-right `LEVEL` bar, artifact title, hairline rule, and balanced `TIPS & TRICKS` copy. |
| `Sources/LerpCore/ArtifactData.swift` | `LerpDataProvider` coordinating session snapshots, 3D scene rendering, photo-relic loading, and HUD updates. |
| `scripts/artifact-photo.swift` | Local CLI (`make artifact-photo PHOTO=… NAME=…`) that lifts a subject out of any photograph via Apple Vision + depth estimation and writes a personal photo relic into `~/Library/Application Support/Lerping/Artifacts/`. |

### Adding Your Own Photo Relic

```sh
make artifact-photo PHOTO=~/Pictures/coffee.jpg NAME=kyoto-cup \
  TITLE="The Espresso Cup" \
  LORE="Taken Oct 14, 2023. You took four pictures of this cup and never looked at them again."
```

### Adding Your Own Notes / Reminders

Create `~/Library/Application Support/Lerping/Artifacts/quests.txt` with one line per entry:

```text
Finish the lighting pass before Friday.
Put the laundry away before it becomes part of the chair.
```
