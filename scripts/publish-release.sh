#!/bin/bash
# Lerping@Home release publisher — the "ship it" half of the auto-updater.
#
# Usage: scripts/publish-release.sh [tag]   (default: vYYYY.MM.DD.HHMM)
#
# Builds the screen saver from this checkout with make, stamps it with the
# tag, zips the installed bundle, and uploads it as a GitHub Release asset
# named LerpingAtHome-saver-<tag>.zip. The playground's updater
# (scripts/release-update.sh) picks that asset up: the release tag is the
# version, and the bundle's LerpBuild stamp must equal it.
#
# Requires a clean checkout (releases what you see), the Xcode command-line
# tools (via make), and the `gh` CLI authenticated to codyhxyz/lerping-at-home.
set -euo pipefail

[ "$(uname -s)" = Darwin ] || { echo "publish-release.sh is macOS only." >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "the gh CLI is required (https://cli.github.com)." >&2; exit 1; }

TAG="${1:-v$(date '+%Y.%m.%d.%H%M')}"
case "$TAG" in
    v*) ;;
    *) echo "tag should look like v2026.09.16.1830 (got: $TAG)" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
[ -n "$(git status --porcelain)" ] && { echo "checkout is dirty; commit or stash first." >&2; exit 1; }

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "release $TAG already exists; pass a different tag." >&2
    exit 1
fi

echo "==> building the saver as $TAG"
make saver LERP_BUILD="$TAG"

BUNDLE="$HOME/Library/Screen Savers/Lerping@Home.saver"
STAMP="$(plutil -extract LerpBuild raw "$BUNDLE/Contents/Info.plist")"
[ "$STAMP" = "$TAG" ] || { echo "built bundle says $STAMP, expected $TAG" >&2; exit 1; }
codesign --verify --deep "$BUNDLE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ASSET="LerpingAtHome-saver-$TAG.zip"
(cd "$HOME/Library/Screen Savers" && zip -qr "$WORK/$ASSET" "Lerping@Home.saver")
# Paranoia: the zip must round-trip to the same signed, correctly stamped bundle.
rm -rf "$WORK/check" && mkdir "$WORK/check"
unzip -q "$WORK/$ASSET" -d "$WORK/check"
codesign --verify --deep "$WORK/check/Lerping@Home.saver"
[ "$(plutil -extract LerpBuild raw "$WORK/check/Lerping@Home.saver/Contents/Info.plist")" = "$TAG" ]

echo "==> publishing release $TAG"
gh release create "$TAG" \
    --title "Lerping@Home saver $TAG" \
    --notes "Automated saver build for the in-app updater." \
    "$WORK/$ASSET"

cat <<EOF

Published $TAG. Machines with automatic updates will pick it up on their next
check (launch, or within four hours). The playground itself is not updated by
the release; install a new playground from the DMG or make install-playground.
EOF
