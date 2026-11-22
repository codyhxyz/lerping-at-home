# Lerping@Home launch copy

**Review draft.** Publish only claims confirmed in the signed release; see [review checklist](REVIEW_DIFF_NOTES.md). The shots below are a recording plan, not finished video.

## Manifesto

Most days a screen is a list of things you owe somebody. When you step away, it doesn't have to go black or find another reason to pull you in. It can be a rainy window, a little village at dusk, or a photograph with room to lean into. Let the weather change it. Let your music color it. Let the hours leave a trace. Lerping@Home makes the Mac worth looking at when there's nothing you need to look at. And if you wonder how a scene works, the source is right there.

## Taglines

1. **Your Mac has a life after work.**
2. A screen saver for the world you're actually in.
3. Less screen time. Better idle time.
4. The rain outside. The record inside. Both on your Mac.
5. A window, not another thing to check.

## Show HN

**Show HN: Lerping@Home – A Mac screen saver that takes cues from weather and music**

I wanted a screen saver I'd actually notice when I came back to my desk, not because it was loud, but because it felt like this room on this day. I built one for Apple Silicon.

Weather Window takes its light and rain from local conditions. In Playground, a look can take its color from album art and its motion from system audio. You can also drop in a photo, then lean sideways and see the foreground move against the background. The same scenes can run full-screen or behind your desktop icons without changing your wallpaper.

Each look's Metal source is editable. Play with a slider, save a preset, or change the code while it's running. The renderer and app are AGPL-3.0-or-later. Normal stills and previews don't need live inputs. Weather uses a network feed; camera and audio come through macOS permissions. Spotify artwork is optional and isn't needed for audio reactivity.

[Source and downloads](https://github.com/codyhxyz/lerping-at-home). I'd love to hear which scene you'd leave on for a week, and which reactions you'd switch off.

## X / Twitter thread

1. **Your Mac has a life after work.** I built Lerping@Home because I wanted something better to come back to than a black screen. Start with this: rain outside, rain on your Mac. [Attach the weather clip.]
2. Put on a record. The cover colors the scene; the bass moves it. Audio reactivity works with what's playing on your Mac, not just Spotify. [Attach the music clip.]
3. Drop a photo. Lean sideways. The foreground moves against the background, like you're looking into it instead of at it. [Attach the photo clip.]
4. Leave a favorite on as your screen saver, take it full-screen, or let it play behind your icons. Open the hood to edit the Metal. For Apple Silicon Macs: https://github.com/codyhxyz/lerping-at-home/releases

## Product Hunt

- **Name:** Lerping@Home
- **Tagline:** Your Mac has a life after work.
- **Description:** Turn your Mac into a rainy window, a tiny world, or a canvas that moves to your music. Drop in a photo and lean into it. Play scenes as a screen saver, full-screen, or behind your icons. Open-source for Apple Silicon.

**Maker comment:** I don't need another app to check. I wanted something my Mac could do when I wasn't asking it to do anything. Start with Weather Window, then try your own photo. Tell me which one you'd keep around on an ordinary Tuesday.

## 30-second hero reel

Use three 10-second scenes. Establish what's driving the picture, show the picture respond, then hold long enough to enjoy it. Use the existing Geist wordmark for a short overlay on the final hold, not a fourth shot.

### Before recording

Use the installed, integrated build and working live inputs, not a staging app. From the integrated checkout, check the weather look exists, then open the installed app and Finder:

```sh
test -r Sources/Shaders/weather-window.metal && printf 'Weather Window present\n'
APP="$HOME/Applications/LerpPlayground.app"
[ -d "$APP" ] || APP=/Applications/LerpPlayground.app
open -a "$APP"
open "$HOME/Pictures"
```

Set Focus / Do Not Disturb and allow Screen Recording for the capture tool before rehearsal. Record on one display, preferably 16:9, in SDR. Open a look with **⌘O** and use **Shader → Preview Full Screen** (**⌃⌘F**) for clean plates. From the same shell, define this timed capture helper; choose the playback window during its six-second delay. No audio is captured by this command.

```sh
CAPTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lerping-hero.XXXXXX")
printf 'Takes: %s\n' "$CAPTURE_DIR"
record_take() {
  [ ! -e "$CAPTURE_DIR/$1.mov" ] || return 1
  (sleep 6; /usr/sbin/screencapture -v -D 1 -V "${2:-20}" "$CAPTURE_DIR/$1.mov") &
}
```

| Final time | Shot and visible proof | Setup and capture |
| --- | --- | --- |
| **00–10s · Weather Window** | **0–2s:** Real rain on the room's window, filmed with a phone. **2–7s:** Match cut to drops bending the light in Weather Window. **7–10s:** Hold with “Local weather, live.” | Configure the recording location, pick `weather-window` in the Library and leave its live setting on. Verify that the current feed matches the actual conditions; capture `record_take 01-weather`. If conditions don't match, wait for them or label a forced preset **Preset preview**, not live. |
| **10–20s · Spotify palette + bass** | **10–12s:** A permission-cleared album cover alongside the current look. **12–16s:** Cue a track with a contrasting cover; show the canvas change colors. **16–20s:** Hold on motion visibly responding to bass hits. | Run `open -a Spotify`. With the album-colors source configured, choose a **Sound & Flow** look that has both palette and bass bindings (verify in **Code**), then enable **Shader → React to System Audio**. Queue contrasting tracks and run `record_take 02-music 30`. Rehearse the delay between song change and palette update; leave enough room in the source take. |
| **20–30s · Photo window** | **20–23s:** Drag one recognizable photo in from Finder. **23–26s:** Reveal the same framing with depth. **26–30s:** From a second camera angle, show the person lean sideways as the near edge moves against the background. Overlay “One photo. Look around.” | Pick a photo you own with a bold foreground edge partly covering a distant subject. Enable **Shader → Track Head with Camera**, grant permission, then run `record_take 03-photo 30` and drop the file into Playground. Use **Shader → Recentre Head** at neutral and don't move the pointer over the render during the head-tracked take. If import takes longer, cut the wait honestly rather than implying instant processing. |

Preflight: inspect the weather cache without printing song or activity metadata (requires `jq`), and list candidate looks with both required music bindings:

```sh
jq '{updatedAt, conditions: .weather.label, rain: .weather.rain, snow: .weather.snow}' \
  "$HOME/Library/Application Support/Lerping/world.json"
git grep -lE '^// lerp-react: .*<- audio\.bass' -- 'Sources/Shaders/*.metal' |
  while IFS= read -r look; do
    if grep -qE '^// lerp-react: .*<- music\.palette[012]' "$look"; then
      printf '%s\n' "$look"
    fi
  done
```

If the photo drop isn't in the candidate, rehearse the lean with a separate custom look from the checkout. This is **not** a substitute for showing a working drop in the published clip.

```sh
make depth-window IMAGE="$HOME/Pictures/beach.jpg" NAME=launch-rehearsal
# In Playground: ⌘O → search launch-rehearsal → Return.
```

Use the real live takes for proof; the existing [launch-video recorder](../../launch-video/README.md#re-rendering-footage) creates deterministic beauty plates from `origin/main`, not live weather, music, or head-tracking takes. Cut against a track you have the rights to use, or deliver silent clips with captions. The existing Four Tet mock track isn't cleared for publication. For the bass shot, use audio from the actual performance only if cleared; don't dub an unrelated beat and imply the canvas is following it. Clear the album art independently or leave it out of frame.
