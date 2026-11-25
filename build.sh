#!/bin/zsh
# Сборка «История буфера.app» и установка в ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="build/История буфера.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 main.swift \
  -o "$APP/Contents/MacOS/ClipHistory"
cp Info.plist "$APP/Contents/Info.plist"

# Иконка
swift make_icon.swift build/icon1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s * 2))
  sips -z $d $d build/icon1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x ClipHistory 2>/dev/null || true
  sleep 0.5
  rm -rf ~/Applications/"История буфера.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"История буфера.app"
  echo "Установлено: ~/Applications/История буфера.app"
fi
