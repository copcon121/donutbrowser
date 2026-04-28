<#
.SYNOPSIS
    Export full Donut Browser profile (fingerprint + cookies + history + extensions + proxy + vpn)
    into a single .zip file that can be moved to another machine.

.DESCRIPTION
    Looks up profile by name (case-insensitive) inside %LOCALAPPDATA%\DonutBrowser\profiles,
    then bundles:
      - The full <UUID> folder (metadata.json + profile/ data + os_crypt_key)
      - Referenced proxy config (if profile has a proxy_id)
      - Referenced VPN config (if profile has a vpn_id)
    into a portable zip archive.

.PARAMETER ProfileName
    Exact display name of the profile (as shown in Donut UI). Case-insensitive.

.PARAMETER OutputPath
    Full path of the output .zip file. If omitted, defaults to
    <Desktop>\donut-profile-<name>-<timestamp>.zip

.PARAMETER Force
    Overwrite existing output file without prompting.

.EXAMPLE
    .\export-donut-profile.ps1 -ProfileName "MyAccount"

.EXAMPLE
    .\export-donut-profile.ps1 -ProfileName "Work" -OutputPath "D:\backups\work.zip" -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProfileName,

    [Parameter(Position = 1)]
    [string]$OutputPath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Locate Donut data directory
# ---------------------------------------------------------------------------
$dataDir = Join-Path $env:LOCALAPPDATA 'DonutBrowser'
if (-not (Test-Path $dataDir)) {
    throw "Donut data dir not found: $dataDir. Has Donut Browser ever been launched on this machine?"
}

$profilesDir = Join-Path $dataDir 'profiles'
$proxiesDir  = Join-Path $dataDir 'proxies'
$vpnDir      = Join-Path $dataDir 'vpn'

if (-not (Test-Path $profilesDir)) {
    throw "No profiles directory at: $profilesDir"
}

# ---------------------------------------------------------------------------
# 2. Refuse to run while Donut is open (DBs would be corrupted)
# ---------------------------------------------------------------------------
$running = Get-Process -Name 'donutbrowser','wayfern','camoufox' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "[!] Donut Browser (or Wayfern/Camoufox) is currently running:" -ForegroundColor Yellow
    $running | Format-Table Id, ProcessName, MainWindowTitle -AutoSize
    throw 'Please close Donut Browser fully before exporting (cookies/history are SQLite DBs and can corrupt if copied while open).'
}

# ---------------------------------------------------------------------------
# 3. Find the profile UUID folder by display name (from metadata.json)
# ---------------------------------------------------------------------------
$matches = @()
Get-ChildItem -Path $profilesDir -Directory | ForEach-Object {
    $metaFile = Join-Path $_.FullName 'metadata.json'
    if (Test-Path $metaFile) {
        try {
            $meta = Get-Content -Raw -LiteralPath $metaFile | ConvertFrom-Json
            if ($meta.name -and ($meta.name -ieq $ProfileName)) {
                $matches += [pscustomobject]@{
                    Uuid     = $_.Name
                    Path     = $_.FullName
                    Browser  = $meta.browser
                    Version  = $meta.version
                    ProxyId  = $meta.proxy_id
                    VpnId    = $meta.vpn_id
                    Metadata = $meta
                }
            }
        } catch {
            Write-Verbose "Skipping $($_.FullName): cannot parse metadata.json ($_)"
        }
    }
}

if ($matches.Count -eq 0) {
    Write-Host "Available profiles in $profilesDir :" -ForegroundColor Cyan
    Get-ChildItem -Path $profilesDir -Directory | ForEach-Object {
        $m = Join-Path $_.FullName 'metadata.json'
        if (Test-Path $m) {
            try {
                $j = Get-Content -Raw -LiteralPath $m | ConvertFrom-Json
                Write-Host ("  - {0,-30} ({1})" -f $j.name, $_.Name)
            } catch {}
        }
    }
    throw "Profile named '$ProfileName' not found."
}
if ($matches.Count -gt 1) {
    Write-Host "Multiple profiles share the name '$ProfileName':" -ForegroundColor Yellow
    $matches | Format-Table Uuid, Browser, Version -AutoSize
    throw 'Rename one of them first or pass the exact UUID via the manual flow.'
}

$profile = $matches[0]
Write-Host "[*] Found profile '$ProfileName'" -ForegroundColor Green
Write-Host "    UUID    : $($profile.Uuid)"
Write-Host "    Browser : $($profile.Browser) ($($profile.Version))"
Write-Host "    Path    : $($profile.Path)"

# ---------------------------------------------------------------------------
# 4. Prepare staging dir
# ---------------------------------------------------------------------------
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeName  = ($ProfileName -replace '[^\w\-\.]+', '_')
$staging   = Join-Path $env:TEMP "donut-export-$safeName-$stamp"

