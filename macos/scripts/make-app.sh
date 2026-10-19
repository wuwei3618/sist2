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
# The command line tool ships inside the app: ln -s /Applications/Sist.app/Contents/MacOS/sist /usr/local/bin/sist
universal sist "$APP/Contents/MacOS/sist"
for bundle in "${BINS[0]}"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    App/Info.plist > "$APP/Contents/Info.plist"

# Hardened runtime is required for notarization. Nested executables are signed before the app.
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_FLAGS+=(--timestamp)
fi
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/sist-worker"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/sist"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" build/Sist.zip
    xcrun notarytool submit build/Sist.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm build/Sist.zip
fi

echo "Built $APP"
