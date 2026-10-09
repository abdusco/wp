#!/usr/bin/env bash
set -euo pipefail

# Usage: ARCH=arm64 VERSION=1.2.3 ./build.sh
# Produces build/<arch>/wp.app

ARCH="${ARCH:-arm64}"
VERSION="${VERSION:-dev}"
VERSION_CLEAN=${VERSION#v}

OUT="build/${ARCH}/wp.app"
# Assembled in a staging dir and moved into place at the end. If Finder
# looks at a half-built bundle (no Info.plist yet), LaunchServices caches it
# as unlaunchable and shows a blocked icon.
APP="build/.staging-${ARCH}/wp.app"

echo "Building for arch: $ARCH, version: $VERSION_CLEAN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

sed "s/var version = \".*\"/var version = \"$VERSION_CLEAN\"/" main.swift > main.build.swift

swiftc -target ${ARCH}-apple-macos13.0 -o "$APP/Contents/MacOS/wp" main.build.swift \
  -framework AppKit -framework Foundation -framework CoreImage -framework Metal -framework Network -framework ServiceManagement -framework SwiftUI

rm main.build.swift

# Icon: render the SVG at every size iconutil expects.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  swift assets/render-icon.swift assets/icon.svg "$ICONSET/icon_${size}x${size}.png" $size
  swift assets/render-icon.swift assets/icon.svg "$ICONSET/icon_${size}x${size}@2x.png" $((size * 2))
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>wp</string>
  <key>CFBundleDisplayName</key>        <string>wp</string>
  <key>CFBundleIdentifier</key>         <string>dev.abdus.apps.wp</string>
  <key>CFBundleExecutable</key>         <string>wp</string>
  <key>CFBundleIconFile</key>           <string>AppIcon</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION_CLEAN}</string>
  <key>CFBundleVersion</key>            <string>${VERSION_CLEAN}</string>
  <key>LSMinimumSystemVersion</key>     <string>13.0</string>
  <key>LSUIElement</key>                <true/>
  <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign the whole bundle so the Info.plist is sealed into the signature.
codesign --force --sign - "$APP"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
mv "$APP" "$OUT"
rmdir "$(dirname "$APP")"

echo "Built $OUT with version $VERSION_CLEAN"
