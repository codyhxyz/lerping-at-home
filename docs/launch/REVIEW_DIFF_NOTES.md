# README and launch review

[Proposed README](README.proposed.md) · [Launch copy and three-shot reel](LAUNCH_COPY.md) · [Current README](../../README.md)

## What's changed

- Lead with three things people can picture: weather at the window, music that colors a room, and a photo they can lean into. The pitch is a better idle screen, not more shaders or a new editor to learn.
- Replace technical categories and drifting shader counts with five feeling-based shelves. Put playback surfaces and a three-step install before the studio and source build.
- Distinguish local system audio from optional album metadata, depth from full reconstruction, and desktop windows from changing the system wallpaper. Remove obsolete instructions for the saver changing the wallpaper and the saver sheet writing rotation.
- Keep entry points for developers, packaging, custom looks, deterministic previews, and credits. Link to source and the porting guide instead of putting sandbox investigations, control internals, asset formats, and profiling recipes in the launch path. The original README is unchanged in this branch.

## Before promoting the drafts

- [ ] **Test the signed package, not just the checkout.** Confirm which install choices and downloaded dependencies ship, how LerpPulse is enabled/configured in each install, and what works with the saver alone. Trim copy for anything not included.
- [ ] **Run all three demos on the intended release.** Confirm the Weather Window display name and location/live controls, the actual Sound & Flow look with both bass and palette bindings, and the photo-drop entry point and model. Verify Ambient Frame, Code, and remaining menu labels. Say "local weather" only for a take using fresh live conditions, and don't imply instantaneous photo processing.
- [ ] **Check input disclosures.** Confirm the exact weather/location setup, the optional SpotAPI path, permissions, and what the helper writes to `world.json`. Don't imply the saver taps audio, that private Spotify endpoints are permanent, or that music metadata is required for motion.
- [ ] **Clear visuals and sound.** Use redistributable captures, a photo cleared for public use, and cleared artwork and audio (or leave them out). Check the existing mock soundtrack is absent from the release edit.
- [ ] **Promote and publish only after review.** The proposed README's relative links are correct under `docs/launch/`; from the root, change `../images/` to `docs/images/` and remove `../../` from repository-relative links. Remove the draft comment when the final public copy matches the release.
