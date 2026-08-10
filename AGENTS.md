# Deployment is part of done

This is a locally used app, not a library whose job ends at compilation.

- Saver changes: run `make saver`. `make saver-build` is compile-only evidence and cannot complete the task.
- Playground changes: run `make playground`. `make playground-build` is compile-only evidence and cannot complete the task.
- Never launch or register `build/LerpPlayground.staging.app`.
- Never replace or kill a playground that may contain unsaved edits. If deployment is cancelled or refuses a pre-migration process, report that the task is not deployed; do not claim completion.
- Before claiming completion, verify the installed bundle signature and that no stale `legacyScreenSaver` process remains.
