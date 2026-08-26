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
from pathlib import Path

SUBSYSTEM = "com.hergenroeder.lerping"
BYHOST = Path.home() / "Library/Preferences/ByHost"
# `log` is shadowed by a zsh function on this machine; the absolute path is not
# a style preference, it is the difference between output and "too many
# arguments".
LOG = "/usr/bin/log"
PLAYING = re.compile(r"playing (.+?) \((\d+) in rotation of (\d+) discovered\)")


def rotation():
    """(disabled set, source path). The v2 record is the only representation."""
    hits = sorted(BYHOST.glob(f"{SUBSYSTEM}.*.plist"))
    if not hits:
        sys.exit(f"no {SUBSYSTEM} ByHost plist under {BYHOST}")
    with hits[0].open("rb") as handle:
        plist = plistlib.load(handle)

    state = plist.get("rotationState")
    if not state:
        sys.exit(f"{hits[0]} has no rotationState — nothing has ever been saved")

    stale = [k for k in ("enabledEntries", "knownEntries",
                         "enabledShaders", "knownShaders") if k in plist]
    return set(state.get("disabled", [])), hits[0], stale


def played(days):
    """Every look a real saver session put on screen, newest last."""
    out = subprocess.run(
        [LOG, "show", "--last", f"{days}d",
         "--predicate", f'subsystem == "{SUBSYSTEM}"', "--style", "compact"],
        capture_output=True, text=True, check=True).stdout
    return [(m.group(1), int(m.group(2)), int(m.group(3)))
            for m in (PLAYING.search(line) for line in out.splitlines()) if m]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    args = ap.parse_args()

    disabled, source, stale = rotation()
    looks = played(args.days)

    print(f"rotation: {source}")
    print(f"          {len(disabled)} looks switched off")
    if stale:
        # Not fatal, but it is the shape of the bug this file exists for: a
        # second representation of the rotation that something could still read.
        print(f"  WARNING: legacy keys still present: {', '.join(stale)}")
        print("           they are no longer written; the next save deletes them.")

    if not looks:
        print(f"\nno screensaver sessions in the last {args.days} days.")
        print("Nothing to judge. Let the saver run, or raise --days.")
        return 2

    seen, bad = {}, []
    for look, _, _ in looks:
        seen[look] = seen.get(look, 0) + 1
        if look in disabled and look not in bad:
            bad.append(look)

    print(f"\n{len(looks)} plays over {args.days}d, {len(seen)} distinct looks:")
    for look in sorted(seen):
        mark = "PLAYED WHILE SWITCHED OFF" if look in disabled else ""
        print(f"  {seen[look]:3d}x  {look}  {mark}")

    if bad:
        print(f"\nFAIL: {len(bad)} switched-off look(s) reached the screen:")
        for look in bad:
            print(f"  {look}")
        return 1

    print("\nOK: every look that played was in the rotation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
