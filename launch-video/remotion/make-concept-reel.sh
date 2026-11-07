#!/bin/zsh
# 3x2 side-by-side of every title concept (out/concepts/*.mp4), each labelled,
# all playing in sync with the music from the first clip.
set -e
cd "${0:A:h}/out/concepts"
FONT="$HOME/Library/Fonts/Geist-VariableFont_wght.ttf"
typeset -A NAME=(
  liquid-glass        "A  Liquid Glass (macOS Tahoe): the letters refract the grid"
  titanium            "B  Titanium (iPhone Pro): brushed, warm grey, lit edge"
  chrome-gradient     "C  Gradient chrome (Linear / Vercel): restrained, no bevel"
  molten              "D  Molten: the liquid-metal shader poured into the letters"
  spectral            "E  Spectral (Apple Intelligence): chrome + turning glow"
  liquid-metal-still  "F  Current mock: liquid-metal still"
)
ORDER=(liquid-glass titanium chrome-gradient molten spectral liquid-metal-still)
inputs=() ; filters="" ; i=0
for c in $ORDER; do
  magick -size 960x44 xc:'#000000b0' -font "$FONT" -pointsize 21 -fill white -gravity west -annotate +14+0 "${NAME[$c]}" label-$c.png
  inputs+=(-i $c.mp4 -i label-$c.png)
  filters+="[$((2*i)):v]scale=960:540[v$i];[v$i][$((2*i+1)):v]overlay=0:0[l$i];"
  i=$((i+1))
done
filters+="[l0][l1][l2][l3][l4][l5]xstack=inputs=6:layout=0_0|w0_0|0_h0|w0_h0|0_h0+h1|w0_h0+h1[out]"
ffmpeg -v error -y $inputs -filter_complex "$filters" -map "[out]" -map 0:a -c:v libx264 -crf 18 -pix_fmt yuv420p \
  -c:a aac -b:a 192k -movflags +faststart ../title-concepts-side-by-side.mp4
rm -f label-*.png
echo "-> out/title-concepts-side-by-side.mp4"
