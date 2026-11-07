#!/bin/zsh
# grab.sh — real window chrome for the SDR/HDR comparison (see ChromeGrab.swift)
cd "${0:A:h}"
swiftc -O -parse-as-library -o ChromeGrab.app/Contents/MacOS/ChromeGrab ChromeGrab.swift -framework AppKit 2>&1 | grep error
rm -rf chrome; mkdir chrome
open -a "$PWD/ChromeGrab.app" --args "$PWD/chrome" 860x538 "Lerping@Home — SDR" "Lerping@Home — HDR"
for i in 0 1; do
  until [[ -f chrome/window$i.id ]]; do sleep 0.1; done
  id=$(cat chrome/window$i.id)
  osascript -e 'tell application id "com.hergenroeder.launchvideo.chromegrab" to activate'
  sleep 0.6
  screencapture -x -l$id chrome/window$i-shadow.png
  screencapture -x -o -l$id chrome/window$i-frame.png
  touch chrome/window$i.done
done
