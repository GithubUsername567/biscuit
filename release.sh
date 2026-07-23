#!/bin/zsh
# Build a distributable Biscuit-<version>.dmg with the Ollama runtime bundled
# inside the app, so downloaders don't need Homebrew or a separate Ollama
# install. Biscuit starts the server itself and downloads the model on first
# run (see OllamaLauncher.swift).
#
# Usage: ./release.sh [version]   (default: MARKETING_VERSION from the project)
#
# The app is signed with the local "Biscuit Local Signing" identity if present
# (keeps permission grants stable), otherwise ad-hoc. Either way it isn't
# notarized, so first-launch requires right-click → Open, or:
#   xattr -dr com.apple.quarantine /Applications/Biscuit.app

set -e
cd "$(dirname "$0")"

VERSION="${1:-$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' NotchAssistant.xcodeproj/project.pbxproj | head -1)}"
DMG="Biscuit-${VERSION}.dmg"

# --- Locate the ollama binary to bundle -------------------------------------
OLLAMA_BIN="$(command -v ollama || true)"
if [[ -z "$OLLAMA_BIN" ]]; then
  for p in /opt/homebrew/bin/ollama /usr/local/bin/ollama /Applications/Ollama.app/Contents/Resources/ollama; do
    [[ -x "$p" ]] && OLLAMA_BIN="$p" && break
  done
fi
if [[ -z "$OLLAMA_BIN" ]]; then
  echo "error: no 'ollama' binary found to bundle. Install it first: brew install ollama" >&2
  exit 1
fi
# Resolve symlinks to the real Mach-O.
OLLAMA_BIN="$(readlink -f "$OLLAMA_BIN" 2>/dev/null || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OLLAMA_BIN")"
echo "Bundling ollama from ${OLLAMA_BIN} ($(du -h "$OLLAMA_BIN" | cut -f1))"

echo "Building Biscuit ${VERSION}…"
xcodebuild -project NotchAssistant.xcodeproj -scheme NotchAssistant \
  -configuration Release -derivedDataPath build -quiet build

APP="build/Build/Products/Release/Biscuit.app"

# --- Bundle the runtime, then (re)sign so the added binary is covered --------
mkdir -p "$APP/Contents/Resources"
cp -p "$OLLAMA_BIN" "$APP/Contents/Resources/ollama"
chmod +x "$APP/Contents/Resources/ollama"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Biscuit Local Signing"; then
  SIGN_ID="Biscuit Local Signing"
else
  SIGN_ID="-"   # ad-hoc
fi
echo "Signing with identity: ${SIGN_ID}"
codesign --force --sign "$SIGN_ID" "$APP/Contents/Resources/ollama"
codesign --force --deep --sign "$SIGN_ID" --identifier com.local.Biscuit "$APP"

# --- Package ----------------------------------------------------------------
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname Biscuit -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

echo "Wrote ${DMG} ($(du -h "$DMG" | cut -f1))"
