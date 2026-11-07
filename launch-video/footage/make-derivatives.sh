#!/bin/zsh
# Tile-size clips (for the opening grid and the curation page) and a labelled
# contact sheet, both derived from the 1080p60 masters in footage/1080p/.
#
# A master that came from footage/store/<look>/<key>.mp4 gets its tile and still
# made once per key, stored beside it (<key>.tile.mp4, <key>.jpg) and linked
# into tiles/ and stills/, so a re-render refreshes them and a revert is free.
# Masters from before the store keep the old rule: made once, if missing.
set -e
cd "${0:A:h}"
mkdir -p tiles stills

tile() { ffmpeg -v error -y -i $1 -vf scale=480:270:flags=lanczos \
  -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -movflags +faststart $2 }
still() { ffmpeg -v error -y -ss 2 -i $1 -frames:v 1 -vf scale=480:270 -q:v 3 $2 }
# Point $2 at $1 unless it already is $1.
relink() { [[ $1 -ef $2 ]] || ln -f $1 $2 }

for src in 1080p/*.mp4; do
  name=${src:t:r}
  stored=(store/$name/*.mp4(N))
  key=
  for f in $stored; do [[ $f -ef $src ]] && key=${f:r} && break; done
  if [[ -n $key && $key != *.tile ]]; then
    {
      [[ -f $key.tile.mp4 ]] || { tile $src $key.tile.part.mp4 && mv $key.tile.part.mp4 $key.tile.mp4 }
      [[ -f $key.jpg ]] || still $src $key.jpg
      relink $key.tile.mp4 tiles/$name.mp4
      relink $key.jpg stills/$name.jpg
    } &
  else
    [[ -f tiles/$name.mp4 ]] || tile $src tiles/$name.mp4 &
    [[ -f stills/$name.jpg ]] || still $src stills/$name.jpg &
  fi
  (( $(jobs -r | wc -l) >= 8 )) && wait -n
done
wait
magick montage stills/*.jpg -font "$HOME/Library/Fonts/Geist-VariableFont_wght.ttf" -pointsize 14 \
  -fill '#e8e8ea' -background '#07080a' -set label '%t' -tile 8x -geometry 360x203+6+6 contact-sheet.jpg
echo "tiles: $(ls tiles | wc -l)  stills: $(ls stills | wc -l)  -> contact-sheet.jpg"
