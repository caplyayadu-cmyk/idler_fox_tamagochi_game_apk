param([Parameter(Mandatory = $true)][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')][string]$Tag)
$ErrorActionPreference = 'Stop'
$releaseRepo = 'caplyayadu-cmyk/idler_fox_tamagochi_game_apk'
$releaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$apk = Join-Path $releaseDir 'idlerfox.apk'
$manifest = Join-Path $releaseDir 'latest.json'
if (!(Test-Path $apk) -or !(Test-Path $manifest)) { throw 'Prepare and review the APK and latest.json first.' }
$data = Get-Content $manifest -Raw | ConvertFrom-Json
if ($data.apk_url -notmatch "/releases/download/$([regex]::Escape($Tag))/idlerfox\.apk$") { throw 'Manifest APK URL does not match this release tag.' }
gh release view $Tag --repo $releaseRepo --json isDraft,assets | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Draft release $Tag was not found." }
$release = gh release view $Tag --repo $releaseRepo --json isDraft,tagName,assets | ConvertFrom-Json
if (!$release.isDraft) { throw 'This release is already published. Published assets must not be replaced.' }
if ($release.tagName -ne $Tag) { throw 'GitHub draft tag does not match the requested release tag.' }
$localSize = (Get-Item -LiteralPath $apk).Length
$localHash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
if ($localSize -ne [int64]$data.size -or $localHash -ne $data.sha256.ToLowerInvariant()) { throw 'Local APK does not match latest.json. Rebuild the draft before publishing.' }
$names = @($release.assets | ForEach-Object name)
if ($names -notcontains 'idlerfox.apk' -or $names -notcontains 'latest.json') { throw 'Draft release must already contain idlerfox.apk and latest.json. Verify those assets before publishing.' }
$remoteApk = $release.assets | Where-Object name -eq 'idlerfox.apk' | Select-Object -First 1
if ([int64]$remoteApk.size -ne $localSize -or $remoteApk.digest -ne "sha256:$localHash") { throw 'Draft APK asset size or SHA-256 differs from the local release APK.' }
gh release edit $Tag --repo $releaseRepo --draft=false
if ($LASTEXITCODE -ne 0) { throw 'Publishing GitHub Release failed.' }
$manifestCopy = Join-Path $env:TEMP 'idlerfox-published-latest.json'
curl.exe --fail --location --silent --show-error --retry 3 'https://github.com/caplyayadu-cmyk/idler_fox_tamagochi_game_apk/releases/latest/download/latest.json' --output $manifestCopy
if ($LASTEXITCODE -ne 0) { throw 'Published release, but could not retrieve stable latest.json for post-publication verification.' }
$published = Get-Content $manifestCopy -Raw | ConvertFrom-Json
Remove-Item -LiteralPath $manifestCopy -Force
if ($published.version_code -ne $data.version_code -or $published.apk_url -ne $data.apk_url -or $published.sha256 -ne $data.sha256) { throw 'Published stable manifest does not match the reviewed release.' }
Write-Host "Published $Tag. Stable latest.json is now served by GitHub Releases."
