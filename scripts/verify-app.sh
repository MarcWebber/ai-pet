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
  (has("schemaVersion") | not)
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
  echo "Obsolete JellyCodexPath key must not be packaged." >&2
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
sprite="$app/Contents/Resources/PetSprites.png"
width="$(sips -g pixelWidth "$sprite" | awk '/pixelWidth:/ {print $2}')"
height="$(sips -g pixelHeight "$sprite" | awk '/pixelHeight:/ {print $2}')"
test "$width" -gt 0
test "$width" -eq "$height"
test "$((width % 8))" -eq 0

echo "Verified $app"
