#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
app="$repo_root/dist/JellyPet.app"
contents="$app/Contents"
compatible_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
build_cache_root="${TMPDIR:-/tmp}/jellypet-build-cache"

if test -z "${SDKROOT:-}" && test -d "$compatible_sdk"; then
  export SDKROOT="$compatible_sdk"
fi
mkdir -p "$build_cache_root/clang" "$build_cache_root/swiftpm"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$build_cache_root/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$build_cache_root/swiftpm}"

codex_bin="${JELLY_CODEX_PATH:-$(command -v codex || true)}"
codex_bundle_path="${codex_bin:-__CODEX_PATH__}"

cd "$repo_root"
bash "$repo_root/scripts/build-icon.sh"
swift build --disable-sandbox -c release --product JellyPet
bin_dir="$(swift build --disable-sandbox -c release --show-bin-path)"

if test "$app" != "$repo_root/dist/JellyPet.app"; then
  echo "Refusing to replace an unexpected app path: $app" >&2
  exit 1
fi

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
install -m 755 "$bin_dir/JellyPet" "$contents/MacOS/JellyPet"
resource_bundle="$bin_dir/JellyPet_JellyApp.bundle"
test -d "$resource_bundle"
install -m 644 \
  "$resource_bundle/PetSprites.png" \
  "$contents/Resources/PetSprites.png"
skill_source="$resource_bundle/Skills/human-exam-taking/SKILL.md"
skill_target="$contents/Resources/Skills/human-exam-taking"
test -f "$skill_source"
mkdir -p "$skill_target"
install -m 644 "$skill_source" "$skill_target/SKILL.md"
install -m 644 "$repo_root/Resources/Info.plist" "$contents/Info.plist"
install -m 644 \
  "$repo_root/Resources/AppIcon.icns" \
  "$contents/Resources/AppIcon.icns"
cp -R "$repo_root/Resources/Sounds" "$contents/Resources/Sounds"
/usr/libexec/PlistBuddy \
  -c "Set :JellyCodexPath $codex_bundle_path" \
  "$contents/Info.plist"
codesign \
  --force \
  --deep \
  --sign - \
  --requirements '=designated => identifier "com.local.JellyPet"' \
  "$app"
echo "$app"
