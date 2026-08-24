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

`make doctor` exits zero, and the work is pushed.

- `make doctor` compares a `LerpSourceRevision` stamp inside each installed bundle against a hash of the sources that produced it, for both the saver and the playground. It catches uncommitted edits, and it catches custom shaders in `~/Library/Application Support/Lerping/Shaders` that get baked into the installed saver.
- `CFBundleVersion` cannot answer this. It is a wall-clock stamp: it changes on a rebuild that changed nothing, and matches nothing in the tree. A green build, a passing harness and `codesign --verify` were all true of the wrong binary for three rounds of "the rotation is fixed now".
- The running saver logs its stamp: `log show --predicate 'subsystem == "com.hergenroeder.lerping"'`, look for `build=` on the init line. That is the only thing that proves which code actually ran.

## Verify against the real host, not a harness

A harness that both sets the state and checks it agrees with itself no matter what the screensaver does. That is how three separate "this is fixed" claims got made about a rotation that had never worked.

- Prove behaviour from the unified log of a real run, or from a probe that loads the **installed** bundle.
- Never write the production defaults domain from a test. `LerpRotation.write` now refuses any writer outside `LerpDefaults.trustedWriters`; set `LERP_DEFAULTS_MODULE` to a scratch domain instead. See `Sources/LerpCore/LerpDefaults.swift`.
