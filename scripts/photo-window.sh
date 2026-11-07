#!/bin/bash
# Your photo becomes a window: one photo -> Apple SHARP -> 3D Gaussian splats
# -> a head-parallax look.
#
#   scripts/photo-window.sh [options] PHOTO NAME     (or: make photo-window PHOTO=… NAME=…)
#   scripts/photo-window.sh --setup                  (or: make photo-window-setup)
#
#   --glass near|median|far|METRES   which depth sits on the screen's glass
#                                    (default median; see `photo` in
#                                    scripts/splat-convert.py)
#   --title TEXT                     the look's title (default: NAME, in words)
#   --force                          predict again even if a prediction newer
#                                    than the photo exists, and rewrite the
#                                    look's .metal (the old one is kept as
#                                    .metal.bak)
#   --dry-run                        check everything and print each step;
#                                    run, download and write nothing
#   --setup                          only make the SHARP environment ready
#
# What it does:
#
#   1. SHARP (https://github.com/apple-aiml-research/ml-sharp, formerly
#      apple/ml-sharp) lives in tools/ml-sharp (gitignored): its source
#      at a pinned commit, a Python 3.13 venv (.venv) with its pinned
#      requirements, and its checkpoint in weights/, fetched once and checked
#      against the SHA-256 below. Prediction runs on the GPU through MPS;
#      SHARP's own video rendering needs CUDA and is not used.
#   2. `sharp predict` turns PHOTO into a 3DGS .ply (in ml-sharp/out/NAME/).
#      It is skipped when that .ply is newer than the photo.
#   3. `splat-convert.py photo` turns the .ply from SHARP's OpenCV axes (x
#      right, y down, z forward, metres) into the frame the `window` camera
#      expects (SplatData.swift), whole — no cap, no thinning — and writes
#      ~/Library/Application Support/Lerping/Splats/photo-NAME.lsplat.
#   4. The look, from Templates/photo-window.metal with the photo's field of
#      view and aspect filled in, goes to
#      ~/Library/Application Support/Lerping/Shaders/splat-photo-NAME.metal,
#      the custom-shader folder: the playground hot-loads it, the saver reads
#      it, and `make saver` bakes it into this Mac's installed bundle.
#
# Licences, and why nothing here goes in git:
#
#   - SHARP's code is under Apple's sample-code licence and its weights under
#     the Apple Machine Learning Research Model licence (ml-sharp/LICENSE,
#     LICENSE_MODEL): research use only. The weights are never committed,
#     bundled or shipped; this script downloads them onto this Mac only.
#   - The splats and the look are made from the user's own photo. They live in
#     ~/Library/Application Support/Lerping, outside the repo and outside
#     build/, so they are never committed and `make package` never ships them.
#     Do not copy them into Sources/ or build/splats.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# tools/ is gitignored, so it exists only in the main checkout; worktrees use that one.
MAIN="$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")"
TOOLS="${LERP_TOOLS:-$MAIN/tools}"
SHARP_DIR="$TOOLS/ml-sharp"
SHARP_REPO="https://github.com/apple-aiml-research/ml-sharp.git"
SHARP_REF="aed6527499ef91cba3b54c18d49a870f25947190"
VENV="$SHARP_DIR/.venv"
WEIGHTS_URL="https://ml-site.cdn-apple.com/models/sharp/sharp_2572gikvuh.pt"
WEIGHTS="$SHARP_DIR/weights/sharp_2572gikvuh.pt"
WEIGHTS_SHA256="94211a75198c47f61fca7d739ba08a215418d8d398d48fddf023baccc24f073d"
# Where the hosts read the user's own looks and captures. The override is for
# trying the script out somewhere harmless; nothing reads looks from anywhere else.
LERPING="${LERP_PHOTO_WINDOW_ROOT:-$HOME/Library/Application Support/Lerping}"
SPLAT_DIR="$LERPING/Splats"
SHADER_DIR="$LERPING/Shaders"
TEMPLATE="$ROOT/Templates/photo-window.metal"
CONVERT="$ROOT/scripts/splat-convert.py"

dry=0 force=0 setup_only=0 glass=median title=""
args=()
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) dry=1 ;;
		--force) force=1 ;;
		--setup) setup_only=1 ;;
		--glass) glass="${2:?--glass needs a value}"; shift ;;
		--title) title="${2:?--title needs a value}"; shift ;;
		-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
		-*) echo "photo-window: unknown option $1" >&2; exit 2 ;;
		*) args+=("$1") ;;
	esac
	shift
