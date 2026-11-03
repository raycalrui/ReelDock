#!/bin/zsh
# Archives a Release build, notarizes it through the Apple account signed in to Xcode,
# and packages the stapled app as a signed DMG in dist/. Publishes nothing.
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

team=G882WWCZ3Z
version=$(xcodebuild -project ReelDock.xcodeproj -scheme ReelDock -configuration Release -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION =/{print $3; exit}')
output="$PWD/dist/ReelDock-$version.dmg"
[[ ! -e "$output" ]] || { echo "Refusing to replace $output" >&2; exit 1; }
mkdir -p dist

work=$(mktemp -d "${TMPDIR:-/tmp}/reeldock-release.XXXXXX")
trap 'rm -rf "$work"' EXIT

cat > "$work/options.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$team</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>upload</string>
</dict></plist>
PLIST

xcodebuild archive -project ReelDock.xcodeproj -scheme ReelDock -configuration Release \
    -derivedDataPath "$work/derived" -archivePath "$work/ReelDock.xcarchive" -allowProvisioningUpdates -quiet
xcodebuild -exportArchive -archivePath "$work/ReelDock.xcarchive" -exportOptionsPlist "$work/options.plist" \
    -exportPath "$work/upload" -allowProvisioningUpdates -quiet

echo "Waiting for notarization…"
for attempt in {1..60}; do
    if xcodebuild -exportNotarizedApp -archivePath "$work/ReelDock.xcarchive" -exportPath "$work/notarized" >"$work/export.log" 2>&1; then
        break
    fi
    grep -q "processing" "$work/export.log" || { cat "$work/export.log" >&2; exit 1; }
    (( attempt < 60 )) || { echo "Notarization timed out" >&2; exit 1; }
    /bin/sleep 30
done

zsh scripts/package-dmg.sh "$work/notarized/ReelDock.app" "$output" "$team"
echo "$output"
