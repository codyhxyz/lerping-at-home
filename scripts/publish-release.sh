#!/bin/bash
# Lerping@Home release publisher — the "ship it" half of the auto-updater.
#
# Usage: scripts/publish-release.sh [tag]   (default: vYYYY.MM.DD.HHMM)
#
# Deploys the saver locally with `make saver`, then builds the public release
# with `make release`: both bundles signed with Developer ID and hardened
# runtime, the PKG signed with Developer ID Installer, and the PKG and DMG
# notarized and stapled. It uploads three assets to a GitHub Release:
#
#   LerpingAtHome-saver-<tag>.zip   the notarized, stapled saver the playground's
#                                   updater (scripts/release-update.sh) installs;
#                                   its LerpBuild stamp must equal the tag
#   LerpingAtHome-<version>-arm64.dmg (+ .sha256)  the installer for people
#
# <version> is the tag without the leading v (the PKG needs a numeric version).
#
# Signing comes from the keychain. Override any of these if it guesses wrong:
#   APP_SIGN_IDENTITY        "Developer ID Application: …"
#   INSTALLER_SIGN_IDENTITY  "Developer ID Installer: …"
#   NOTARY_PROFILE           notarytool keychain profile (default: lerping)
# Create the profile once from an App Store Connect API key:
#   xcrun notarytool store-credentials lerping --key AuthKey_X.p8 --key-id X --issuer Y
#
# There is no unsigned mode. An unsigned public DMG is what this used to ship,
# with a note telling people to right-click → Open; Gatekeeper on current macOS
# no longer offers that way out.
#
# Requires a clean checkout (releases what you see), the Xcode command-line
# tools, and the `gh` CLI authenticated to codyhxyz/lerping-at-home.
set -euo pipefail

[ "$(uname -s)" = Darwin ] || { echo "publish-release.sh is macOS only." >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "the gh CLI is required (https://cli.github.com)." >&2; exit 1; }

TAG="${1:-v$(date '+%Y.%m.%d.%H%M')}"
case "$TAG" in
    v*) ;;
    *) echo "tag should look like v2026.09.16.1830 (got: $TAG)" >&2; exit 1 ;;
esac
VERSION="${TAG#v}" # the PKG requires a numeric-looking version, no v prefix

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
[ -n "$(git status --porcelain)" ] && { echo "checkout is dirty; commit or stash first." >&2; exit 1; }

# First quoted name of a valid identity matching $2, from `security find-identity`.
identity() {
    security find-identity -v $1 | sed -n "s/.*\"\\($2: [^\"]*\\)\".*/\\1/p" | head -n 1
}
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-$(identity '-p codesigning' 'Developer ID Application')}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-$(identity '-p basic' 'Developer ID Installer')}"
NOTARY_PROFILE="${NOTARY_PROFILE:-lerping}"

missing=0
[ -n "$APP_SIGN_IDENTITY" ] || { echo "no Developer ID Application identity in the keychain." >&2; missing=1; }
[ -n "$INSTALLER_SIGN_IDENTITY" ] || { echo "no Developer ID Installer identity in the keychain." >&2; missing=1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "notarytool profile '$NOTARY_PROFILE' is missing or invalid." >&2; missing=1; }
if [ "$missing" = 1 ]; then
    echo "Developer ID certificates can only be made by the Account Holder: Xcode → Settings →" >&2
    echo "Accounts → Manage Certificates → + → Developer ID Application / Developer ID Installer." >&2
    exit 1
fi
echo "==> signing as $APP_SIGN_IDENTITY"
echo "    packaging as $INSTALLER_SIGN_IDENTITY"
echo "    notarizing with profile $NOTARY_PROFILE"

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "release $TAG already exists; pass a different tag." >&2
    exit 1
fi

echo "==> deploying the saver locally as $TAG"
make saver LERP_BUILD="$TAG"

echo "==> building, signing, and notarizing the release"
make release LERP_BUILD="$TAG" RELEASE_VERSION="$VERSION" \
    APP_SIGN_IDENTITY="$APP_SIGN_IDENTITY" \
    INSTALLER_SIGN_IDENTITY="$INSTALLER_SIGN_IDENTITY" \
    NOTARY_PROFILE="$NOTARY_PROFILE"
DMG="build/release/LerpingAtHome-$VERSION-arm64.dmg"
[ -f "$DMG" ] && [ -f "$DMG.sha256" ] || { echo "make release did not produce $DMG and its checksum" >&2; exit 1; }

# The updater zip is the saver staged inside the PKG: Developer ID signed, with
# the same stamp. Notarize it on its own and staple the ticket to the bundle,
# so it passes Gatekeeper offline wherever the updater puts it.
STAGED="build/release/saver-root/Library/Screen Savers/Lerping@Home.saver"
[ "$(plutil -extract LerpBuild raw "$STAGED/Contents/Info.plist")" = "$TAG" ] \
    || { echo "release saver stamp is not $TAG" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ASSET="LerpingAtHome-saver-$TAG.zip"
ditto "$STAGED" "$WORK/Lerping@Home.saver"
ditto -c -k --keepParent "$WORK/Lerping@Home.saver" "$WORK/notarize.zip"
echo "==> notarizing the updater saver"
xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$WORK/Lerping@Home.saver"
xcrun stapler validate "$WORK/Lerping@Home.saver"
(cd "$WORK" && ditto -c -k --keepParent "Lerping@Home.saver" "$ASSET")

# The zip must round-trip to the same signed, stapled, correctly stamped bundle.
mkdir "$WORK/check"
ditto -x -k "$WORK/$ASSET" "$WORK/check"
codesign --verify --deep --strict "$WORK/check/Lerping@Home.saver"
xcrun stapler validate "$WORK/check/Lerping@Home.saver"
[ "$(plutil -extract LerpBuild raw "$WORK/check/Lerping@Home.saver/Contents/Info.plist")" = "$TAG" ]

echo "==> publishing release $TAG"
gh release create "$TAG" \
    --title "Lerping@Home $TAG" \
    --notes "Download LerpingAtHome-$VERSION-arm64.dmg, open it, and double-click **Install Lerping@Home**. Signed with Developer ID and notarized by Apple. The .sha256 file is its checksum. LerpingAtHome-saver-$TAG.zip feeds the playground's automatic updater." \
    "$WORK/$ASSET" \
    "$DMG" \
    "$DMG.sha256"

cat <<EOF

Published $TAG with the updater zip and the notarized installer DMG. Machines
with automatic updates will pick up the saver on their next check (launch, or
within four hours). The playground itself is not updated by the release;
install a new playground from the DMG or make install-playground.
EOF