done

say() { printf '%s\n' "$*"; }
# Runs a step, or under --dry-run prints it.
step() {
	if [ "$dry" = 1 ]; then
		printf 'would run:'; printf ' %q' "$@"; printf '\n'
	else
		"$@"
	fi
}

need_tool() { command -v "$1" >/dev/null 2>&1 || { echo "photo-window: needs $1" >&2; exit 1; }; }

# ------------------------------------------------------------------ setup ----

setup() {
	need_tool curl
	need_tool shasum
	if [ ! -f "$SHARP_DIR/pyproject.toml" ]; then
		need_tool git
		say "SHARP: cloning $SHARP_REPO into $SHARP_DIR"
		step mkdir -p "$TOOLS"
		step git clone --quiet "$SHARP_REPO" "$SHARP_DIR"
		step git -C "$SHARP_DIR" checkout --quiet "$SHARP_REF"
	else
		say "SHARP: source in $SHARP_DIR"
	fi

	if [ ! -x "$VENV/bin/sharp" ]; then
		say "SHARP: making its Python 3.13 venv"
		if command -v uv >/dev/null 2>&1; then
			step uv venv --quiet --python 3.13 "$VENV"
			# requirements.txt installs SHARP itself as `-e .`, relative to its directory.
			step uv --directory "$SHARP_DIR" pip install --quiet --python "$VENV/bin/python" -r requirements.txt
		else
			need_tool python3.13
			step python3.13 -m venv "$VENV"
			step sh -c 'cd "$1" && "$2/bin/pip" install --quiet -r requirements.txt' sh "$SHARP_DIR" "$VENV"
		fi
	else
		say "SHARP: venv ready ($VENV)"
	fi

	if [ ! -f "$WEIGHTS" ]; then
		say "SHARP: downloading its checkpoint (2.8 GB, Apple research licence) to $WEIGHTS"
		step mkdir -p "$(dirname "$WEIGHTS")"
		step curl -fL --retry 3 -C - -o "$WEIGHTS.part" "$WEIGHTS_URL"
		if [ "$dry" = 0 ]; then
			check_weights "$WEIGHTS.part"
			mv "$WEIGHTS.part" "$WEIGHTS"
		fi
	else
		# Hashing 2.8 GB takes a few seconds; once per file, not once per photo.
		stamp="$WEIGHTS.sha256-ok"
		if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$(stat -f '%z %m' "$WEIGHTS")" ]; then
			check_weights "$WEIGHTS"
			[ "$dry" = 1 ] || stat -f '%z %m' "$WEIGHTS" > "$stamp"
		fi
		say "SHARP: checkpoint verified ($WEIGHTS)"
	fi
}

check_weights() {
	local got
	got="$(shasum -a 256 "$1" | cut -d' ' -f1)"
	if [ "$got" != "$WEIGHTS_SHA256" ]; then
		echo "photo-window: $1 has SHA-256 $got, expected $WEIGHTS_SHA256" >&2
		echo "  (delete it to download again)" >&2
		exit 1
	fi
}

if [ "$setup_only" = 1 ]; then
	setup
	exit 0
fi

# ------------------------------------------------------------- one photo ----

# The arguments are checked before setup, so a typo never starts a 2.8 GB download.
if [ "${#args[@]}" -ne 2 ]; then
	echo "usage: scripts/photo-window.sh [--glass G] [--title T] [--force] [--dry-run] PHOTO NAME" >&2
	exit 2
fi
photo="${args[0]}" name="${args[1]}"
[ -f "$photo" ] || { echo "photo-window: no such photo: $photo" >&2; exit 1; }
if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
	echo "photo-window: NAME must be lower-case letters, digits and dashes (it names files): $name" >&2
	exit 2
fi
case "$glass" in
	near|median|far) ;;
	*) [[ "$glass" =~ ^[0-9]*\.?[0-9]+$ ]] || { echo "photo-window: --glass is near, median, far or metres" >&2; exit 2; } ;;
esac
# The card's name, as the selector derives it from the file name (minus
# "splat-" on the Splats shelf); also the default title.
words="$(printf '%s' "$name" | tr '-' ' ' | awk '{ for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2) } 1')"
[ -n "$title" ] || title="$words"

