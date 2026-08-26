# Deployment is part of done

This is a locally used app, not a library whose job ends at compilation.

- Saver changes: run `make saver`. `make saver-build` is compile-only evidence and cannot complete the task.
- Playground changes: run `make playground`. `make playground-build` is compile-only evidence and cannot complete the task.
- Never launch or register `build/LerpPlayground.staging.app`.
- Never replace or kill a playground that may contain unsaved edits. If deployment is cancelled or refuses a pre-migration process, report that the task is not deployed; do not claim completion.
- Before claiming completion, verify the installed bundle signature and that no stale `legacyScreenSaver` process remains.

# We test in prod

Finish the job. Build, push, deploy — every time, without being asked again.

- **Always push when the work is done.** Committing is not the finish line and neither is a clean `git status`. `git push` is.
- **"Needs a human to see it" does not count as unfinished work.** Do not hold a change back for review, for a screenshot, for confirmation that it looks right, or for a convenient moment. Ship it and say what you shipped. If it is wrong, the next commit fixes it.
- **Do not ask permission to deploy.** This file is the permission. Asking "shall I push?" at the end of a finished task is the thing this section exists to stop.
- The one exception is destructive or unrecoverable action on the user's *data* — their saved rotation, their custom shaders, their checkout. Deploying code is not that. Overwriting a selection you cannot reconstruct is.

## What "done" means here

The change is deployed with `make saver` / `make playground`, and the work is
pushed.

There is no `make doctor` any more. It hashed the source tree, hashed the
installed bundle, and printed "up to date" when they matched — and it printed
exactly that while the bug it was built to catch was reproducing, three times.
"Do these bytes match those bytes" was never the question in doubt. Having a
green stale-check made staleness *look* answered, so the question that mattered
— which look did the saver put on screen, and was it one the user had switched
off — went unasked.

So the stale-check is gone rather than improved. `make saver` takes about eight
seconds and is a shorter path to certainty than any check that the last one was
still good. Run it; do not ask whether you need to.

- The installed bundle stamps `LerpBuild` (`git describe --always --dirty`) into
  its `Info.plist`, and the running saver logs it: look for `build=` on the
  `init` line. That is a label for reading the log, not a verdict. `--dirty` is
  what keeps it honest about uncommitted edits.
- `CFBundleVersion` still cannot answer anything: it is a wall-clock stamp, so
  it changes on a rebuild that changed nothing and matches nothing in the tree.

## Verify against the real host, not a harness

A harness that both sets the state and checks it agrees with itself no matter
what the screensaver does. That is how three separate "this is fixed" claims got
made about a rotation bug whose actual cause was in the desktop-picture code.

`make verify-rotation` is the check that replaced the doctor, and it is built so
that it cannot agree with itself. It reads the rotation from the user's ByHost
plist and reads what actually played from the unified log — written by the saver
during real sessions on a real screen — and fails if anything switched off
reached the screen. It sets nothing, so there is no fixture for it to be right
about. When there are no sessions to judge it says so and exits 2 rather than
passing.

- `make verify-rotation`, or `make verify-rotation DAYS=30`.
- Read the log directly with `/usr/bin/log show --last 7d --predicate
  'subsystem == "com.hergenroeder.lerping"' --style compact`. Use the absolute
  path: `log` is shadowed by a zsh function that errors with "too many
  arguments".
- Never write the production defaults domain from a test. Set
  `LERP_DEFAULTS_MODULE` to a scratch domain. `LerpRotation.write` refuses the
  production domain from any process with no `Bundle.main.bundleIdentifier`,
  which is every throwaway `swiftc` binary and neither of the two real hosts —
  see `Sources/LerpCore/LerpDefaults.swift` for why that replaced an allowlist
  of writer *names*.

## Where the rotation lives

One representation, one writer, one store. Keep it that way; every past bug in
this area came from having more than one of any of them.

- **One representation.** The `rotationState` record in the ByHost plist, which
  stores the looks that are *off*. The old `enabledEntries` / `knownEntries` /
  `enabledShaders` / `knownShaders` keys are read once by a domain that has no
  `rotationState`, deleted on the next write, and never written again.
- **One writer.** LerpPlayground. The saver's Options… sheet shows the gallery
  read-only, because it runs sandboxed inside `legacyScreenSaver` and can only
  write Apple's container — not the file the saver reads.
- **One store.** `~/Library/Preferences/ByHost/com.hergenroeder.lerping.<hardware
  UUID>.plist`. The saver reads it by path rather than through
  `ScreenSaverDefaults`, so there is no precedence order and no `cfprefsd` cache
  between the bytes the playground wrote and the bytes the saver parses.

The screensaver does not set the desktop picture, and should not be given the
job back without reading the comment where it used to live in
`Sources/Saver/LerpSaverView.swift`. A sandboxed, ephemeral guest making
permanent global mutations is what pinned this user's lock screen to a shader
they had removed, across 946 spaces, for three weeks.
