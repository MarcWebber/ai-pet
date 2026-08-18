#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
app="$repo_root/dist/JellyPet.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_root/Resources/Info.plist")"
dmg="$repo_root/dist/JellyPet-$version-macos.dmg"
checksum_file="$dmg.sha256"
staging="$(mktemp -d "${TMPDIR:-/tmp}/jellypet-dmg.XXXXXX")"

cleanup() { rm -rf "$staging"; }
trap cleanup EXIT

bash "$repo_root/scripts/build-app.sh"
if test -n "${JELLY_DEVELOPER_ID:-}"; then
  codesign --force --deep --options runtime --timestamp \
    --sign "$JELLY_DEVELOPER_ID" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
fi

cp -R "$app" "$staging/JellyPet.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg" "$checksum_file"
hdiutil create -volname "JellyPet" -srcfolder "$staging" \
  -ov -format UDZO "$dmg"

if test -n "${JELLY_NOTARY_PROFILE:-}"; then
  xcrun notarytool submit "$dmg" \
    --keychain-profile "$JELLY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi

checksum="$(shasum -a 256 "$dmg" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$(basename "$dmg")" >"$checksum_file"
echo "$dmg"
echo "$checksum_file"
