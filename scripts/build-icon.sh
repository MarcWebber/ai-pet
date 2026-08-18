#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
source_png="$repo_root/Resources/AppIcon-source.png"
output="$repo_root/Resources/AppIcon.icns"
cache_root="${TMPDIR:-/private/tmp}/JellyPet-Icon-Swift-Cache"

test -f "$source_png"

if test "$output" != "$repo_root/Resources/AppIcon.icns"; then
  echo "Refusing to replace an unexpected icon path: $output" >&2
  exit 1
fi

mkdir -p "$cache_root/clang" "$cache_root/swift" "$cache_root/xdg"

env \
  CLANG_MODULE_CACHE_PATH="$cache_root/clang" \
  SWIFT_MODULECACHE_PATH="$cache_root/swift" \
  XDG_CACHE_HOME="$cache_root/xdg" \
  swift "$repo_root/scripts/build-icns.swift" "$source_png" "$output"

echo "$output"
