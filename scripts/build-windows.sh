#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
project="$repo_root/windows/JellyPet.Windows/JellyPet.Windows.csproj"
version="$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$project" | head -n 1)"
output="$repo_root/dist/windows/JellyPet-$version-windows-x64-test"
archive="$output.zip"
checksum_file="$archive.sha256"
dotnet_bin="${DOTNET_BIN:-$(command -v dotnet || true)}"

test -n "$version"
if test -z "$dotnet_bin"; then
  echo "需要 .NET 10 SDK 才能构建 Windows 应用。" >&2
  exit 1
fi
case "$output" in
  "$repo_root"/dist/windows/JellyPet-*-windows-x64-test) ;;
  *) echo "拒绝清理意外的输出路径：$output" >&2; exit 2 ;;
esac

export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-$repo_root/.build/windows-dotnet-home}"
export NUGET_PACKAGES="${NUGET_PACKAGES:-$repo_root/.build/windows-nuget}"
mkdir -p "$DOTNET_CLI_HOME" "$NUGET_PACKAGES" "$repo_root/dist/windows"
rm -rf "$output"
rm -f "$archive" "$checksum_file"

"$dotnet_bin" publish "$project" \
  --configuration Release \
  --runtime win-x64 \
  --self-contained true \
  --output "$output" \
  -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:DebugType=None \
  -p:DebugSymbols=false \
  -p:NuGetAudit=false

install -m 644 "$repo_root/windows/install.ps1" "$output/install.ps1"
install -m 644 "$repo_root/windows/uninstall.ps1" "$output/uninstall.ps1"
install -m 644 "$repo_root/windows/README-WINDOWS.txt" "$output/README-WINDOWS.txt"

commit="$(git -C "$repo_root" rev-parse --short HEAD)"
source_state="clean"
if test -n "$(git -C "$repo_root" status --porcelain)"; then
  source_state="contains uncommitted changes"
fi
printf '%s\n' \
  "JellyPet Windows Test Build" \
  "Version: $version" \
  "Runtime: win-x64, self-contained, single-file" \
  "Source baseline: $commit ($source_state)" \
  "Built at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  "Build host: $(uname -s) $(uname -m)" \
  "Verification: compiled and published on macOS; Windows runtime must be checked by the tester" \
  >"$output/BUILD-INFO.txt"

test -f "$output/JellyPet.exe"
test -f "$output/Skills/human-exam-taking/SKILL.md"
test -f "$output/README-WINDOWS.txt"
file "$output/JellyPet.exe" | grep -q 'PE32+ executable.*x86-64'

/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "$output" "$archive"
checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$(basename "$archive")" >"$checksum_file"

echo "$archive"
echo "$checksum_file"
