#!/bin/bash
# Builds ClaudeUsageBar.app (release, ad-hoc signed) into macos/build/.
# Usage: scripts/bundle.sh [--install]   (--install copies it to ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ClaudeUsageBar
BIN="$(swift build -c release --product ClaudeUsageBar --show-bin-path)/ClaudeUsageBar"

APP="build/ClaudeUsageBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeUsageBar"

VERSION="0.1.0"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.claude-usage-bar</string>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: required to run on Apple Silicon. Keychain items are tied to the signature,
# so after a rebuild macOS may ask once to allow access to the saved session.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ClaudeUsageBar.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/ClaudeUsageBar.app"
fi
