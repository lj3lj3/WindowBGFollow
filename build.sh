#!/bin/zsh
# 构建并签名 WindowBGFollow.app，随后可 launchctl/open 启动
set -e
cd "$(dirname "$0")"

APP=WindowBGFollow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O main.swift \
  -o "$APP/Contents/MacOS/WindowBGFollow" \
  -framework AppKit -framework ApplicationServices -framework CoreFoundation

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/bg.jpg "$APP/Contents/Resources/bg.jpg"

codesign --force --sign - "$APP"
echo "Build OK: $(pwd)/$APP"
