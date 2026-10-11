#!/bin/bash
# Builds a release MacDirStat.app (with Info.plist and icon) at .build/MacDirStat.app.
# Install with: cp -R .build/MacDirStat.app /Applications/
#
# Optional environment:
#   VERSION=1.2.3      version written to Info.plist (default 0.1.0)
#   UNIVERSAL=1        build for both arm64 and x86_64
#   SIGN_IDENTITY=...  codesigning identity, e.g. "Developer ID Application: Name (TEAMID)" for
#                      distribution; the default "-" signs ad hoc
set -euo pipefail

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="io.github.phalladar.MacDirStat"

cd "$(dirname "$0")/.."
BUILD_ARGS=(-c release)
if [[ "${UNIVERSAL:-}" == 1 ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

APP=".build/MacDirStat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/MacDirStat" "$APP/Contents/MacOS/"
cp Sources/MacDirStat/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# Bundle.module looks in Contents/Resources first, so keep SPM resources working inside the app.
cp -R "$BIN_DIR/MacDirStat_MacDirStat.bundle" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MacDirStat</string>
    <key>CFBundleDisplayName</key>
    <string>MacDirStat</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>MacDirStat</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    # Ad-hoc sign so the bundle's resources are sealed and the signature is valid.
    codesign --force --sign - "$APP"
else
    # Notarization requires the hardened runtime and a secure timestamp.
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
fi

echo "Built $APP"
