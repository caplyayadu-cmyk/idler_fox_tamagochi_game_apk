param(
    [Parameter(Mandatory)][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')][string]$Tag,
    [Parameter(Mandatory)][string]$GodotExe,
    [string]$ReleaseKeystore = (Join-Path $env:USERPROFILE '.android/idlerfox-release.keystore'),
    [string]$KeyAlias = 'androiddebugkey',
    [string]$KeyPassword = $(if ($env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD) { $env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD } else { 'android' }),
    [switch]$UploadDraft
)
$ErrorActionPreference = 'Stop'
$repo = 'caplyayadu-cmyk/idler_fox_tamagochi_game_apk'
$project = Split-Path -Parent $PSScriptRoot
$preset = Get-Content (Join-Path $project 'export_presets.cfg') -Raw
$config = Get-Content (Join-Path $project 'project.godot') -Raw
$code = [int][regex]::Match($preset, '(?m)^version/code=(\d+)\s*$').Groups[1].Value
$name = [regex]::Match($preset, '(?m)^version/name="([^"]+)"\s*$').Groups[1].Value
$package = 'com.idlerfox.game'
if ($code -lt 1 -or $Tag -cne "v$name" -or $config -notmatch "(?m)^config/version_code=$code\s*$") { throw 'Project, Android preset and tag versions must agree.' }
& (Join-Path $project 'tools/check_wardrobe.ps1') -GodotExe $GodotExe
$ReleaseKeystore = (Resolve-Path -LiteralPath $ReleaseKeystore).Path
if ($ReleaseKeystore.StartsWith($project + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Keep the signing key outside the project and release repository.'
}
$changelog = Get-Content (Join-Path $PSScriptRoot 'CHANGELOG.md') -Raw
$notes = [regex]::Match($changelog, "(?ms)^## $([regex]::Escape($Tag))\s*(.*?)(?=^## |\z)").Groups[1].Value.Trim()
if (!$notes -or $notes.Length -gt 8000) { throw 'Add release notes (1–8000 characters) to CHANGELOG.md.' }
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
$buildTools = Get-ChildItem (Join-Path $sdk 'build-tools') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$aapt = Join-Path $buildTools.FullName 'aapt.exe'
$signer = Join-Path $buildTools.FullName 'apksigner.bat'
$android = Join-Path $project 'android/build/src/main'
$manifestPath = Join-Path $android 'AndroidManifest.xml'
$manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
$bridge = Join-Path $android 'java/com/idlerfox/updater/UpdaterBridge.java'
$network = Join-Path $android 'java/com/idlerfox/updater/UpdateNetwork.java'
$paths = Join-Path $android 'res/xml/fox_update_paths.xml'
$source = Join-Path $project 'tools/updater_bridge'
$metadata = @"
        <meta-data android:name="org.godotengine.plugin.v2.UpdaterBridge" android:value="com.idlerfox.updater.UpdaterBridge" />
        <provider android:name="com.idlerfox.updater.UpdaterBridge`$UpdateFiles"
            android:authorities="$package.updates" android:exported="false" android:grantUriPermissions="true">
            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/fox_update_paths" />
        </provider>
"@
$stage = Join-Path $PSScriptRoot ('.stage-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stage
$apk = Join-Path $stage 'idlerfox.apk'
$json = Join-Path $stage 'latest.json'
$keys = @{
    GODOT_ANDROID_KEYSTORE_RELEASE_PATH = $ReleaseKeystore
    GODOT_ANDROID_KEYSTORE_RELEASE_USER = $KeyAlias
    GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD = $KeyPassword
}
$original = @{}
$injected = @{}
$manifestTouched = $false
try {
    foreach ($pair in @(@($bridge, 'UpdaterBridge.java'), @($network, 'UpdateNetwork.java'), @($paths, 'fox_update_paths.xml'))) {
        $target = $pair[0]
        $injected[$target] = if (Test-Path -LiteralPath $target) { ,([IO.File]::ReadAllBytes($target)) } else { $null }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)
        Copy-Item -LiteralPath (Join-Path $source $pair[1]) -Destination $target -Force
    }
    $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes)
    if ($manifest -match 'org\.godotengine\.plugin\.v2\.UpdaterBridge|fox_update_paths') { throw 'Remove stale updater declarations from the Android template.' }
    if ($manifest -notmatch '</application>') { throw 'Invalid Android template manifest.' }
    $manifestTouched = $true
    [IO.File]::WriteAllText($manifestPath, $manifest.Replace('</application>', "$metadata`n    </application>"))
    foreach ($key in $keys.Keys) {
        $original[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $keys[$key], 'Process')
    }
    $stdout = Join-Path $stage 'godot.stdout.log'
    $stderr = Join-Path $stage 'godot.stderr.log'
    $arguments = '--headless --path "{0}" --export-release Android "{1}"' -f $project, $apk
    $export = Start-Process -FilePath $GodotExe -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $deadline = [DateTime]::UtcNow.AddMinutes(20)
    $success = $false
    $stableCount = 0
    $previousSize = -1
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            $export.Refresh()
            if ($export.HasExited) {
                $success = $export.ExitCode -eq 0
                break
            }
            # Some Windows Godot builds hang on shutdown after completing the export.
            $log = Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
            if ($log -match '(?s)Started Exporting for Android.*\[ DONE \]' -and (Test-Path -LiteralPath $apk)) {
                $currentSize = (Get-Item -LiteralPath $apk).Length
                $stableCount = if ($currentSize -gt 0 -and $currentSize -eq $previousSize) { $stableCount + 1 } else { 0 }
                $previousSize = $currentSize
                if ($stableCount -ge 4) { $success = $true; break }
            }
            Start-Sleep -Seconds 1
        }
    } finally {
        if (!$export.HasExited) { Stop-Process -Id $export.Id -Force; $export.WaitForExit() }
    }
    if (!$success -or !(Test-Path -LiteralPath $apk)) { throw "Android export failed; previous APK retained. See $stdout and $stderr." }
} finally {
    foreach ($key in $original.Keys) { [Environment]::SetEnvironmentVariable($key, $original[$key], 'Process') }
    if ($manifestTouched) { [IO.File]::WriteAllBytes($manifestPath, $manifestBytes) }
    foreach ($target in $injected.Keys) {
        if ($null -ne $injected[$target]) { [IO.File]::WriteAllBytes($target, $injected[$target]) }
        else { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
    }
}
$badging = (& $aapt dump badging $apk) -join "`n"
if ($LASTEXITCODE -ne 0 -or $badging -notmatch "package: name='com\.idlerfox\.game' versionCode='$code' versionName='$([regex]::Escape($name))'" -or $badging -match '(?m)^application-debuggable') {
    throw 'APK package, version or debug flag is wrong.'
}
$entries = & $aapt list $apk
if ($LASTEXITCODE -ne 0 -or ($entries | Where-Object { $_ -match '(?i)(\.(keystore|jks|p12|pfx|apk|aab)$|^assets/(tools|tests|calculators|output|dev_rules|user_tools|idler_fox_tamagochi_game_apk)/|(?:^|/)(save\.json|\.env)(?:$|\.))' })) {
    throw 'APK contains non-release files or could not be inspected.'
}
$cert = & $signer verify --print-certs $apk
$expected = 'fa478fbfcf01dc5474a539dde21094244ad2a86d409a3651c9799eb2a7e66f6c'
if ($LASTEXITCODE -ne 0 -or @($cert | Select-String 'certificate SHA-256 digest:' | Where-Object { $_.Line -match '^Signer #' }).Count -ne 1 -or
    ($cert -join "`n") -notmatch "Signer #1 certificate SHA-256 digest: $expected") { throw 'APK signing certificate differs from the previous release.' }
$size = (Get-Item -LiteralPath $apk).Length
if ($size -lt 1 -or $size -gt 512MB) { throw 'APK size outside updater limits.' }
$hash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
$info = [ordered]@{version_name=$name; version_code=$code; package_name=$package; apk_url="https://github.com/$repo/releases/download/$Tag/idlerfox.apk"; size=$size; sha256=$hash; changelog=$notes}
[IO.File]::WriteAllText($json, ($info | ConvertTo-Json -Depth 4))
if ((Get-Item -LiteralPath $json).Length -gt 64KB) { throw 'Manifest size outside updater limits.' }
foreach ($file in @($apk, $json)) {
    $destination = Join-Path $PSScriptRoot (Split-Path -Leaf $file)
    if (Test-Path -LiteralPath $destination) { [IO.File]::Move($file, $destination, $true) }
    else { [IO.File]::Move($file, $destination) }
}
Remove-Item -LiteralPath $stdout, $stderr
Remove-Item -LiteralPath $stage
Write-Host "Built $Tag ($code), $size bytes, SHA-256 $hash"
if ($UploadDraft) {
    $draft = gh release view $Tag --repo $repo --json isDraft 2>$null
    if ($LASTEXITCODE -eq 0) {
        if (!($draft | ConvertFrom-Json).isDraft) { throw 'Published assets cannot be replaced.' }
    } else {
        gh release create $Tag --repo $repo --draft --title "Idler Fox $name" --notes $notes
        if ($LASTEXITCODE -ne 0) { throw 'Could not create release draft.' }
    }
    gh release upload $Tag (Join-Path $PSScriptRoot 'idlerfox.apk') (Join-Path $PSScriptRoot 'latest.json') --repo $repo --clobber
    if ($LASTEXITCODE -ne 0) { throw 'Could not upload draft files.' }
}
