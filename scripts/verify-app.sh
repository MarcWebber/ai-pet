#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
app="$repo_root/dist/JellyPet.app"
plist="$app/Contents/Info.plist"

test -x "$app/Contents/MacOS/JellyPet"
test -f "$plist"
test -f "$app/Contents/Resources/PetSprites.png"
test -f "$app/Contents/Resources/JellyPetConfig.json"
jq -e '
  .schemaVersion == 2
  and .conversation.historyTurns == 8
  and .assistant.model == "auto"
  and .assistant.reasoningEffort == "high"
  and .beta.screenTakeover == true
' "$app/Contents/Resources/JellyPetConfig.json" >/dev/null
test -f "$app/Contents/Resources/Skills/jellypet-takeover/SKILL.md"
test -f "$app/Contents/Resources/AppIcon.icns"
test -f "$app/Contents/Resources/Sounds/capture.wav"
test -f "$app/Contents/Resources/Sounds/thinking.wav"
test -f "$app/Contents/Resources/Sounds/answer.wav"
test -f "$app/Contents/Resources/Sounds/error.wav"
test -f "$app/Contents/Resources/Sounds/dock.wav"
plutil -lint "$plist"
test "$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist"
)" = "com.local.JellyPet"
test "$(
  /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$plist"
)" = "true"
test "$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$plist"
)" = "AppIcon"
test -n "$(
  /usr/libexec/PlistBuddy \
    -c "Print :NSScreenCaptureUsageDescription" \
    "$plist"
)"
if /usr/libexec/PlistBuddy -c "Print :JellyCodexPath" "$plist" \
    >/dev/null 2>&1; then
  echo "JellyCodexPath compatibility key must not be packaged." >&2
  exit 1
fi
codesign --verify --deep --strict "$app"
requirements="$(codesign -d --requirements - "$app" 2>&1)"
case "$requirements" in
  *'designated => identifier "com.local.JellyPet"'*) ;;
  *)
    echo "JellyPet is missing its stable designated requirement." >&2
    exit 1
    ;;
esac
"$app/Contents/MacOS/JellyPet" --verify-resources
if test "${JELLY_SKIP_GUI_VERIFY:-0}" = "1"; then
  echo "Skipped packaged GUI verification in the outer sandbox."
else
  "$app/Contents/MacOS/JellyPet" --verify-visuals
fi

echo "Verified $app"
