#!/bin/zsh
# Bring footage/1080p up to date with origin/main, rendering only what changed.
#
#   footage/render.sh            every look remotion/src/picks.json uses
#   footage/render.sh --all      every look in the rotation (for the curation page)
#   footage/render.sh LOOK ...   just these (shader, shader/Preset or shader--Preset)
#
# Renders come from a clean snapshot of origin/main, never the working checkout,
# so uncommitted shader edits there can't leak into the video. Clips live in
# footage/store/<look>/<key>.mp4, keyed on what decides the pixels (see
# recorder/RecordMain.swift); a look whose shader hasn't changed since its last
# render is relinked, not re-rendered. Old renders stay in the store, so each
# look's history is footage/store/<look>/history.tsv.
#
# One recorder at a time, on purpose: parallel GPU work makes the laptop unusable.
set -e
root=${0:A:h:h}
repo=${root:h}  # launch-video/ sits in the repo it renders

git -C $repo fetch -q origin
rev=$(git -C $repo rev-parse --short=12 origin/main)
snap=$root/recorder/snap/$rev
if [[ ! -d $snap ]]; then
  rm -rf $snap.part && mkdir -p $snap.part
  git -C $repo archive origin/main Sources | tar -x -C $snap.part
  mv $snap.part $snap
fi
# Splat captures are not in git: the recorder finds them at <snapshot>/build/splats,
# so point that at the checkout's converted set (`make splats` there).
mkdir -p $snap/build && ln -sfn $repo/build/splats $snap/build/splats
# Keep only the current snapshot.
for old in $root/recorder/snap/*(N/); do [[ $old == $snap ]] || rm -rf $old; done

# Bump when RecordMain.swift changes how a frame is made or encoded (not for
# CLI or bookkeeping edits): it is in every key, so bumping re-renders everything.
render_version=ae18e1b2f38b

# One recorder binary per (LerpCore tree, RecordMain.swift).
core=$(git -C $repo rev-parse origin/main:Sources/LerpCore)
rec=$(shasum -a 256 $root/recorder/RecordMain.swift | cut -c1-12)
bin=$root/recorder/bin/LerpRecord-${core[1,12]}-$rec
if [[ ! -x $bin ]]; then
  mkdir -p $root/recorder/bin
  echo "building recorder for LerpCore ${core[1,12]}"
  swiftc -O -parse-as-library -target arm64-apple-macos14.0 -o $bin.part \
    $snap/Sources/LerpCore/*.swift $root/recorder/RecordMain.swift \
    -framework AppKit -framework Metal -framework QuartzCore -framework CoreGraphics -framework ImageIO
  mv $bin.part $bin
fi
ln -sf ${bin:t} $root/recorder/bin/LerpRecord-current

# Salts: plain shaders depend on the renderer and parameter packing; shaders with
# a data provider run engine Swift every frame, so they key on all of LerpCore.
pure=$(git -C $repo rev-parse origin/main:Sources/LerpCore/LerpRenderer.swift \
       origin/main:Sources/LerpCore/ShaderParameters.swift | cut -c1-12 | tr -d '\n')-$render_version
data=${core[1,12]}-$render_version

only=()
if [[ $1 == --all ]]; then
  :
elif (( $# )); then
  for look in "$@"; do only+=(--only $look); done
else
  for look in $(python3 - $root/remotion/src/picks.json <<'EOF'
import json, sys
p = json.load(open(sys.argv[1]))
looks = list(p["grid"]) + [s["look"] for s in p["montage"]] + [p["closingBackground"]]
looks.append(p.get("opening", {}).get("hero", "fractal-d--Upstream"))
print("\n".join(dict.fromkeys(looks)))
EOF
  ); do only+=(--only $look); done
fi

cd $snap  # the recorder finds Sources/Shaders from the working directory
$bin $root/footage/1080p --store $root/footage/store --salt-pure $pure --salt-data $data \
  --label $rev --start 6 --seconds 6 --speed 1 --seed 0.37 $only
$root/footage/make-derivatives.sh
