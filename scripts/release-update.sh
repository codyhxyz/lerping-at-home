#!/bin/bash
# Lerping@Home release updater.
#
# Checks GitHub Releases for a newer saver build. When the latest release is
# newer than the installed saver's LerpBuild stamp, it downloads the release
# ZIP and checks it against the installed release's Developer ID identity and
# the release tag. Replaces that exact installed copy, never a shadow copy.
# Install the signed DMG first to establish trust. LERP_EXPECTED_TEAM_ID may
# further constrain which installed Developer ID signer is trusted.
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
SYSTEM_SAVER_DIR="/Library/Screen Savers"
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

# A lock older than any run can last (one 300 s download plus the API call)
# belongs to a run that died without its EXIT trap — SIGKILL, power loss — and
# would otherwise make every later check "already running", forever.
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    say "removing a stale update lock left by a run that never finished"
    rmdir "$LOCK" 2>/dev/null || true
fi
if ! mkdir "$LOCK" 2>/dev/null; then
    say "another update is already running; skipping"
    result skipped REASON="another update already running"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Trust the local installation, not certificate text downloaded with the ZIP.
# Apple Developer ID CA and Application leaf extensions exclude ad-hoc,
# Developer ID Installer, Apple Development, and App Store Distribution.
REQUIREMENT='anchor apple generic and identifier "com.hergenroeder.lerping" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
verified_identity() {
    local bundle="$1" expected_team="$2" requirement="$REQUIREMENT" info team signer
    [ -d "$bundle" ] && [ ! -L "$bundle" ] || return 1
    if [ -n "$expected_team" ]; then
        requirement="$requirement and certificate leaf[subject.OU] = \"$expected_team\""
    fi
    codesign --verify --deep --strict -R="$requirement" "$bundle" >&3 2>&1 || return 1
    info="$(codesign -d --verbose=4 "$bundle" 2>&1)" || return 1
    team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p')"
    signer="$(printf '%s\n' "$info" | sed -n '/^Authority=/{s/^Authority=//;p;q;}')"
    [[ "$team" =~ ^[A-Z0-9]{10}$ && "$signer" == 'Developer ID Application: '* ]] || return 1
    [ -z "$expected_team" ] || [ "$team" = "$expected_team" ] || return 1
    printf '%s\n%s\n' "$team" "$signer"
}

exists() { [ -e "$1" ] || [ -L "$1" ]; }
is_release_tag() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ &&
       "$1" != *-dirty && ! "$1" =~ -[0-9]+-g[0-9a-f]+$ ]]
}
SYSTEM_BUNDLE="$SYSTEM_SAVER_DIR/$BUNDLE_NAME"
USER_BUNDLE="$USER_SAVER_DIR/$BUNDLE_NAME"
if exists "$SYSTEM_BUNDLE" && exists "$USER_BUNDLE"; then
    say "both system and user saver copies exist; cannot choose a canonical installation"
    result skipped REASON="multiple saver copies; keep one installation from the signed DMG"
    exit 0
elif exists "$SYSTEM_BUNDLE"; then
    SAVER_DIR="$SYSTEM_SAVER_DIR"
    INSTALLED_BUNDLE="$SYSTEM_BUNDLE"
else
    SAVER_DIR="$USER_SAVER_DIR"
    INSTALLED_BUNDLE="$USER_BUNDLE"
fi

