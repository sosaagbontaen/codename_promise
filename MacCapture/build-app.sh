#!/bin/sh
# Builds "DumpNotes Capture.app" and installs it in /Applications (or ~/Applications if that
# isn't writable). Ad-hoc signed: it runs on this Mac without a Developer ID, and needs no
# entitlements because it only writes to a folder in iCloud Drive.
set -eu
cd "$(dirname "$0")"

APP_NAME="DumpNotes Capture"
BUILD_DIR=".build/app"
APP="$BUILD_DIR/$APP_NAME.app"

swift build -c release --product DumpNotesCapture
BIN="$(swift build -c release --show-bin-path)/DumpNotesCapture"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DumpNotesCapture"

# The phone app's icon, so the two are recognisably the same thing.
ICON_SRC="../CodenamePromise/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

VERSION="1.0"
BUILD="$(git -C .. rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>com.codenamepromise.capture</string>
	<key>CFBundleExecutable</key><string>DumpNotesCapture</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x DumpNotesCapture 2>/dev/null || true
rm -rf "$DEST/$APP_NAME.app"
cp -R "$APP" "$DEST/"
echo "Installed $DEST/$APP_NAME.app"
[ "${OPEN:-1}" = "1" ] && open "$DEST/$APP_NAME.app"
true
