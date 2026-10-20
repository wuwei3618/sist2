#!/bin/bash
# Builds Sist.app (universal: arm64 + x86_64, or ARCHS="arm64") from the Swift package, signs it and optionally
# notarizes it for distribution outside the Mac App Store (Developer ID).
#
#   scripts/make-app.sh                       # ad-hoc signed, runs on this Mac
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   BUNDLE_ID=com.yourname.sist NOTARY_PROFILE=notary scripts/make-app.sh
#
# NOTARY_PROFILE is a keychain profile created once with
#   xcrun notarytool store-credentials notary --apple-id ... --team-id ... --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-com.example.sist}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Sist.app"
# Each architecture is built with SwiftPM's native build system and merged with lipo: passing
# several --arch flags at once switches SwiftPM to the xcbuild backend, which fails on this package
read -r -a ARCHS <<< "${ARCHS:-arm64 x86_64}"

BINS=()
for arch in "${ARCHS[@]}"; do
    swift build -c release --arch "$arch"
    BINS+=("$(swift build -c release --arch "$arch" --show-bin-path)")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
universal() {
    local inputs=()
    for bin in "${BINS[@]}"; do
        inputs+=("$bin/$1")
    done
    lipo -create "${inputs[@]}" -output "$2"
}
universal SistApp "$APP/Contents/MacOS/Sist"
# Found by WorkerLocator through Bundle.main.url(forAuxiliaryExecutable:)
universal sist-worker "$APP/Contents/MacOS/sist-worker"
# The command line tool ships inside the app, in Helpers: next to the app's own executable "Sist"
# it would be the same file on a case-insensitive volume.
#   ln -s /Applications/Sist.app/Contents/Helpers/sist /usr/local/bin/sist
mkdir -p "$APP/Contents/Helpers"
universal sist "$APP/Contents/Helpers/sist"
# The background agent, a login item registered by the app with SMAppService. It uses the app's
# sist-worker (WorkerLocator looks in the enclosing app).
AGENT="$APP/Contents/Library/LoginItems/SistAgent.app"
mkdir -p "$AGENT/Contents/MacOS"
universal SistAgent "$AGENT/Contents/MacOS/SistAgent"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    App/Agent/Info.plist > "$AGENT/Contents/Info.plist"
for bundle in "${BINS[0]}"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    App/Info.plist > "$APP/Contents/Info.plist"

# The icon, from App/Icon/AppIcon.png (drawn by scripts/make-icon.py) at the sizes an .icns holds
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" App/Icon/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    sips -z $((size * 2)) $((size * 2)) App/Icon/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Hardened runtime is required for notarization. Nested executables are signed before the app.
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_FLAGS+=(--timestamp)
fi
# The app's executable must be the app (and not, say, a tool of the same name in another case)
otool -L "$APP/Contents/MacOS/Sist" | grep -q SwiftUI || { echo "Contents/MacOS/Sist is not the app" >&2; exit 1; }

# Inside out: the nested app before anything else in the bundle
codesign "${SIGN_FLAGS[@]}" "$AGENT"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/sist-worker"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/sist"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" build/Sist.zip
    xcrun notarytool submit build/Sist.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm build/Sist.zip
fi

echo "Built $APP"