if (-not $OutputPath) {
    $desktop    = [Environment]::GetFolderPath('Desktop')
    $OutputPath = Join-Path $desktop "donut-profile-$safeName-$stamp.zip"
}
if ((Test-Path $OutputPath) -and -not $Force) {
    throw "Output file already exists: $OutputPath  (use -Force to overwrite)"
}
if (Test-Path $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

New-Item -ItemType Directory -Force -Path $staging | Out-Null
Write-Host "[*] Staging at $staging" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 5. Copy the profile UUID folder
# ---------------------------------------------------------------------------
$stagingProfiles = Join-Path $staging 'profiles'
New-Item -ItemType Directory -Force -Path $stagingProfiles | Out-Null
$destProfile = Join-Path $stagingProfiles $profile.Uuid

Write-Host "[*] Copying profile data..." -ForegroundColor Cyan
# robocopy is faster + handles long paths better than Copy-Item for large profiles
$rcArgs = @($profile.Path, $destProfile, '/E', '/MT:8', '/R:1', '/W:1', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
$null = & robocopy @rcArgs
# robocopy uses non-zero exit codes for benign info; codes < 8 are NOT errors
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

# ---------------------------------------------------------------------------
# 6. Copy referenced proxy config (best-effort)
# ---------------------------------------------------------------------------
if ($profile.ProxyId -and (Test-Path $proxiesDir)) {
    Write-Host "[*] Looking for proxy config (proxy_id = $($profile.ProxyId))..." -ForegroundColor Cyan
    $stagingProxies = Join-Path $staging 'proxies'
    New-Item -ItemType Directory -Force -Path $stagingProxies | Out-Null

    # Donut stores proxies as <id>.json (or under subfolder). Match defensively.
    $proxyMatches = Get-ChildItem -Path $proxiesDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq $profile.ProxyId -or $_.Name -like "*$($profile.ProxyId)*" }

    if ($proxyMatches) {
        foreach ($pm in $proxyMatches) {
            $rel = $pm.FullName.Substring($proxiesDir.Length).TrimStart('\','/')
            $dst = Join-Path $stagingProxies $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $pm.FullName -Destination $dst -Force
        }
        Write-Host "    [+] Bundled $($proxyMatches.Count) proxy file(s)" -ForegroundColor Green
    } else {
        Write-Host "    [!] proxy_id referenced but no matching file found; profile will fall back to direct connection on import" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# 7. Copy referenced VPN config
# ---------------------------------------------------------------------------
if ($profile.VpnId -and (Test-Path $vpnDir)) {
    Write-Host "[*] Looking for VPN config (vpn_id = $($profile.VpnId))..." -ForegroundColor Cyan
    $stagingVpn = Join-Path $staging 'vpn'
    New-Item -ItemType Directory -Force -Path $stagingVpn | Out-Null

    $vpnMatches = Get-ChildItem -Path $vpnDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq $profile.VpnId -or $_.Name -like "*$($profile.VpnId)*" }
    if ($vpnMatches) {
        foreach ($vm in $vpnMatches) {
            $rel = $vm.FullName.Substring($vpnDir.Length).TrimStart('\','/')
            $dst = Join-Path $stagingVpn $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $vm.FullName -Destination $dst -Force
        }
        Write-Host "    [+] Bundled $($vpnMatches.Count) VPN file(s)" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 8. Manifest for the importer
# ---------------------------------------------------------------------------
$manifest = [ordered]@{
    schema       = 'donut-profile-export/v1'
    exported_at  = (Get-Date).ToString('o')
    source_host  = $env:COMPUTERNAME
    source_user  = $env:USERNAME
    profile = [ordered]@{
        uuid    = $profile.Uuid
        name    = $profile.Metadata.name
        browser = $profile.Browser
        version = $profile.Version
        proxy_id = $profile.ProxyId
        vpn_id   = $profile.VpnId
    }
}
$manifestPath = Join-Path $staging 'donut-export.json'
$manifest | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $manifestPath -Encoding utf8

# ---------------------------------------------------------------------------
# 9. Zip everything
# ---------------------------------------------------------------------------
Write-Host "[*] Compressing..." -ForegroundColor Cyan
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutputPath -CompressionLevel Optimal -Force

# ---------------------------------------------------------------------------
# 10. Cleanup staging
# ---------------------------------------------------------------------------
Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

$sizeMB = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1MB, 2)
Write-Host ""
Write-Host "[OK] Export complete." -ForegroundColor Green
Write-Host "     File : $OutputPath"
Write-Host "     Size : $sizeMB MB"
Write-Host ""
Write-Host "Move this .zip to the target machine, then run:" -ForegroundColor Cyan
Write-Host "  .\import-donut-profile.ps1 -ZipPath '<path-to-zip>'"
