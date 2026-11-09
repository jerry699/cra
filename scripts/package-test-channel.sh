#!/bin/bash
# Derives a second app from a built Cra.app so it runs next to the installed one:
# bundle id dk.kildahl.cra.dev (own profile under ~/Library/Application Support/CraDev),
# display name CraDev, no URL schemes (cra:// stays with the installed copy), no update feed.
#   scripts/package-test-channel.sh [path/to/Cra.app]
# Installs to ~/Applications (CRA_DEV_APP overrides): a file provider under ~/Documents
# re-tags bundles after signing, which fails codesign verification.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-build/Cra.app}"
APP="${CRA_DEV_APP:-$HOME/Applications/CraDev.app}"
PB=/usr/libexec/PlistBuddy
[ -d "$SRC" ] || { echo "No app at $SRC. Run scripts/build.sh first." >&2; exit 1; }
[ "$($PB -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist")" = "dk.kildahl.cra" ] \
  || { echo "$SRC is not a release-identity build" >&2; exit 1; }

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
ditto "$SRC" "$APP"
xattr -cr "$APP"

$PB -c "Set :CFBundleIdentifier dk.kildahl.cra.dev" \
      -c "Set :CFBundleName CraDev" -c "Set :CFBundleDisplayName CraDev" \
      -c "Delete :CFBundleURLTypes" -c "Delete :CFBundleDocumentTypes" \
      -c "Delete :UTExportedTypeDeclarations" "$APP/Contents/Info.plist"
$PB -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true

# Helper apps keep their executable names (CEF finds them by the main executable's name)
# but get the dev identity, so notifications and LaunchServices see a separate app.
for plist in "$APP"/Contents/Frameworks/Cra\ Helper*.app/Contents/Info.plist; do
  [ -f "$plist" ] || continue
  $PB -c "Set :CFBundleIdentifier $(/usr/bin/sed -n 's/.*<string>dk\.kildahl\.cra\.helper\(.*\)<\/string>.*/dk.kildahl.cra.dev.helper\1/p' "$plist" | head -1)" "$plist"
  $PB -c "Set :CFBundleName CraDev Helper" -c "Set :CFBundleDisplayName CraDev Helper" "$plist"
done

for helper in "$APP"/Contents/Frameworks/Cra\ Helper*.app; do
  codesign --force --sign - --entitlements resources/CraHelper.entitlements "$helper"
done
codesign --force --sign - --entitlements resources/Cra.entitlements "$APP"
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p build/dist
ditto -c -k --keepParent "$APP" build/dist/CraDev.zip
(cd build/dist && shasum -a 256 CraDev.zip > CraDev.zip.sha256)
echo "Built $APP; the installed Cra is untouched."
echo "Its profile: ~/Library/Application Support/CraDev"
cat build/dist/CraDev.zip.sha256
