#!/bin/zsh
# Build a distributable Biscuit-<version>.dmg.
# Usage: ./release.sh [version]   (default: MARKETING_VERSION from the project)
#
# The app is ad-hoc signed (no Developer ID yet), so downloaders must
# right-click → Open the first time, or run:
#   xattr -dr com.apple.quarantine /Applications/Biscuit.app

set -e
cd "$(dirname "$0")"

VERSION="${1:-$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' NotchAssistant.xcodeproj/project.pbxproj | head -1)}"
DMG="Biscuit-${VERSION}.dmg"

echo "Building Biscuit ${VERSION}…"
xcodebuild -project NotchAssistant.xcodeproj -scheme NotchAssistant \
  -configuration Release -derivedDataPath build -quiet build

STAGE=$(mktemp -d)
cp -R build/Build/Products/Release/Biscuit.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname Biscuit -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

echo "Wrote ${DMG} ($(du -h "$DMG" | cut -f1))"
