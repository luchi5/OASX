param(
    [Parameter(Mandatory)][string]$ReleaseTag,
    [string]$BuildName = '0.3.9',
    [Parameter(Mandatory)][string]$BuildNumber
)
$ErrorActionPreference = 'Stop'
if ($ReleaseTag -notmatch '^luchi-[0-9]{4}\.[0-9]{2}\.[0-9]{2}([.-][a-zA-Z0-9]+)?$') { throw 'Invalid release label' }
if ($BuildName -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or $BuildNumber -notmatch '^[1-9][0-9]{0,8}$') { throw 'Invalid build version' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$release = Join-Path $root 'build/windows/x64/runner/Release'
foreach ($required in @('oasx.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z')) {
    if (!(Test-Path -LiteralPath (Join-Path $release $required) -PathType Leaf)) { throw "Missing release file: $required" }
}
$releaseItems = @(Get-ChildItem -LiteralPath $release -Recurse -Force)
foreach ($item in $releaseItems) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release output contains a reparse point' }
    if ($item.FullName -match '[\\/](profile[^\\/]*|logs?|config|toolkit|\.git)[\\/]' -or $item.Extension -in @('.pdb', '.log', '.gs', '.bak', '.key', '.pem', '.pfx')) {
        throw "Unexpected private/debug file in release: $($item.Name)"
    }
}
$artifactDir = Join-Path $root 'artifacts'
$packageRoot = Join-Path $artifactDir "oasx_$ReleaseTag"
if (Test-Path -LiteralPath $packageRoot) { throw 'Package directory already exists; use a clean build workspace' }
$appDir = Join-Path $packageRoot 'app'
New-Item -ItemType Directory -Path $appDir -Force | Out-Null
Get-ChildItem -LiteralPath $release -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $appDir -Recurse }

# App-local Microsoft CRT files let recipients run without a developer SDK.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio redistributable locator is missing' }
$vsRoot = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
if (!$vsRoot) { throw 'Visual Studio C++ redistributable installation is missing' }
$crtDirectories = @(Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC/Redist/MSVC') -Directory | Sort-Object Name -Descending | ForEach-Object {
    Get-ChildItem -LiteralPath (Join-Path $_.FullName 'x64') -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^Microsoft\.VC[0-9]+\.CRT$'
})
$crt = $crtDirectories | Select-Object -First 1
if (!$crt) { throw 'Windows x64 CRT redistributable directory is missing' }
foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    $source = Join-Path $crt.FullName $name
    if (!(Test-Path -LiteralPath $source)) { throw "Missing CRT: $name" }
    Copy-Item -LiteralPath $source -Destination $appDir -Force
}

Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $root 'THIRD_PARTY_NOTICES.md') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $root 'assets/Lato-OFL.txt') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $root 'dev_tools/WINDOWS-使用说明.txt') -Destination (Join-Path $packageRoot '使用说明.txt')
$launcher = "@echo off`r`ncd /d `"%~dp0`"`r`nstart `"`" `"%~dp0app\oasx.exe`"`r`n"
[IO.File]::WriteAllText((Join-Path $packageRoot '启动OASX.cmd'), $launcher, [Text.Encoding]::ASCII)
$commit = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot identify build source' }
$files = @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse | Sort-Object FullName | ForEach-Object {
    @{ path = [IO.Path]::GetRelativePath($packageRoot, $_.FullName).Replace('\', '/'); bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$metadata = @{
    source = "https://github.com/luchi5/OASX/tree/$commit"
    commit = $commit
    release_tag = $ReleaseTag
    windows_version = "$BuildName+$BuildNumber"
    flutter = '3.35.1'
    architecture = 'windows-x64'
    preview = $false
    files = $files
}
$metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $packageRoot 'build-info.json') -Encoding utf8
$zip = Join-Path $artifactDir "oasx_$($ReleaseTag)_windows_x64.zip"
Compress-Archive -LiteralPath $packageRoot -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $artifactDir 'SHA256SUMS.txt'), "$hash  $([IO.Path]::GetFileName($zip))`n", [Text.Encoding]::ASCII)
Write-Output "Packaged $([IO.Path]::GetFileName($zip)) ($hash)"