setup

capture="photo-$name"
look="splat-photo-$name"
out="$SHARP_DIR/out/$name"
stem="$(basename "$photo")"; stem="${stem%.*}"
ply="$out/$stem.ply"
lsplat="$SPLAT_DIR/$capture.lsplat"
shader="$SHADER_DIR/$look.metal"
py="$VENV/bin/python"

say "photo:   $photo"
say "look:    $look (\"$title\"), glass $glass"
say "splats:  $lsplat"
say "shader:  $shader"

# 2. Predict.
if [ "$force" = 1 ] || [ ! -f "$ply" ] || [ "$photo" -nt "$ply" ]; then
	say "SHARP: predicting on MPS (this is the GPU step)"
	step mkdir -p "$out"
	# MPS fallback: an op MPS lacks runs on the CPU instead of failing.
	step env PYTORCH_ENABLE_MPS_FALLBACK=1 "$VENV/bin/sharp" predict \
		-i "$photo" -o "$out" -c "$WEIGHTS" --device mps
	if [ "$dry" = 0 ] && [ ! -f "$ply" ]; then
		echo "photo-window: SHARP wrote no $ply (is $(basename "$photo") an image type it reads?)" >&2
		exit 1
	fi
else
	say "SHARP: reusing $ply (newer than the photo; --force to predict again)"
fi

# 3. Convert, whole, into the window frame — staged as .new, and only put in
# place with a look whose framing matches it.
framing="$out/framing.json"
step mkdir -p "$SPLAT_DIR"
if [ "$dry" = 1 ]; then
	step "$py" -I "$CONVERT" photo "$ply" "$lsplat" --glass "$glass"
else
	"$py" -I "$CONVERT" photo "$ply" "$lsplat.new" --glass "$glass" > "$framing"
fi

# 4. The look.
if [ "$dry" = 1 ]; then
	say "would write $shader from $TEMPLATE (fov and aspect from $framing)"
	exit 0
fi
mkdir -p "$SHADER_DIR"
"$py" -I - "$TEMPLATE" "$framing" "$shader.new" "$title" "$(basename "$photo")" "$capture" <<'PY'
import datetime, json, sys
template, framing, out, title, source, capture = sys.argv[1:7]
f = json.load(open(framing))
text = open(template, encoding="utf-8").read()
for key, value in {"TITLE": title, "SOURCE": source, "CAPTURE": capture,
                   "DATE": datetime.date.today().isoformat(),
                   "FOV": f"{f['fovy_degrees']:.3f}", "ASPECT": f"{f['aspect']:.4f}",
                   "GLASS": f"{f['glass_metres']:.2f}"}.items():
    text = text.replace(f"@{key}@", value)
import re
assert not re.search(r"@[A-Z]+@", text), "unfilled placeholder"
open(out, "w", encoding="utf-8").write(text)
PY
if [ -f "$shader" ] && [ "$force" = 0 ]; then
	# The look may have been tuned since; keep it unless the photo's framing moved.
	want="$(grep -E 'lerp-param: (fov|aspect) ' "$shader.new")"
	have="$(grep -E 'lerp-param: (fov|aspect) ' "$shader")"
	rm -f "$shader.new"
	if [ "$want" != "$have" ]; then
		rm -f "$lsplat.new"
		echo "photo-window: $shader exists with another photo's framing:" >&2
		echo "$have" >&2
		echo "  the new prediction wants:" >&2
		echo "$want" >&2
		echo "  nothing was changed; re-run with --force to rewrite it (the old one is kept as $look.metal.bak)" >&2
		exit 1
	fi
	mv "$lsplat.new" "$lsplat"
	say "wrote $lsplat"
	say "kept $shader (same framing)"
else
	mv "$lsplat.new" "$lsplat"
	say "wrote $lsplat"
	[ -f "$shader" ] && cp "$shader" "$shader.bak"
	mv "$shader.new" "$shader"
	say "wrote $shader"
fi
say "framing: $(head -1 "$framing")"
say "done: open the playground and pick \"Photo $words\" on the Splats shelf, or render a still:"
say "  build/LerpPreview --snapshot build/photo-window --size 1600x1000 --time 4 --shader $look"
