#!/bin/zsh
# Usage: package-dmg.sh <notarized ReelDock.app> <new .dmg path> <team ID>
# Packages a stapled app as a signed DMG, and refuses an app Gatekeeper wouldn't accept.
set -euo pipefail
app="$1"
output="$2"
team="$3"
[[ ! -e "$output" ]] || { echo "Refusing to replace $output" >&2; exit 1; }

codesign --verify --deep --strict "$app"
codesign -dv "$app" 2>&1 | grep -q "TeamIdentifier=$team" || { echo "Wrong team" >&2; exit 65; }
xcrun stapler validate "$app"
spctl --assess --type execute "$app"

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
identity=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep -F "($team)" | head -1 | sed -E 's/.*"(.*)"/\1/')
stage=$(mktemp -d "${TMPDIR:-/tmp}/reeldock-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/ReelDock.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "ReelDock $version" -srcfolder "$stage" -format UDZO -fs HFS+ "$output"
codesign --force --sign "$identity" --timestamp "$output"
hdiutil verify "$output"
