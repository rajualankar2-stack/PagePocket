#!/usr/bin/env bash
# Builds PagePocket.ipa for AltStore / SideStore.
#
# The app is compiled without a real certificate, then ad-hoc signed with its
# entitlements. AltStore re-signs with the user's own Apple ID on install, but it
# reads the App Group entitlement from this signature to know which group to
# register — an unsigned build would silently lose the Share Extension.
#
# Usage: scripts/build-ipa.sh [marketing-version] [build-number]
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)}"
BUILD="${2:-1}"
OUT="build/ipa"
DERIVED="build/ipa-derived"

rm -rf "$OUT" "$DERIVED"
mkdir -p "$OUT"

xcodebuild build \
  -project PagePocket.xcodeproj \
  -scheme PagePocket \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  | tail -20

APP="$DERIVED/Build/Products/Release-iphoneos/PagePocket.app"
[ -d "$APP" ] || { echo "error: $APP was not produced" >&2; exit 1; }

# Inside-out: the extension is sealed before the app that contains it.
codesign --force --sign - --timestamp=none \
  --entitlements PagePocketShare/PagePocketShare.entitlements \
  "$APP/PlugIns/PagePocketShare.appex"
codesign --force --sign - --timestamp=none \
  --entitlements PagePocket/Resources/PagePocket.entitlements \
  "$APP"

mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && zip -qry PagePocket.ipa Payload && rm -rf Payload)

echo "Built $OUT/PagePocket.ipa (version $VERSION, build $BUILD)"
