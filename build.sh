#!/bin/zsh
# Сборка «История буфера.app» (для Apple Silicon и Intel).
#   ./build.sh            — только собрать в build/
#   ./build.sh --install  — собрать и установить в ~/Applications
#   ./build.sh --dmg      — собрать установщик build/ClipHistory-<версия>.dmg
set -euo pipefail
cd "$(dirname "$0")"

NAME="История буфера"
APP="build/$NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 main.swift -o build/ClipHistory-$arch
done
lipo -create build/ClipHistory-arm64 build/ClipHistory-x86_64 -output "$APP/Contents/MacOS/ClipHistory"
rm build/ClipHistory-arm64 build/ClipHistory-x86_64
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

case "${1:-}" in
  --install)
    mkdir -p ~/Applications
    pkill -x ClipHistory 2>/dev/null || true
    sleep 0.5
    rm -rf ~/Applications/"$NAME.app"
    cp -R "$APP" ~/Applications/
    open ~/Applications/"$NAME.app"
    echo "Установлено: ~/Applications/$NAME.app"
    ;;
  --dmg)
    STAGE=build/dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Программы"
    cp "Как установить.txt" "$STAGE/"
    DMG="build/ClipHistory-$VERSION.dmg"
    hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "Установщик: $DMG"
    ;;
esac
