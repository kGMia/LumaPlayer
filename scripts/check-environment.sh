#!/bin/bash
set -euo pipefail
sw_vers
uname -m
# Avoid hardware UUID and serial-number collection.
system_profiler SPHardwareDataType SPDisplaysDataType | sed '/Serial Number/d; /Hardware UUID/d; /Provisioning UDID/d'
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -version
swift --version
node --version
ffmpeg -version | head -4
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/IINA.app/Contents/Info.plist
