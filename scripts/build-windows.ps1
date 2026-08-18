param()

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$project = Join-Path $repo "windows\JellyPet.Windows\JellyPet.Windows.csproj"
[xml]$projectXML = Get-Content $project
$version = $projectXML.Project.PropertyGroup.Version | Select-Object -First 1
$output = Join-Path $repo "dist\windows\JellyPet-$version-windows-x64-test"
$archive = "$output.zip"
$checksumFile = "$archive.sha256"

if (Test-Path $output) { Remove-Item $output -Recurse -Force }
if (Test-Path $archive) { Remove-Item $archive -Force }
if (Test-Path $checksumFile) { Remove-Item $checksumFile -Force }
New-Item (Split-Path -Parent $output) -ItemType Directory -Force | Out-Null

dotnet publish $project -c Release -r win-x64 --self-contained true -o $output `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None -p:DebugSymbols=false -p:NuGetAudit=false

Copy-Item (Join-Path $repo "windows\install.ps1") $output
Copy-Item (Join-Path $repo "windows\uninstall.ps1") $output
Copy-Item (Join-Path $repo "windows\README-WINDOWS.txt") $output

$commit = (git -C $repo rev-parse --short HEAD).Trim()
$sourceState = if (git -C $repo status --porcelain) {
    "contains uncommitted changes"
} else {
    "clean"
}
$buildInfo = @(
    "JellyPet Windows Test Build"
    "Version: $version"
    "Runtime: win-x64, self-contained, single-file"
    "Source baseline: $commit ($sourceState)"
    "Built at: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    "Build host: Windows $env:PROCESSOR_ARCHITECTURE"
    "Verification: built on Windows; runtime still requires a separate launch check"
)
Set-Content (Join-Path $output "BUILD-INFO.txt") $buildInfo -Encoding UTF8

$executable = Join-Path $output "JellyPet.exe"
$skill = Join-Path $output "Skills\human-exam-taking\SKILL.md"
if (-not (Test-Path $executable)) { throw "发布结果缺少 JellyPet.exe。" }
if (-not (Test-Path $skill)) { throw "发布结果缺少 human-exam-taking Skill。" }

Compress-Archive -Path $output -DestinationPath $archive -CompressionLevel Optimal
$checksum = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content $checksumFile "$checksum  $(Split-Path $archive -Leaf)" -Encoding ASCII
Write-Host $archive
Write-Host $checksumFile
