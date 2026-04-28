<#
.SYNOPSIS
    Import a Donut Browser profile zip created by export-donut-profile.ps1.

.DESCRIPTION
    Extracts a profile bundle into %LOCALAPPDATA%\DonutBrowser\, restoring:
      - The original UUID folder (so fingerprint, cookies, history, extensions all stay intact)
      - Referenced proxy/VPN configs (if bundled)

    By default, refuses to overwrite an existing UUID. Use -Overwrite to replace,
    or -NewUuid to generate a fresh UUID and rename the profile (useful when the
    same profile already exists on the target machine).

.PARAMETER ZipPath
    Path to the .zip produced by export-donut-profile.ps1.

.PARAMETER Overwrite
    Replace an existing profile with the same UUID. Existing data is moved to
    a .bak-<timestamp> folder before overwrite.

.PARAMETER NewUuid
    Assign a new UUID (and append " (imported)" to the display name) so it
    coexists with any existing profile.

.PARAMETER NewName
    Override the profile display name on import. Implies -NewUuid if the
    original UUID conflicts.

.EXAMPLE
    .\import-donut-profile.ps1 -ZipPath "D:\backups\work.zip"

.EXAMPLE
    .\import-donut-profile.ps1 -ZipPath ".\donut-profile-Work-20260428.zip" -NewUuid -NewName "Work (copy)"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ZipPath,

    [switch]$Overwrite,
    [switch]$NewUuid,
    [string]$NewName
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ZipPath)) {
    throw "Zip file not found: $ZipPath"
}

$dataDir = Join-Path $env:LOCALAPPDATA 'DonutBrowser'
if (-not (Test-Path $dataDir)) {
    Write-Host "[*] Donut data dir not found, creating: $dataDir" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
}

$profilesDir = Join-Path $dataDir 'profiles'
$proxiesDir  = Join-Path $dataDir 'proxies'
$vpnDir      = Join-Path $dataDir 'vpn'
foreach ($d in $profilesDir, $proxiesDir, $vpnDir) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# Refuse to run if Donut is open
$running = Get-Process -Name 'donutbrowser','wayfern','camoufox' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "[!] Close Donut Browser first:" -ForegroundColor Yellow
    $running | Format-Table Id, ProcessName -AutoSize
    throw 'Cannot import while Donut is running.'
}

# ---------------------------------------------------------------------------
# Extract zip into temp staging
# ---------------------------------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$staging = Join-Path $env:TEMP "donut-import-$stamp"
New-Item -ItemType Directory -Force -Path $staging | Out-Null

Write-Host "[*] Extracting $ZipPath ..." -ForegroundColor Cyan
Expand-Archive -LiteralPath $ZipPath -DestinationPath $staging -Force

$manifestPath = Join-Path $staging 'donut-export.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Invalid bundle: missing donut-export.json (was this zip created by export-donut-profile.ps1?)"
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schema -ne 'donut-profile-export/v1') {
    throw "Unsupported bundle schema: $($manifest.schema)"
}

$srcUuid    = $manifest.profile.uuid
$srcName    = $manifest.profile.name
$srcBrowser = $manifest.profile.browser

Write-Host "[*] Bundle:"
Write-Host "    UUID    : $srcUuid"
Write-Host "    Name    : $srcName"
Write-Host "    Browser : $srcBrowser"

$srcProfileDir = Join-Path (Join-Path $staging 'profiles') $srcUuid
if (-not (Test-Path -LiteralPath $srcProfileDir)) {
    throw "Bundle is missing profile folder: profiles/$srcUuid"
}

# ---------------------------------------------------------------------------
# Decide target UUID + name
# ---------------------------------------------------------------------------
$targetUuid = $srcUuid
$targetName = if ($NewName) { $NewName } else { $srcName }
$targetDir  = Join-Path $profilesDir $targetUuid

$conflictByUuid = Test-Path -LiteralPath $targetDir
if ($conflictByUuid -and -not $Overwrite -and -not $NewUuid) {
    throw "Profile UUID $srcUuid already exists at $targetDir. Use -Overwrite or -NewUuid."
}

