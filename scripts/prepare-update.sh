#!/bin/zsh
# Usage: prepare-update.sh <tag> <dmg> <Sparkle bin directory>
# Adds a release to appcast.xml, signed with the key in the login Keychain. Publishes nothing.
# Upload the DMG to the GitHub release and check it before pushing the appcast that points at it.
set -euo pipefail
cd "${0:A:h:h}"
tag="$1"
dmg="$2"
bin="$3"
[[ -f "$dmg" && "${dmg:e:l}" == dmg ]] || { echo "Expected a .dmg: $dmg" >&2; exit 66; }

work=$(mktemp -d "${TMPDIR:-/tmp}/reeldock-appcast.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$dmg" "$work/"
[[ ! -f appcast.xml ]] || cp appcast.xml "$work/appcast.xml"

"$bin/generate_appcast" \
    --account cc.raycal.ReelDock \
    --download-url-prefix "https://github.com/raycalrui/ReelDock/releases/download/$tag/" \
    --link "https://github.com/raycalrui/ReelDock/releases/tag/$tag" \
    --full-release-notes-url "https://github.com/raycalrui/ReelDock/releases/tag/$tag" \
    --maximum-deltas 0 \
    -o "$PWD/appcast.xml" \
    "$work"
echo "Updated appcast.xml"
