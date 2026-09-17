#!/bin/bash
# Lerping@Home release updater.
#
# Checks GitHub Releases for a newer saver build. When the latest release is
# newer than the installed saver's LerpBuild stamp, it downloads the release
# zip, verifies it (code signature, and the stamp inside the bundle matches
# the release tag), and installs it to ~/Library/Screen Savers.
#
# This is the standard shape: prebuilt, signed artifacts downloaded from
# releases — no git checkout update, no compiler on the receiving end.
#
# Contract with the playground (see Sources/Playground/UpdateMenu.swift):
# stdout carries exactly one result line; the log gets everything else.
#   LERP_RESULT=up-to-date BUILD=<tag>
#   LERP_RESULT=updated    BUILD=<tag>
#   LERP_RESULT=skipped    REASON=<why>
#   LERP_RESULT=failed     REASON=<why>
# Progress goes to the log file, and to stderr when run in a terminal.
set -u

REPO_OWNER="codyhxyz"
REPO_NAME="lerping-at-home"
BUNDLE_NAME="Lerping@Home.saver"
USER_SAVER_DIR="$HOME/Library/Screen Savers"
LOG="$HOME/Library/Logs/LerpingAutoUpdate.log"
LOCK="$HOME/Library/Caches/com.hergenroeder.lerping.autoupdate.lock"

exec 3>>"$LOG"
say() { # log line, timestamped; also to stderr in a terminal
    echo "$(date '+%F %T') $*" >&3
    [ -t 2 ] && echo "$*" >&2 || true
}
result() { # the one stdout line the playground parses
    local line="LERP_RESULT=$1"
    shift
    for kv in "$@"; do line="$line $kv"; done
    echo "$line"
}

if ! mkdir "$LOCK" 2>/dev/null; then
    say "another update is already running; skipping"
    result skipped REASON="another update already running"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

INSTALLED=""
for dir in "$USER_SAVER_DIR" "/Library/Screen Savers"; do
    INSTALLED="$(plutil -extract LerpBuild raw "$dir/$BUNDLE_NAME/Contents/Info.plist" 2>/dev/null || true)"
    [ -n "$INSTALLED" ] && break
done

API="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
RELEASE_JSON="$(curl -sSL --max-time 30 "$API" 2>/dev/null || true)"
# Prints the tag, NONE when no release exists yet, or ERROR when the API
# could not be reached or answered with something unusable.
TAG="$(printf '%s' "$RELEASE_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERROR")
else:
    print(d.get("tag_name") or ("NONE" if d.get("message") else "ERROR"))
' 2>/dev/null || echo ERROR)"
if [ "$TAG" = "ERROR" ]; then
    say "could not reach the GitHub releases API (offline?); skipping"
    result failed REASON="could not reach GitHub"
    exit 0
fi
if [ "$TAG" = "NONE" ]; then
    say "no releases published yet; nothing to download"
    result skipped REASON="no releases published yet"
    exit 0
fi

if [ -n "$INSTALLED" ] && [ "$INSTALLED" = "$TAG" ]; then
    say "up to date ($INSTALLED)"
    result up-to-date BUILD="$INSTALLED"
    exit 0
fi
if [ -z "$INSTALLED" ]; then
    say "no installed saver found; installing $TAG"
else
    say "installed is $INSTALLED, latest release is $TAG; updating"
fi

ASSET="LerpingAtHome-saver-$TAG.zip"
URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$TAG/$ASSET"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; rmdir "$LOCK" 2>/dev/null' EXIT

say "downloading $ASSET"
if ! curl -fsSL --max-time 300 -o "$WORK/$ASSET" "$URL" 2>/dev/null; then
    say "download failed; skipping"
    result failed REASON="download failed"
    exit 0
fi
unzip -q -o "$WORK/$ASSET" -d "$WORK/unzipped" 2>/dev/null || {
    say "could not unzip the release; skipping"
    result failed REASON="could not unzip the release"
    exit 0
}
BUNDLE="$(find "$WORK/unzipped" -maxdepth 2 -name "$BUNDLE_NAME" -type d | head -1)"
if [ -z "$BUNDLE" ]; then
    say "release did not contain $BUNDLE_NAME; skipping"
    result failed REASON="release is missing the saver bundle"
    exit 0
fi
if ! codesign --verify --deep "$BUNDLE" 2>/dev/null; then
    say "release bundle failed signature verification; skipping"
    result failed REASON="signature verification failed"
    exit 0
fi
STAMP="$(plutil -extract LerpBuild raw "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
if [ "$STAMP" != "$TAG" ]; then
    say "release stamp ($STAMP) does not match tag ($TAG); skipping"
    result failed REASON="build stamp mismatch"
    exit 0
fi

# A loaded bundle stays mapped after its files are replaced; kill the
# disposable Apple host before the swap so no old code survives.
pkill -9 -x legacyScreenSaver 2>/dev/null || true
mkdir -p "$USER_SAVER_DIR"
rm -rf "$USER_SAVER_DIR/$BUNDLE_NAME"
cp -R "$BUNDLE" "$USER_SAVER_DIR/$BUNDLE_NAME"
pkill -9 -x legacyScreenSaver 2>/dev/null || true
if ! codesign --verify --deep "$USER_SAVER_DIR/$BUNDLE_NAME" 2>/dev/null; then
    say "installed bundle failed verification after copying"
    result failed REASON="installed bundle failed verification"
    exit 0
fi

say "saver now at $TAG"
result updated BUILD="$TAG"
