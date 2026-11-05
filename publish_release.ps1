param([Parameter(Mandatory = $true)][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')][string]$Tag)
$ErrorActionPreference = 'Stop'
$releaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$apk = Join-Path $releaseDir 'idlerfox.apk'
$manifest = Join-Path $releaseDir 'latest.json'
if (!(Test-Path $apk) -or !(Test-Path $manifest)) { throw 'Prepare and review the APK and latest.json first.' }
$data = Get-Content $manifest -Raw | ConvertFrom-Json
if ($data.apk_url -notmatch "/releases/download/$([regex]::Escape($Tag))/idlerfox\.apk$") { throw 'Manifest APK URL does not match this release tag.' }
gh release view $Tag --json isDraft,assets | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Draft release $Tag was not found." }
$release = gh release view $Tag --json isDraft,assets | ConvertFrom-Json
if (!$release.isDraft) { throw 'This release is already published. Published assets must not be replaced.' }
$names = @($release.assets | ForEach-Object name)
if ($names -notcontains 'idlerfox.apk' -or $names -notcontains 'latest.json') { throw 'Draft release must already contain idlerfox.apk and latest.json. Verify those assets before publishing.' }
gh release edit $Tag --draft=false
if ($LASTEXITCODE -ne 0) { throw 'Publishing GitHub Release failed.' }
Write-Host "Published $Tag. Stable latest.json is now served by GitHub Releases."
