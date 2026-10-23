#!/bin/sh
# Builds "Fluid MechLab.app" in ./build from the Swift package.
# Usage: scripts/build-app.sh            (release build for this Mac)
set -eu

cd "$(dirname "$0")/.."
APP="build/Fluid MechLab.app"

swift build -c release --product FluidMechLab
BIN="$(swift build -c release --show-bin-path)/FluidMechLab"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FluidMechLab"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

# App icon: render every size from the 1024 px master.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so Gatekeeper lets a locally built app run.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
