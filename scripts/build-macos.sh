#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/check-version.mjs
release_version=$(node -p 'JSON.parse(require("fs").readFileSync("version.json")).version')
release_build=$(node -p 'JSON.parse(require("fs").readFileSync("version.json")).build')
mkdir -p artifacts/macos .build/release-direct
sources=()
while IFS= read -r -d '' path; do sources+=("$path"); done < <(find MinuteFlow -name '*.swift' -print0)
for arch in arm64 x86_64; do
  swiftc -O -swift-version 6 -parse-as-library -target "$arch-apple-macos14.0" "${sources[@]}" \
    -o ".build/release-direct/MinuteFlow-$arch" -framework SwiftUI -framework AppKit \
    -framework AVFoundation -framework ScreenCaptureKit -framework Security \
    -framework CoreLocation -framework CryptoKit -framework Accelerate
done
build_stage=$(mktemp -d /tmp/MinuteFlow-macos-build-XXXXXX)
bundle="$build_stage/MinuteFlow.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
lipo -create .build/release-direct/MinuteFlow-arm64 .build/release-direct/MinuteFlow-x86_64 -output "$bundle/Contents/MacOS/MinuteFlow"
cp MinuteFlow/Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
cp MinuteFlow/Supporting/Info.plist "$bundle/Contents/Info.plist"
plist="$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable MinuteFlow' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.minuteflow.app' "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $release_version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $release_build" "$plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 14.0' "$plist"
xattr -cr "$bundle"
codesign --force --sign - --entitlements MinuteFlow/Supporting/MinuteFlow.entitlements "$bundle"
codesign --verify --deep --strict "$bundle"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "artifacts/MinuteFlow-v$release_version-macOS-universal.zip"
printf 'MACOS_STAGED_APP=%s\n' "$bundle"
