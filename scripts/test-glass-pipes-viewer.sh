#!/bin/bash
# Exercise the real shader and viewer plumbing without changing user defaults.
set -euo pipefail
cd "$(dirname "$0")/.."
make build/LerpPreview
out=$(mktemp -d "${TMPDIR:-/tmp}/lerp-pipes-viewer.XXXXXX")
trap 'rm -rf "$out"' EXIT
render() {
    local name=$1; shift
    build/LerpPreview --snapshot "$out/$name" --size 480x300 --time 6 --seed 0.37 --shader glass-pipes "$@"
}
render centered
render zero --viewer 0.5,0.2,0.1 --param parallax=0
render moved --viewer 0.5,0.2,0.1
cmp "$out/centered/glass-pipes.png" "$out/zero/glass-pipes.png"
if cmp -s "$out/centered/glass-pipes.png" "$out/moved/glass-pipes.png"; then
    echo 'glass-pipes did not respond to viewer' >&2; exit 1
fi
echo 'Glass pipes: zero gain preserves centered camera; viewer moves the scene.'
