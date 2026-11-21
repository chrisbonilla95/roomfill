#!/bin/sh
# Builds Roomfill.app into build/, with the vendored airplay-cli inside, ad-hoc signed.
set -e
cd "$(dirname "$0")/.."
[ -x vendor/cliairplay ] || { echo "vendor/cliairplay missing; run scripts/fetch-airplay-cli.sh" >&2; exit 1; }
swift build -c release --product Roomfill
BIN=$(swift build -c release --show-bin-path)/Roomfill
APP=build/Roomfill.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Roomfill"
cp vendor/cliairplay "$APP/Contents/Resources/cliairplay"
# airplay-cli is GPL-3.0: ship its license and notices; its source is linked from the README.
mkdir -p "$APP/Contents/Resources/airplay-cli"
cp vendor/cliairplay-LICENSE "$APP/Contents/Resources/airplay-cli/LICENSE"
cp vendor/cliairplay-THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/airplay-cli/THIRD_PARTY_NOTICES.md"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
rm -rf build/AppIcon.iconset
swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# A stable code-signing identity keeps macOS privacy permissions across rebuilds; ad-hoc is the
# fallback. The name comes from .codesign-identity (not committed) or defaults to "Roomfill Local".
WANT="Roomfill Local"
[ -f .codesign-identity ] && WANT=$(head -1 .codesign-identity)
IDENTITY=-
if security find-identity -v -p codesigning | grep -qF "\"$WANT\""; then IDENTITY="$WANT"; fi
codesign --force -s "$IDENTITY" "$APP/Contents/Resources/cliairplay"
codesign --force -s "$IDENTITY" --identifier io.chrisbonilla.roomfill "$APP"
echo "signed with: $IDENTITY"
echo "built $APP"
