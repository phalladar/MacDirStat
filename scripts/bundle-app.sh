#!/usr/bin/env bash
# Builds MacDirStat in release mode and wraps the binary in a minimal .app bundle.
#
# Usage:
#   scripts/bundle-app.sh            # creates build/MacDirStat.app
#   scripts/bundle-app.sh --install  # also copies it to /Applications
set -euo pipefail

APP_NAME="MacDirStat"
BUNDLE_ID="com.github.phalladar.MacDirStat"
VERSION="${VERSION:-1.0.0}"
# Unique per build so macOS icon caches keyed on bundle ID + version never go stale.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
MIN_MACOS="15.0"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

swift build -c release
binary="$(swift build -c release --show-bin-path)/$APP_NAME"

app_dir="build/$APP_NAME.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary" "$app_dir/Contents/MacOS/$APP_NAME"
iconutil --convert icns "Resources/AppIcon.iconset" --output "$app_dir/Contents/Resources/AppIcon.icns"

cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so the bundle (including Info.plist) is sealed and launches cleanly.
codesign --force --sign - "$app_dir"
echo "Built $app_dir"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$app_dir" /Applications/
    echo "Installed /Applications/$APP_NAME.app"
fi
