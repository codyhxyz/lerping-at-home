#!/usr/bin/env python3
"""Did the screensaver play anything the user had switched off?

This is the check that replaced `make doctor`, and the difference between them
is the whole point.

`doctor` hashed the source tree, hashed the installed bundle, and reported "up
to date" when they matched. It said that while this bug was reproducing, every
time, because the question it asked — do these bytes match those bytes — was
never the question in doubt. It made staleness *look* answered and so the real
question went unasked for three rounds of "the rotation is fixed now".

This asks the real one, and it asks the operating system rather than a harness:

  * the rotation comes from the user's ByHost plist, the file the playground
    writes and the saver reads;
  * the looks that actually appeared come from `log show`, which is written by
    the saver itself while a real screensaver session is on a real screen.

Nothing here sets anything. There is no fixture and no injected state, so it
cannot agree with itself: if the saver puts a switched-off look on screen, this
reports it, and if the saver never runs, this says that instead of passing.

Usage:  scripts/verify-rotation.py [--days N]
Exit:   0 clean · 1 a disabled look played · 2 no evidence to judge
"""

import argparse
import plistlib
import re
import subprocess
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path

SUBSYSTEM = "com.hergenroeder.lerping"
BYHOST = Path.home() / "Library/Preferences/ByHost"
# `log` is shadowed by a zsh function on this machine; the absolute path is not
# a style preference, it is the difference between output and "too many
# arguments".
LOG = "/usr/bin/log"
PLAYING = re.compile(r"playing (.+?) \((\d+) in rotation of (\d+) discovered\)")
PROFILE_TAG = re.compile(r"^\s*(?:crossfade\s+)?profile=(\S+)")
LIBRARY_PROFILE_ID = "00000000-0000-4000-8000-000000000001"


@dataclass
class Profile:
    name: str
    admission: str
    disabled: set
    roster: dict

    def excludes(self, look):
        shader, _, preset = look.partition("/")
        # Closed rosters list Defaults explicitly as the empty preset name.
        not_admitted = self.admission == "closed" and preset not in self.roster.get(shader, [])
        return not_admitted or look in self.disabled or f"{shader}/*" in self.disabled


def parse_state(state):
    """(version, active profile ID, policies by UUID), from the one record."""
    def profile(record):
        admission = record["admission"]
        if admission not in ("automatic", "closed"):
            raise ValueError(f"unknown admission: {admission!r}")
        return Profile(record["name"], admission, set(record["disabled"]), record["roster"])

    version = state["version"]
    if version == 2:
        return version, LIBRARY_PROFILE_ID, {
            LIBRARY_PROFILE_ID: Profile("Library Rotation", "automatic",
                                        set(state.get("disabled", [])), state.get("roster", {}))}
    if version == 3:
        active_id = str(uuid.UUID(state["activeID"]))
        records = state["profiles"]
        profiles = {str(uuid.UUID(p["id"])): profile(p) for p in records}
        if len(profiles) != len(records) or active_id not in profiles:
            raise ValueError("invalid profile IDs")
        return version, active_id, profiles
    raise ValueError(f"unsupported rotationState version: {version!r}")


# Exactly `<subsystem>.<hardware UUID>.plist` and nothing else. A bare
# `{SUBSYSTEM}.*.plist` glob also matches the scratch domains tests leave behind
# — com.hergenroeder.lerping.uitest.<UUID>.plist and friends — and this file
# then judges the rotation against a 42-byte stub. Today it survives that only
# because sorted() happens to put a UUID starting with a digit ahead of
# "eureka" and "uitest"; a machine whose UUID began with a letter would read the
# wrong file and either crash or pass against nothing.
UUID_SEGMENT = re.compile(r"^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$", re.I)


def rotation():
    """Read the one persisted record. Never query a defaults cache or write it."""
    hits = sorted(p for p in BYHOST.glob(f"{SUBSYSTEM}.*.plist")
                  if UUID_SEGMENT.match(p.name[len(SUBSYSTEM) + 1:-len(".plist")]))
    if not hits:
        raise ValueError(f"no {SUBSYSTEM} ByHost plist under {BYHOST}")
    with hits[0].open("rb") as handle:
        plist = plistlib.load(handle)

    state = plist.get("rotationState")
    if not state:
        raise ValueError(f"{hits[0]} has no rotationState — nothing has ever been saved")

    stale = [k for k in ("enabledEntries", "knownEntries",
                         "enabledShaders", "knownShaders") if k in plist]
    return parse_state(state), hits[0], stale


# The saver's host process. The predicate has to name it: LerpPlayground logs
# to the same subsystem and category, and its editor deliberately shows every
# look there is — `make playground` ends by opening it, so without this filter a
# normal deploy reports the shader you were last editing as a rotation
# violation. A check that cries wolf on a routine deploy is the next check
# everyone learns to ignore.
SAVER_PROCESS = "legacyScreenSaver"


def played(days):
    """Every look a real saver session put on screen, newest last."""
    out = subprocess.run(
        [LOG, "show", "--last", f"{days}d",
         "--predicate",
         f'subsystem == "{SUBSYSTEM}" AND process == "{SAVER_PROCESS}"',
         "--style", "compact"],
        capture_output=True, text=True, check=True).stdout
    return [pick for line in out.splitlines() if (pick := parse_play(line)) is not None]


def parse_play(line):
    m = PLAYING.search(line)
    if m is None:
        return None
    # Search only after the pick's closing parenthesis. Preset and playlist
    # names can contain spaces or the literal text “profile=”.
    tag = PROFILE_TAG.match(line[m.end():])
    return m[1], tag[1].lower() if tag else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    args = ap.parse_args()

    try:
        (version, active_id, profiles), source, stale = rotation()
        looks = played(args.days)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"Cannot judge rotation: {error}", file=sys.stderr)
        return 2

    active = profiles[active_id]
    print(f"rotation: {source} (v{version})")
    print(f"          active: {active.name} ({active_id}, {active.admission})")
    if stale:
        print(f"  WARNING: legacy keys still present: {', '.join(stale)}")
        print("           they are no longer written; the next save deletes them.")

    # Compare each tagged session with its own saved profile, not whichever is
    # active today. A deleted profile or a pre-v3 untagged session cannot be
    # attributed; report missing evidence rather than guessing. As before, the
    # plist describes today's choices, not a history of edits to a profile.
    seen, bad, skipped = {}, set(), 0
    for look, profile_id in looks:
        if profile_id is None and version == 2:
            profile_id = LIBRARY_PROFILE_ID
        if profile_id not in profiles:
            skipped += 1
            continue
        pick = (profile_id, look)
        seen[pick] = seen.get(pick, 0) + 1
        if profiles[profile_id].excludes(look):
            bad.add(pick)

    if skipped:
        print(f"  Skipped {skipped} play(s) without a matching saved playlist ID.")
    if not seen:
        print(f"\nNo attributable screensaver plays in the last {args.days} days. Nothing to judge.")
        return 2

    print(f"\n{sum(seen.values())} plays over {args.days}d, {len(seen)} distinct playlist/look pairs:")
    for profile_id, look in sorted(seen):
        pick = (profile_id, look)
        mark = "PLAYED WHILE SWITCHED OFF OR OUTSIDE ROSTER" if pick in bad else ""
        print(f"  {seen[pick]:3d}x  {look}  [{profiles[profile_id].name}, {profile_id}]  {mark}")

    if bad:
        print(f"\nFAIL: {len(bad)} out-of-rotation playlist/look pair(s) reached the screen.")
        return 1

    print("\nOK: every attributable look was in its saved playlist.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