if ($NewUuid -or ($conflictByUuid -and -not $Overwrite)) {
    $targetUuid = [guid]::NewGuid().ToString()
    $targetDir  = Join-Path $profilesDir $targetUuid
    if (-not $NewName) { $targetName = "$srcName (imported)" }
    Write-Host "[*] Assigning new UUID: $targetUuid" -ForegroundColor Cyan
}

# Conflict by display name?
$nameConflict = $false
Get-ChildItem -Path $profilesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.FullName -eq $targetDir) { return }
    $m = Join-Path $_.FullName 'metadata.json'
    if (Test-Path -LiteralPath $m) {
        try {
            $j = Get-Content -Raw -LiteralPath $m | ConvertFrom-Json
            if ($j.name -ieq $targetName) { $script:nameConflict = $true }
        } catch {}
    }
}
if ($nameConflict) {
    $oldName    = $targetName
    $targetName = "$targetName (imported $stamp)"
    Write-Host "[!] Name '$oldName' already used, renaming to '$targetName'" -ForegroundColor Yellow
}

# Backup existing dir if overwriting
if ((Test-Path -LiteralPath $targetDir) -and $Overwrite) {
    $bak = "$targetDir.bak-$stamp"
    Write-Host "[*] Backing up existing profile -> $bak" -ForegroundColor Yellow
    Move-Item -LiteralPath $targetDir -Destination $bak -Force
}

# ---------------------------------------------------------------------------
# Copy profile data into place
# ---------------------------------------------------------------------------
Write-Host "[*] Installing profile -> $targetDir" -ForegroundColor Cyan
$rcArgs = @($srcProfileDir, $targetDir, '/E', '/MT:8', '/R:1', '/W:1', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
$null = & robocopy @rcArgs
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

# Patch metadata.json: id + name (if changed)
$metaFile = Join-Path $targetDir 'metadata.json'
if (Test-Path -LiteralPath $metaFile) {
    $meta = Get-Content -Raw -LiteralPath $metaFile | ConvertFrom-Json
    $changed = $false
    if ($meta.id -ne $targetUuid)   { $meta.id = $targetUuid;     $changed = $true }
    if ($meta.name -ne $targetName) { $meta.name = $targetName;   $changed = $true }
    # Always clear stored process_id (process from old machine is meaningless here)
    if ($meta.PSObject.Properties.Match('process_id').Count -gt 0 -and $null -ne $meta.process_id) {
        $meta.process_id = $null
        $changed = $true
    }
    if ($changed) {
        ($meta | ConvertTo-Json -Depth 64) | Out-File -LiteralPath $metaFile -Encoding utf8
        Write-Host "    [+] metadata.json patched (id/name)" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Restore proxies/vpn (best-effort, never overwrite)
# ---------------------------------------------------------------------------
$srcProxiesDir = Join-Path $staging 'proxies'
if (Test-Path -LiteralPath $srcProxiesDir) {
    Write-Host "[*] Merging proxy configs..." -ForegroundColor Cyan
    Get-ChildItem -Path $srcProxiesDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($srcProxiesDir.Length).TrimStart('\','/')
        $dst = Join-Path $proxiesDir $rel
        if (Test-Path -LiteralPath $dst) {
            Write-Host "    [skip] $rel already exists on this machine" -ForegroundColor DarkGray
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
            Write-Host "    [+] $rel" -ForegroundColor Green
        }
    }
}

$srcVpnDir = Join-Path $staging 'vpn'
if (Test-Path -LiteralPath $srcVpnDir) {
    Write-Host "[*] Merging VPN configs..." -ForegroundColor Cyan
    Get-ChildItem -Path $srcVpnDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($srcVpnDir.Length).TrimStart('\','/')
        $dst = Join-Path $vpnDir $rel
        if (Test-Path -LiteralPath $dst) {
            Write-Host "    [skip] $rel already exists" -ForegroundColor DarkGray
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
            Write-Host "    [+] $rel" -ForegroundColor Green
        }
    }
}

Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[OK] Import complete." -ForegroundColor Green
Write-Host "     Profile  : $targetName"
Write-Host "     UUID     : $targetUuid"
Write-Host "     Browser  : $srcBrowser"
Write-Host ""
Write-Host "Launch Donut Browser - the profile should appear in your list." -ForegroundColor Cyan
Write-Host "If the proxy is missing, re-bind it via Profile Settings -> Proxy." -ForegroundColor DarkGray
