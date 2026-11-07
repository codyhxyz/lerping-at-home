#!/bin/bash
# Render the launch video with raea:  edit/render.sh vN   (e.g. v10, or v9-raea)
#
# Writes remotion/out/launch-mock-vN.mp4 (H.264 CRF 16 + AAC 320k, as the Remotion renders were) and
# remotion/out/launch-mock-vN-preview.mp4 (CRF 26, preset slow). Refuses to overwrite either.
#
# Steps:
#   1. raea renders edit/Launch.tsx (composition "Launch") at constant quality ("master") into
#      edit/out/vN-<time>/raea-master.mp4, with its log beside it.
#   2. The render FAILS (exit 3, the work folder kept aside) if raea's log has a warning or error line that isn't on the
#      short list of known-harmless startup lines below. raea once dropped the title's letters and still exited 0; the
#      only sign was a WARN line.
#   3. The master is re-encoded into remotion/out, then the work folder's 1 GB master is deleted (log and picks kept).
#
# Pinned to raea 0.1.0-canary.2 (~/Documents/raea). A different version refuses to run: canary changes daily.
#
# Audio: raea masters every render through a look-ahead limiter. With no <Mix> the ceiling is -1 dBFS, and <Mix> only
# allows ceilings <= 0 dBTP (with loudness normalisation on top). raea has no way to turn the limiter off, so the loud
# parts come out about 0.7 dB lower than the track (and lower than the Remotion renders), with peaks at about -1 dBFS.
set -euo pipefail
set -o noclobber

NAME="${1:-}"
if [[ ! "$NAME" =~ ^v[0-9]+(-[a-z0-9]+)*$ ]]; then
  echo "usage: edit/render.sh vN   (e.g. v10, v9-raea)" >&2
  exit 64
fi

EDIT="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT="$(dirname "$EDIT")"
OUTDIR="$PROJECT/remotion/out"
OUT="$OUTDIR/launch-mock-$NAME.mp4"
PREVIEW="$OUTDIR/launch-mock-$NAME-preview.mp4"
RAEA_HOME="${RAEA_HOME:-$HOME/Documents/raea}"
RAEA="$RAEA_HOME/bin/raea"
PINNED="0.1.0-canary.2"

for f in "$OUT" "$PREVIEW"; do
  if [[ -e "$f" ]]; then echo "render.sh: $f already exists; pick a new version name" >&2; exit 65; fi
done
[[ -x "$RAEA" ]] || { echo "render.sh: no raea at $RAEA" >&2; exit 66; }
have="$(cat "$RAEA_HOME/share/raea/VERSION" 2>/dev/null || echo unknown)"
if [[ "$have" != "$PINNED" ]]; then
  echo "render.sh: raea is $have, this script is pinned to $PINNED. Check a render against the last one before changing PINNED." >&2
  exit 66
fi
# One GPU job at a time.
if pgrep -f 'remotion render' >/dev/null || pgrep -f 'raea render' >/dev/null; then
  echo "render.sh: a remotion or raea render is already running; wait for it to finish" >&2
  exit 75
fi

WORK="$EDIT/out/$NAME-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK"
cp "$PROJECT/remotion/src/picks.json" "$WORK/picks.json"   # the picks this render used
MASTER="$WORK/raea-master.mp4"
LOG="$WORK/render.log"

echo "render.sh: rendering $NAME with raea $have -> $WORK"
start=$(date +%s)
set +e
# RAEA_PAGE_ROOT: lets inline-style url(/media/...) (the title's maskImage) load; without it raea draws an empty mask.
# RAEA_BUNDLE_CACHE=0 / RAEA_EXPORT_CACHE=0: always a fresh bundle and render (picks.json and timing.ts live outside
# edit/), and no 1 GB copy of every export in ~/Library/Caches/raea.
( cd "$EDIT" && RAEA_PAGE_ROOT="$EDIT" RAEA_BUNDLE_CACHE=0 RAEA_EXPORT_CACHE=0 \
    "$RAEA" render Launch.tsx --composition Launch -o "$MASTER" --quality master ) >"$LOG" 2>&1
rc=$?
set -e
secs=$(( $(date +%s) - start ))
echo "render.sh: raea exited $rc after ${secs}s"
if [[ $rc -ne 0 ]]; then
  tail -20 "$LOG" >&2
  echo "render.sh: FAILED (raea exit $rc); log and partial output kept in $WORK" >&2
  exit 3
fi

# Every warning or error line fails the render, except these known-harmless ones (Bevy's asset setup and an MP4 atom
# note that come with every render of this release).
ALLOW='WebAssetPlugin is potentially insecure|Skip creating file watcher because path ".*/bin/assets" does not exist|AssetSourceId::Default does not have an AssetWatcher configured|symphonia_format_isomp4::atoms::stbl\] ignoring (stss|ctts) atom'
bad="$(sed $'s/\x1b\\[[0-9;]*m//g' "$LOG" \
  | /usr/bin/grep -iE "warn|error|panic|fail|refus|isn't a file|not found|missing|cannot|could not|couldn't" \
  | /usr/bin/grep -vE "$ALLOW" || true)"
if [[ -n "$bad" ]]; then
  echo "$bad" >&2
  echo "render.sh: FAILED: raea logged the warnings/errors above (it can exit 0 with a broken frame); output kept aside in $WORK" >&2
  exit 3
fi

applied="$(/usr/bin/grep -oE 'APPLIED +[0-9]+ frames' "$LOG" | /usr/bin/grep -oE '[0-9]+' || true)"
probed="$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$MASTER")"
if [[ -z "$applied" || "$applied" != "$probed" ]]; then
  echo "render.sh: FAILED: raea reported '${applied:-no}' frames, the file has $probed; kept aside in $WORK" >&2
  exit 3
fi
echo "render.sh: $applied frames, log clean"

tmp="$OUTDIR/.launch-mock-$NAME.$$.mp4"
ffmpeg -v error -nostdin -i "$MASTER" -map 0:v:0 -map 0:a:0 -c:v libx264 -crf 16 -pix_fmt yuv420p \
  -c:a aac -b:a 320k -movflags +faststart "$tmp"
mv -n "$tmp" "$OUT"
[[ -e "$tmp" ]] && { rm -f "$tmp"; echo "render.sh: $OUT appeared meanwhile; not overwritten" >&2; exit 65; }

tmp="$OUTDIR/.launch-mock-$NAME-preview.$$.mp4"
ffmpeg -v error -nostdin -i "$OUT" -c:v libx264 -crf 26 -preset slow -c:a aac -b:a 160k -movflags +faststart "$tmp"
mv -n "$tmp" "$PREVIEW"
[[ -e "$tmp" ]] && { rm -f "$tmp"; echo "render.sh: $PREVIEW appeared meanwhile; not overwritten" >&2; exit 65; }

rm -f "$MASTER"
echo "render.sh: raea ${secs}s; wrote $OUT and $PREVIEW (log and picks in $WORK)"
