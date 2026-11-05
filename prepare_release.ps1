param(
    [Parameter(Mandatory = $true)][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')][string]$Tag,
    [Parameter(Mandatory = $true)][string]$GodotExe,
    [string]$ReleaseKeystore = (Join-Path $env:USERPROFILE '.android\idlerfox-release.keystore'),
    [string]$KeyAlias = 'androiddebugkey',
    [string]$KeyPassword = 'android'
)
$ErrorActionPreference = 'Stop'
$releaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $releaseDir
$preset = Get-Content (Join-Path $projectDir 'export_presets.cfg') -Raw
$versionMatch = [regex]::Match($preset, '(?m)^version/code=(\d+)\s*$')
$nameMatch = [regex]::Match($preset, '(?m)^version/name="([^"]+)"\s*$')
$packageMatch = [regex]::Match($preset, '(?m)^package/unique_name="([^"]+)"\s*$')
if (!$versionMatch.Success -or !$nameMatch.Success -or !$packageMatch.Success) { throw 'Could not read Android version and package settings.' }
$versionCode = [int]$versionMatch.Groups[1].Value
$versionName = $nameMatch.Groups[1].Value
$packageName = $packageMatch.Groups[1].Value
if ($Tag -ne "v$versionName") { throw "Tag $Tag does not match export preset version $versionName." }
if (!(Test-Path -LiteralPath $ReleaseKeystore)) { throw "Signing key was not found: $ReleaseKeystore. Keep it outside both repositories and make a protected backup." }
$apk = Join-Path $releaseDir 'idlerfox.apk'
if (Test-Path -LiteralPath $apk) { Remove-Item -LiteralPath $apk -Force }
$presetPath = Join-Path $projectDir 'export_presets.cfg'
$presetBytes = [System.IO.File]::ReadAllBytes($presetPath)
$presetText = [System.Text.Encoding]::UTF8.GetString($presetBytes)
$presetText = [regex]::Replace($presetText, '(?m)^keystore/release="[^"]*"$', 'keystore/release="' + $ReleaseKeystore.Replace('\', '/') + '"')
$presetText = [regex]::Replace($presetText, '(?m)^keystore/release_user="[^"]*"$', 'keystore/release_user="' + $KeyAlias + '"')
$presetText = [regex]::Replace($presetText, '(?m)^keystore/release_password="[^"]*"$', 'keystore/release_password="' + $KeyPassword + '"')
try {
    [System.IO.File]::WriteAllText($presetPath, $presetText, [System.Text.UTF8Encoding]::new($false))
    & $GodotExe --headless --path $projectDir --export-release Android $apk
} finally {
    [System.IO.File]::WriteAllBytes($presetPath, $presetBytes)
}
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $apk)) { throw 'Godot Android export failed.' }
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$buildTools = Get-ChildItem (Join-Path $sdk 'build-tools') -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (!$buildTools) { throw 'Android SDK build-tools were not found.' }
$aapt = Join-Path $buildTools.FullName 'aapt.exe'
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
if (!(Test-Path $aapt) -or !(Test-Path $apksigner)) { throw 'aapt or apksigner is missing from Android SDK build-tools.' }
$badging = & $aapt dump badging $apk
if ($LASTEXITCODE -ne 0 -or (($badging -join "`n") -notmatch "package: name='$([regex]::Escape($packageName))'")) { throw "APK package name does not match $packageName." }
$versionText = $badging -join "`n"
if ($versionText -notmatch "versionCode='$versionCode'" -or $versionText -notmatch "versionName='$([regex]::Escape($versionName))'") { throw 'APK version metadata does not match export preset.' }
$verify = & $apksigner verify --print-certs $apk 2>&1
if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed: $verify" }
$signerLine = ($verify | Select-String 'Signer #1 certificate SHA-256 digest:').Line
if (!$signerLine) { throw 'Could not read APK signer certificate digest.' }
$sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $apk).Length
$changelog = Get-Content (Join-Path $releaseDir 'CHANGELOG.md') -Raw
$manifest = [ordered]@{
    version_name = $versionName
    version_code = $versionCode
    package_name = $packageName
    apk_url = "https://github.com/caplyayadu-cmyk/idler_fox_tamagochi_game_apk/releases/download/$Tag/idlerfox.apk"
    size = $size
    sha256 = $sha256
    changelog = $changelog.Trim()
}
$manifestJson = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $releaseDir 'latest.json'), $manifestJson, [System.Text.UTF8Encoding]::new($false))
Write-Host "Built: $apk"
Write-Host "Version: $versionName ($versionCode), package: $packageName"
Write-Host "Size: $size bytes, SHA-256: $sha256"
Write-Host $signerLine
$draft = gh release view $Tag --json isDraft 2>$null
if ($LASTEXITCODE -eq 0) {
    if (!($draft | ConvertFrom-Json).isDraft) { throw 'That tag is already published. Create a new version and tag; published assets cannot be replaced.' }
} else {
    $notes = Join-Path $releaseDir 'CHANGELOG.md'
    gh release create $Tag --draft --title "Idler Fox $versionName" --notes-file $notes
    if ($LASTEXITCODE -ne 0) { throw 'Could not create a draft release. Check gh login and the release repository remote.' }
}
gh release upload $Tag $apk (Join-Path $releaseDir 'latest.json') --clobber
if ($LASTEXITCODE -ne 0) { throw 'Could not upload both release assets to the draft. Inspect the draft before retrying.' }
Write-Host 'Draft created and assets uploaded. Review the draft assets, version, size and checksum, then run publish_release.ps1 explicitly.'
