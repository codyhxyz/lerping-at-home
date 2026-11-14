#!/bin/bash
# Compile and exercise the optical shaders offscreen without touching defaults.
set -euo pipefail
cd "$(dirname "$0")/.."
make build/LerpPreview
out=$(mktemp -d "${TMPDIR:-/tmp}/lerp-optics.XXXXXX")
trap 'rm -rf "$out"' EXIT
for shader in prism-caustics diffraction-foil laser-interferometer; do
    for run in a b; do
        build/LerpPreview --snapshot "$out/$run" --size 480x300 --time 7 --seed 0.5 --shader "$shader"
    done
    cmp "$out/a/$shader.png" "$out/b/$shader.png"
    build/LerpPreview --snapshot "$out/earlier" --size 480x300 --time 0 --seed 0.5 --shader "$shader"
    if cmp -s "$out/a/$shader.png" "$out/earlier/$shader.png"; then
        echo "$shader did not change with time" >&2; exit 1
    fi
done
build/LerpPreview --snapshot "$out/viewer" --size 480x300 --time 7 --seed 0.5 --shader diffraction-foil --viewer 0.5,0.2,0
if cmp -s "$out/a/diffraction-foil.png" "$out/viewer/diffraction-foil.png"; then
    echo 'diffraction-foil did not respond to viewer' >&2; exit 1
fi
echo 'Optics snapshots: deterministic, animated and viewer-responsive.'
