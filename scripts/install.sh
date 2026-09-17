#!/bin/bash
# Lerping@Home installer — the fresh-machine path.
#
# Usage: scripts/install.sh [--with-playground|--without-playground]
#                           [--with-auto-update|--without-auto-update]
#                           [--repo-dir DIR]
#
# Without flags it asks. Checks the prerequisites (macOS 14+ on Apple Silicon,
# the Xcode command-line tools), uses this checkout — or clones one — and runs
# the same `make saver` / `make install-playground` targets the README
# documents. Non-interactive when every choice has a flag.
set -euo pipefail

PLAYGROUND=""
AUTOUPDATE=""
REPO_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --with-playground) PLAYGROUND=yes; shift ;;
        --without-playground) PLAYGROUND=no; shift ;;
        --with-auto-update) AUTOUPDATE=yes; shift ;;
        --without-auto-update) AUTOUPDATE=no; shift ;;
        --repo-dir) REPO_DIR="$2"; shift 2 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1 (see --help)" >&2; exit 1 ;;
    esac
done

ask() { # ask VAR "prompt" default
    local var="$1" prompt="$2" def="$3" ans
    if [ -t 0 ]; then
        read -r -p "$prompt [$def] " ans
        printf -v "$var" "%s" "${ans:-$def}"
    else
        printf -v "$var" "%s" "$def"
    fi
}

[ "$(uname -s)" = Darwin ] || { echo "This installer is macOS only." >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "Lerping@Home needs Apple Silicon." >&2; exit 1; }
if ! xcrun --show-sdk-path >/dev/null 2>&1; then
    echo "The Xcode command-line tools are missing."
    echo "Run: xcode-select --install"
    echo "then re-run this installer."
    exit 1
fi

HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "$REPO_DIR" ]; then
    if [ -d "$HERE/Sources/Shaders" ]; then
        REPO_DIR="$HERE"
    else
        REPO_DIR="$HOME/src/lerping-at-home"
    fi
fi
if [ ! -d "$REPO_DIR/Sources/Shaders" ]; then
    echo "Cloning into $REPO_DIR ..."
    git clone https://github.com/codyhxyz/lerping-at-home.git "$REPO_DIR"
fi
cd "$REPO_DIR"

echo "==> Installing the screen saver"
make saver

[ -n "$PLAYGROUND" ] || ask PLAYGROUND "Install the Shader Playground too? (yes/no)" "yes"
if [ "$PLAYGROUND" = "yes" ]; then
    echo "==> Installing the playground"
    make install-playground
fi

[ -n "$AUTOUPDATE" ] || ask AUTOUPDATE "Enable automatic update checks? (yes/no)" "yes"
if [ "$AUTOUPDATE" != "yes" ]; then
    # The playground checks for updates itself and the toggle defaults to on;
    # this records the opt-out before the first launch.
    defaults write com.hergenroeder.lerping.playground.installed LerpAutoUpdateEnabled -bool false
    echo "Automatic update checks disabled (toggle them back on from the playground's menu-bar item)."
fi

# Retire the LaunchAgent from the brief 2026-09-16 daemon experiment: updates
# are in-app now. No-op when it was never enrolled.
launchctl bootout "gui/$(id -u)/com.hergenroeder.lerping.autoupdate" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.hergenroeder.lerping.autoupdate.plist"

cat <<'EOF'

Installed. Next steps:
- Select "Lerping@Home" in System Settings > Screen Saver.
- Update log: ~/Library/Logs/LerpingAutoUpdate.log
EOF
