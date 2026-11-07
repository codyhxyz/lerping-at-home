#!/bin/zsh
# comp.sh IN.png OUT.jpg — the render over the grid (darkened like the title scrim)
magick ../title-assets/src/ref/shader-grid-1920.png -resize 1920x1080^ -gravity center -extent 1920x1080 \
  -fill black -colorize 35% "$1" -composite -quality 92 "$2"
