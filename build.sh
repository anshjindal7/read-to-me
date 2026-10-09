#!/bin/bash
# Builds "Read To Me.app" and the photo2audiobook command-line tool into ./build
# Needs only the Xcode Command Line Tools (xcode-select --install), not full Xcode.
set -euo pipefail

cd "$(dirname "$0")"
BUILD=build
APP="$BUILD/Read To Me.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Building app..."
swiftc -O -parse-as-library -swift-version 5 \
    Sources/Shared/*.swift Sources/ReadToMe/*.swift \
    -o "$APP/Contents/MacOS/ReadToMe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The Qwen helper and its setup script travel inside the app.
cp Resources/readtome_ai.py scripts/setup_qwen.sh "$APP/Contents/Resources/"

echo "Drawing icon..."
swift scripts/make_icon.swift "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$BUILD/AppIcon.iconset"

# Ad-hoc signature so macOS will run it locally.
codesign --force --deep --sign - "$APP"

echo "Building command-line tool..."
swiftc -O -swift-version 5 \
    Sources/Shared/*.swift Sources/photo2audiobook/main.swift \
    -o "$BUILD/photo2audiobook"

echo
echo "Done:"
echo "  $APP"
echo "  $BUILD/photo2audiobook"
echo
echo "Drag \"Read To Me.app\" into /Applications to install it."
echo "For natural voices and Qwen's page check, run scripts/setup_qwen.sh once (or click Set Up Qwen in the app)."
