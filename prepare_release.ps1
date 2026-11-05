param(
    [Parameter(Mandatory = $true)][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')][string]$Tag,
    [Parameter(Mandatory = $true)][string]$GodotExe,
    [string]$ReleaseKeystore = (Join-Path $env:USERPROFILE '.android\idlerfox-release.keystore'),
    [string]$KeyAlias = 'androiddebugkey',
    [string]$KeyPassword = 'android',
    [string]$ExpectedSignerSha256 = 'fa478fbfcf01dc5474a539dde21094244ad2a86d409a3651c9799eb2a7e66f6c'
)
$ErrorActionPreference = 'Stop'
$releaseRepo = 'caplyayadu-cmyk/idler_fox_tamagochi_game_apk'
$releaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $releaseDir
$preset = Get-Content (Join-Path $projectDir 'export_presets.cfg') -Raw
$projectConfig = Get-Content (Join-Path $projectDir 'project.godot') -Raw
$versionMatch = [regex]::Match($preset, '(?m)^version/code=(\d+)\s*$')
$nameMatch = [regex]::Match($preset, '(?m)^version/name="([^"]+)"\s*$')
$packageMatch = [regex]::Match($preset, '(?m)^package/unique_name="([^"]+)"\s*$')
if (!$versionMatch.Success -or !$nameMatch.Success -or !$packageMatch.Success) { throw 'Could not read Android version and package settings.' }
$versionCode = [int]$versionMatch.Groups[1].Value
$versionName = $nameMatch.Groups[1].Value
$packageName = $packageMatch.Groups[1].Value
if ($projectConfig -notmatch "(?m)^config/version_code=$versionCode\s*$") { throw 'project.godot config/version_code must match Android export preset version/code.' }
if ($Tag -ne "v$versionName") { throw "Tag $Tag does not match export preset version $versionName." }
if (!(Test-Path -LiteralPath $ReleaseKeystore)) { throw "Signing key was not found: $ReleaseKeystore. Keep it outside both repositories and make a protected backup." }
$apk = Join-Path $releaseDir 'idlerfox.apk'
if (Test-Path -LiteralPath $apk) { Remove-Item -LiteralPath $apk -Force }
$presetPath = Join-Path $projectDir 'export_presets.cfg'
$androidManifestPath = Join-Path $projectDir 'android\build\src\main\AndroidManifest.xml'
$bridgeSource = Join-Path $projectDir 'tools\updater_bridge\UpdaterBridge.java'
$bridgeTarget = Join-Path $projectDir 'android\build\src\main\java\com\idlerfox\updater\UpdaterBridge.java'
if (!(Test-Path -LiteralPath $androidManifestPath) -or !(Test-Path -LiteralPath $bridgeSource)) { throw 'Install the Android build template and keep tools/updater_bridge/UpdaterBridge.java in the project.' }
$presetBytes = [System.IO.File]::ReadAllBytes($presetPath)
$manifestBytes = [System.IO.File]::ReadAllBytes($androidManifestPath)
$presetText = [System.Text.Encoding]::UTF8.GetString($presetBytes)
$presetText = $presetText.Replace('keystore/release=""', 'keystore/release="' + $ReleaseKeystore.Replace('\', '/') + '"')
$presetText = $presetText.Replace('keystore/release_user=""', 'keystore/release_user="' + $KeyAlias + '"')
$presetText = $presetText.Replace('keystore/release_password=""', 'keystore/release_password="' + $KeyPassword + '"')
try {
    $manifestText = [System.Text.Encoding]::UTF8.GetString($manifestBytes)
    $pluginMetadata = '<meta-data android:name="org.godotengine.plugin.v2.UpdaterBridge" android:value="com.idlerfox.updater.UpdaterBridge" />'
    if ($manifestText -notmatch 'org\.godotengine\.plugin\.v2\.UpdaterBridge') {
        if ($manifestText -notmatch '</application>') { throw 'Android manifest has no application element.' }
        $manifestText = $manifestText.Replace('</application>', "        $pluginMetadata`r`n    </application>")
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $bridgeTarget) -Force | Out-Null
    Copy-Item -LiteralPath $bridgeSource -Destination $bridgeTarget -Force
    [System.IO.File]::WriteAllText($androidManifestPath, $manifestText, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($presetPath, $presetText, [System.Text.UTF8Encoding]::new($false))
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $arguments = '--headless --path "{0}" --export-release Android "{1}"' -f $projectDir, $apk
    $exportProcess = Start-Process -FilePath $GodotExe -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $exportSucceeded = $false
    $stableSince = $null
    $deadline = [DateTime]::UtcNow.AddMinutes(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        $stdout = if (Test-Path $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        $exportLog = $stdout + "`n" + $stderr
        $exportStart = $exportLog.IndexOf('Started Exporting for Android')
        $doneAfterStart = $exportStart -ge 0 -and $exportLog.IndexOf('[ DONE ]', $exportStart) -ge 0
        if (Test-Path -LiteralPath $apk) {
            $sizeNow = (Get-Item -LiteralPath $apk).Length
            if ($doneAfterStart -and $sizeNow -gt 1MB) {
                if ($null -eq $stableSince) { $stableSince = [DateTime]::UtcNow }
                if (([DateTime]::UtcNow - $stableSince).TotalSeconds -ge 4) {
                    $exportSucceeded = $true
                    break
                }
            } else {
                $stableSince = $null
            }
        }
        $exportProcess.Refresh()
        if ($exportProcess.HasExited) {
            $exportSucceeded = $exportProcess.ExitCode -eq 0
            break
        }
        Start-Sleep -Seconds 1
    }
    if (!$exportProcess.HasExited) { Stop-Process -Id $exportProcess.Id -Force -ErrorAction SilentlyContinue }
    if (!$exportSucceeded) { throw "Godot export failed or timed out. See $stdoutPath and $stderrPath" }
} finally {
    [System.IO.File]::WriteAllBytes($presetPath, $presetBytes)
    [System.IO.File]::WriteAllBytes($androidManifestPath, $manifestBytes)
    Remove-Item -LiteralPath $bridgeTarget -Force -ErrorAction SilentlyContinue
}
if (!(Test-Path -LiteralPath $apk)) { throw 'Godot Android export produced no APK.' }
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
$signerDigest = ($signerLine -split ':')[-1].Trim().ToLowerInvariant()
if ($signerDigest -ne $ExpectedSignerSha256.ToLowerInvariant()) { throw "APK signer differs from the installed release certificate. Expected $ExpectedSignerSha256, got $signerDigest." }
$sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $apk).Length
$changelogText = Get-Content (Join-Path $releaseDir 'CHANGELOG.md') -Raw
$releaseNotesMatch = [regex]::Match($changelogText, "(?ms)^## v$([regex]::Escape($versionName))\s*(.*?)(?=^## |\z)")
if (!$releaseNotesMatch.Success) { throw "CHANGELOG.md has no section for version $versionName." }
$changelog = $releaseNotesMatch.Groups[1].Value.Trim()
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
$draft = gh release view $Tag --repo $releaseRepo --json isDraft 2>$null
if ($LASTEXITCODE -eq 0) {
    if (!($draft | ConvertFrom-Json).isDraft) { throw 'That tag is already published. Create a new version and tag; published assets cannot be replaced.' }
} else {
    $notes = Join-Path $releaseDir 'CHANGELOG.md'
    gh release create $Tag --repo $releaseRepo --draft --title "Idler Fox $versionName" --notes-file $notes
    if ($LASTEXITCODE -ne 0) { throw 'Could not create a draft release. Check gh login and the release repository remote.' }
}
gh release upload $Tag $apk (Join-Path $releaseDir 'latest.json') --repo $releaseRepo --clobber
if ($LASTEXITCODE -ne 0) { throw 'Could not upload both release assets to the draft. Inspect the draft before retrying.' }
Write-Host 'Draft created and assets uploaded. Review the draft assets, version, size and checksum, then run publish_release.ps1 explicitly.'