EXPECTED_TEAM="${LERP_EXPECTED_TEAM_ID:-}"
if [ "${LERP_EXPECTED_TEAM_ID+x}" ] && [[ ! "$EXPECTED_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
    say "LERP_EXPECTED_TEAM_ID is not a valid Developer ID team identifier"
    result failed REASON="invalid LERP_EXPECTED_TEAM_ID"
    exit 0
fi
INSTALLED="$(plutil -extract LerpBuild raw "$INSTALLED_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
# Only a release replaces a release. Local `make saver` stamps and ad-hoc
# signatures are not an update trust anchor, even when they use a release tag.
if ! is_release_tag "$INSTALLED" ||
   ! TRUSTED_IDENTITY="$(verified_identity "$INSTALLED_BUNDLE" "$EXPECTED_TEAM")"; then
    say "no matching Developer ID release installed at $INSTALLED_BUNDLE; install the signed DMG first"
    result skipped REASON="no trusted saver release; install from the signed DMG"
    exit 0
fi
EXPECTED_TEAM="${TRUSTED_IDENTITY%%$'\n'*}"

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

if ! is_release_tag "$TAG"; then
    say "invalid release tag ($TAG); skipping"
    result failed REASON="invalid release tag"
    exit 0
fi

if [ "$INSTALLED" = "$TAG" ]; then
    say "up to date ($INSTALLED)"
    result up-to-date BUILD="$INSTALLED"
    exit 0
fi
# The latest published release need not be newer than the installed one.
if [ "$(printf '%s\n%s\n' "$INSTALLED" "$TAG" | LC_ALL=C sort -V | tail -n 1)" = "$INSTALLED" ]; then
    say "installed $INSTALLED is newer than the latest release $TAG; leaving it alone"
    result up-to-date BUILD="$INSTALLED"
    exit 0
fi
if [ ! -w "$SAVER_DIR" ] || [ ! -x "$SAVER_DIR" ]; then
    say "cannot replace $INSTALLED_BUNDLE; install the newer signed DMG"
    result skipped REASON="canonical saver location is not writable; update with the signed DMG"
    exit 0
fi
say "installed is $INSTALLED, latest release is $TAG; updating $INSTALLED_BUNDLE"

ASSET="LerpingAtHome-saver-$TAG.zip"
URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$TAG/$ASSET"
WORK="$(mktemp -d)" || { result failed REASON="could not create download directory"; exit 0; }
SWAP=""
cleanup() {
    rm -rf "$WORK"
    if [ -n "$SWAP" ]; then
        # Preserve the old copy if a filesystem error prevented rollback.
        if exists "$SWAP/previous"; then
            if ! exists "$INSTALLED_BUNDLE"; then
                mv "$SWAP/previous" "$INSTALLED_BUNDLE" >&3 2>&1 || true
            fi
        fi
        if exists "$SWAP/previous"; then
            say "previous saver preserved at $SWAP/previous"
        else
            rm -rf "$SWAP"
        fi
    fi
    rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

say "downloading $ASSET"
if ! curl -fsSL --max-time 300 -o "$WORK/$ASSET" "$URL" 2>/dev/null; then
    say "download failed; skipping"
    result failed REASON="download failed"
    exit 0
fi
ditto -x -k "$WORK/$ASSET" "$WORK/unzipped" >&3 2>&1 || {
    say "could not unzip the release; skipping"
    result failed REASON="could not unzip the release"
    exit 0
}
BUNDLE="$WORK/unzipped/$BUNDLE_NAME"
if [ ! -d "$BUNDLE" ] || [ -L "$BUNDLE" ]; then
    say "release did not contain $BUNDLE_NAME; skipping"
    result failed REASON="release is missing the saver bundle"
    exit 0
fi
matches_release() {
    local bundle="$1" stamp="$2" identity
    identity="$(verified_identity "$bundle" "$EXPECTED_TEAM")" &&
        [ "$identity" = "$TRUSTED_IDENTITY" ] &&
        [ "$(plutil -extract LerpBuild raw "$bundle/Contents/Info.plist" 2>/dev/null)" = "$stamp" ]
}
if ! matches_release "$BUNDLE" "$TAG"; then
    say "downloaded release failed signer, bundle ID, or build stamp verification"
    result failed REASON="downloaded release failed identity or build verification"
    exit 0
fi

# Copy on the target volume and verify before moving either installed bundle.
# A failed copy or rename must not destroy the old installation.
if ! SWAP="$(mktemp -d "$SAVER_DIR/.lerping-update.XXXXXX")" ||
   ! ditto "$BUNDLE" "$SWAP/$BUNDLE_NAME" >&3 2>&1 ||
   ! matches_release "$SWAP/$BUNDLE_NAME" "$TAG"; then
    say "could not stage and verify the replacement at $SAVER_DIR"
    result failed REASON="could not copy and verify the release"
    exit 0
fi
if ! matches_release "$INSTALLED_BUNDLE" "$INSTALLED" ||
   { exists "$SYSTEM_BUNDLE" && exists "$USER_BUNDLE"; }; then
    say "installed saver changed while preparing update; leaving it alone"
    result skipped REASON="installed saver changed during the update"
    exit 0
fi

# A loaded bundle stays mapped after it is replaced; stop the disposable host.
pkill -9 -x legacyScreenSaver 2>/dev/null || true
if ! mv "$INSTALLED_BUNDLE" "$SWAP/previous" >&3 2>&1 ||
   ! mv "$SWAP/$BUNDLE_NAME" "$INSTALLED_BUNDLE" >&3 2>&1; then
    say "could not swap the canonical saver; retaining the previous release"
    result failed REASON="could not replace the canonical saver"
    exit 0
fi
if ! matches_release "$INSTALLED_BUNDLE" "$TAG"; then
    mv "$INSTALLED_BUNDLE" "$SWAP/rejected" >&3 2>&1 || true
    say "installed bundle failed verification; retaining the previous release"
    result failed REASON="installed bundle failed verification"
    exit 0
fi
rm -rf "$SWAP/previous"
pkill -9 -x legacyScreenSaver 2>/dev/null || true

say "saver now at $TAG"
result updated BUILD="$TAG"
