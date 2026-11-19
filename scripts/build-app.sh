#!/bin/zsh
# Builds NativeCAM.app (Apple silicon, release) into build/ and ad-hoc signs it.
#   scripts/build-app.sh          build
#   scripts/build-app.sh --open   build and launch
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --product NativeCAM
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/NativeCAM.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NativeCAM" "$APP/Contents/MacOS/NativeCAM"
cp Resources/AppIcon.icns Resources/Credits.rtf LICENSE "$APP/Contents/Resources/"
# SwiftPM resource bundles, if any target has resources.
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

VERSION="0.1.0"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NativeCAM</string>
  <key>CFBundleDisplayName</key><string>NativeCAM</string>
  <key>CFBundleIdentifier</key><string>com.nativecam.app</string>
  <key>CFBundleExecutable</key><string>NativeCAM</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Daniel Smith. GPL-3.0-or-later.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>NativeCAM Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>NSDocumentClass</key><string>NSDocument</string>
      <key>LSItemContentTypes</key><array><string>com.nativecam.project</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.nativecam.project</string>
      <key>UTTypeDescription</key><string>NativeCAM Project</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>nativecam</string></array></dict>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.nativecam.gcode-tap</string>
      <key>UTTypeDescription</key><string>G-code (Mach)</string>
      <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>tap</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
