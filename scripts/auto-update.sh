#!/bin/bash
# Lerping@Home auto-updater.
#
# Once a day — via the LaunchAgent installed by `make install-auto-update` —
# this compares the installed saver's LerpBuild stamp against origin/main on
# GitHub. When GitHub is ahead, it fast-forward pulls this checkout and runs
# `make saver`: the same build-install-verify the Makefile documents.
#
# It never builds a dirty tree and never merges over local work. A checkout
# with uncommitted changes, or one that has diverged from origin/main, is left
# alone and the skip is logged. The playground is deliberately not touched:
# replacing it unattended could discard unsaved editor state (see AGENTS.md).
set -u

LOG="$HOME/Library/Logs/LerpingAutoUpdate.log"
exec >>"$LOG" 2>&1

say() { echo "$(date '+%F %T') $*"; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || { say "cannot cd to $REPO; skipping"; exit 0; }

LOCK="$HOME/Library/Caches/com.hergenroeder.lerping.autoupdate.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    say "another update is already running; skipping"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

REMOTE="$(git ls-remote https://github.com/codyhxyz/lerping-at-home.git refs/heads/main 2>/dev/null | awk '{print $1}')"
if [ -z "$REMOTE" ]; then
    say "remote unreachable (offline?); skipping"
    exit 0
fi

INSTALLED="$(plutil -extract LerpBuild raw "$HOME/Library/Screen Savers/Lerping@Home.saver/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$INSTALLED" ]; then
    case "$REMOTE" in
        "$INSTALLED"*) say "up to date ($INSTALLED)"; exit 0 ;;
    esac
else
    say "no installed saver found; installing $REMOTE"
fi

git fetch --quiet origin main 2>/dev/null || { say "fetch failed; skipping"; exit 0; }
if [ -n "$(git status --porcelain)" ]; then
    say "checkout has uncommitted changes; skipping"
    exit 0
fi
if ! git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    say "checkout has diverged from origin/main; skipping"
    exit 0
fi
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    git merge --ff-only --quiet origin/main || { say "fast-forward failed; skipping"; exit 0; }
    say "pulled $(git rev-parse --short=8 HEAD)"
fi

say "running make saver"
if make saver; then
    say "saver now at $(git rev-parse --short=8 HEAD)"
else
    say "make saver FAILED"
    exit 1
fi
