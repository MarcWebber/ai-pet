#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
mac_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_root/Resources/Info.plist")"

test -n "$mac_version"

verify_checksum() {
  artifact="$1"
  if test -f "$artifact"; then
    checksum="$artifact.sha256"
    test -f "$checksum"
    artifact_dir="$(dirname "$artifact")"
    (
      cd "$artifact_dir"
      shasum -a 256 -c "$(basename "$checksum")"
    )
  fi
}

verify_checksum "$repo_root/dist/JellyPet-$mac_version-macos.dmg"
echo "JellyPet version: $mac_version"
