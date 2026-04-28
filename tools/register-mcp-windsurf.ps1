<#
.SYNOPSIS
    Register Donut Browser's MCP server with Windsurf so Cascade can control the browser.

.DESCRIPTION
    Writes ~/.codeium/windsurf/mcp_config.json so Windsurf's Cascade agent can discover
    and call Donut's MCP tools (run_profile, navigate, click_element, screenshot,
    evaluate_javascript, etc.).

    Donut stores the MCP token Argon2-encrypted in settings\mcp_token.dat, so the
    plaintext URL must come from the running app. Two ways to provide it:
      1. -McpUrl <url>            : pass the URL on the command line.
      2. (default)                : pulls the URL from your clipboard.

    Get the URL from Donut: open the app, click the gear icon -> Integrations ->
    MCP Server section, then click the copy button next to the URL.

.PARAMETER McpUrl
    Full Donut MCP URL of the form http://127.0.0.1:<port>/mcp/<token>.
    If omitted, the script reads the URL from your clipboard.

.PARAMETER DonutExe
    Optional path to donutbrowser.exe used to bootstrap settings if Donut has never
    been launched. Auto-detected from ./src-tauri/target/.

.PARAMETER Force
    Overwrite existing donut-browser entry in mcp_config.json without prompting.

.EXAMPLE
    # Easiest flow: copy the URL from Donut UI, then run:
    .\register-mcp-windsurf.ps1

.EXAMPLE
    .\register-mcp-windsurf.ps1 -McpUrl "http://127.0.0.1:51080/mcp/abc...xyz" -Force
#>

[CmdletBinding()]
param(
    [string]$McpUrl,
    [string]$DonutExe,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Locate Donut settings (or boot Donut to create them)
# ---------------------------------------------------------------------------
$donutDataDir       = Join-Path $env:LOCALAPPDATA 'DonutBrowser'
$donutAppSettings   = Join-Path $donutDataDir 'settings\app_settings.json'
$donutMcpTokenFile  = Join-Path $donutDataDir 'settings\mcp_token.dat'

function Bootstrap-DonutIfMissing {
    if ((Test-Path -LiteralPath $donutAppSettings) -and (Test-Path -LiteralPath $donutMcpTokenFile)) { return }

    Write-Host "[!] Donut has not been launched yet on this machine." -ForegroundColor Yellow
    Write-Host "    settings dir: $(Split-Path -Parent $donutAppSettings)"

    if (-not $DonutExe) {
        $candidates = @(
            (Join-Path $PSScriptRoot '..\src-tauri\target\x86_64-pc-windows-msvc\release\donutbrowser.exe'),
            (Join-Path $PSScriptRoot '..\src-tauri\target\release\donutbrowser.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\DonutBrowser\donutbrowser.exe'),
            'C:\Program Files\DonutBrowser\donutbrowser.exe'
        )
        $script:DonutExe = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($script:DonutExe) { $script:DonutExe = (Resolve-Path -LiteralPath $script:DonutExe).Path }
    }
    if (-not $DonutExe -or -not (Test-Path -LiteralPath $DonutExe)) {
        Write-Host "Could not auto-locate donutbrowser.exe. Launch Donut manually, then re-run." -ForegroundColor Red
        exit 1
    }

    Write-Host "[*] Launching Donut so it can generate its MCP token..." -ForegroundColor Cyan
    Write-Host "    $DonutExe"
    $null = Start-Process -FilePath $DonutExe -PassThru

    Write-Host "[*] Waiting for token file to appear (max 90s)..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if ((Test-Path -LiteralPath $donutAppSettings) -and (Test-Path -LiteralPath $donutMcpTokenFile)) { return }
    }
    Write-Host "[!] Timed out waiting for Donut to write its settings." -ForegroundColor Yellow
    Write-Host "    Continue anyway - the URL still works as long as Donut is running."
}

Bootstrap-DonutIfMissing

# Read the port (port is plaintext in app_settings.json).
$donutPort = 51080
if (Test-Path -LiteralPath $donutAppSettings) {
    try {
        $appSettings = Get-Content -Raw -LiteralPath $donutAppSettings | ConvertFrom-Json
        if ($appSettings.mcp_port) { $donutPort = [int]$appSettings.mcp_port }
    } catch {}
}

# ---------------------------------------------------------------------------
# 2. Get the MCP URL (token is Argon2-encrypted, must come from the app)
# ---------------------------------------------------------------------------
function Try-ReadClipboardUrl {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $txt = [System.Windows.Forms.Clipboard]::GetText()
        if ($txt) { return $txt.Trim() }
    } catch {}
    try {
        $txt = Get-Clipboard -Raw -ErrorAction Stop
        if ($txt) { return $txt.Trim() }
    } catch {}
    return ''
}

if (-not $McpUrl) {
    Write-Host ""
    Write-Host "Need Donut's MCP URL to register it with Windsurf." -ForegroundColor Cyan
    Write-Host "How to get it:" -ForegroundColor Cyan
    Write-Host "  1. Open Donut Browser."
    Write-Host "  2. Click the gear icon (Settings) -> Integrations."
    Write-Host "  3. Make sure 'Enable MCP Server' is ON."
    Write-Host "  4. Click the copy button next to the MCP URL."
    Write-Host ""

    $clip = Try-ReadClipboardUrl
    if ($clip -match '^https?://127\.0\.0\.1:\d+/mcp/.+') {
        Write-Host "[*] Detected an MCP URL on your clipboard:" -ForegroundColor Green
        Write-Host "    $clip"
        $a = Read-Host "    Use this URL? (Y/n)"
        if ($a -notmatch '^[nN]') { $McpUrl = $clip }
    }
}

while (-not $McpUrl -or ($McpUrl -notmatch '^https?://127\.0\.0\.1:\d+/mcp/.+')) {
    $McpUrl = (Read-Host "Paste the MCP URL").Trim()
    if ($McpUrl -notmatch '^https?://127\.0\.0\.1:\d+/mcp/.+') {
        Write-Host "    Invalid format. Expected: http://127.0.0.1:<port>/mcp/<token>" -ForegroundColor Yellow
        $McpUrl = ''
    }
}

if ($McpUrl -match '^https?://127\.0\.0\.1:(\d+)/') {
    $urlPort = [int]$matches[1]
    if ($urlPort -ne $donutPort) {
        Write-Host "[!] URL port ($urlPort) does not match app_settings.json mcp_port ($donutPort). Using URL value." -ForegroundColor Yellow
    }
    $donutPort = $urlPort
}

# ---------------------------------------------------------------------------
# 3. Sanity check: is the MCP server actually listening?
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[*] Donut MCP details:" -ForegroundColor Green
Write-Host "    Port : $donutPort"
Write-Host "    URL  : $McpUrl"

$listening = $false
try {
    $listening = (Test-NetConnection -ComputerName '127.0.0.1' -Port $donutPort -WarningAction SilentlyContinue -InformationLevel Quiet)
} catch {}
if ($listening) {
    Write-Host "    Port $donutPort is currently LISTENING." -ForegroundColor Green
} else {
    Write-Host "[!] Port $donutPort is not currently listening." -ForegroundColor Yellow
    Write-Host "    The config will still be written; just make sure Donut is running before Cascade calls a tool."
}

# Use $McpUrl going forward (rest of the script expects this variable name)
$mcpUrl = $McpUrl

# ---------------------------------------------------------------------------
# 3. Write Windsurf MCP config (~/.codeium/windsurf/mcp_config.json)
# ---------------------------------------------------------------------------
$windsurfDir    = Join-Path $env:USERPROFILE '.codeium\windsurf'
$mcpConfigPath  = Join-Path $windsurfDir 'mcp_config.json'

if (-not (Test-Path -LiteralPath $windsurfDir)) {
    New-Item -ItemType Directory -Force -Path $windsurfDir | Out-Null
}

# Load existing config if present, otherwise start fresh
$config = $null
if (Test-Path -LiteralPath $mcpConfigPath) {
    try {
        $config = Get-Content -Raw -LiteralPath $mcpConfigPath | ConvertFrom-Json
    } catch {
        Write-Host "[!] Existing mcp_config.json is invalid JSON, backing up and recreating." -ForegroundColor Yellow
        $bak = "$mcpConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $mcpConfigPath -Destination $bak -Force
        $config = $null
    }
}

if (-not $config) {
    $config = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
}
if (-not $config.PSObject.Properties['mcpServers']) {
    $config | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value ([pscustomobject]@{}) -Force
}

$existing = $config.mcpServers.PSObject.Properties['donut-browser']
if ($existing -and -not $Force) {
    Write-Host "[?] mcp_config.json already has a 'donut-browser' entry." -ForegroundColor Yellow
    $answer = Read-Host "    Overwrite it? (y/N)"
    if ($answer -notmatch '^[yY]') {
        Write-Host "    Aborted. Re-run with -Force to skip the prompt." -ForegroundColor DarkGray
        exit 0
    }
}

# Windsurf uses Claude-Desktop-compatible "mcpServers" format.
# For HTTP transport (which Donut exposes), the schema is:
#   { "serverUrl": "http://127.0.0.1:<port>/mcp/<token>" }
# Some Windsurf builds also accept the explicit "type" + "url" pair, so we
# emit both keys for maximum compatibility.
$entry = [ordered]@{
    serverUrl = $mcpUrl
    type      = 'http'
    url       = $mcpUrl
}

# Replace or add the donut-browser entry, preserving any other servers
$serversObj = [ordered]@{}
foreach ($p in $config.mcpServers.PSObject.Properties) {
    if ($p.Name -ne 'donut-browser') { $serversObj[$p.Name] = $p.Value }
}
$serversObj['donut-browser'] = $entry

$final = [ordered]@{ mcpServers = $serversObj }
$json  = $final | ConvertTo-Json -Depth 10

# Backup original then write
if (Test-Path -LiteralPath $mcpConfigPath) {
    $bak = "$mcpConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $mcpConfigPath -Destination $bak -Force
    Write-Host "[*] Backed up existing config -> $bak" -ForegroundColor DarkGray
}
$json | Out-File -LiteralPath $mcpConfigPath -Encoding utf8

Write-Host ""
Write-Host "[OK] Windsurf MCP config updated:" -ForegroundColor Green
Write-Host "     $mcpConfigPath"
Write-Host ""
Write-Host "Final config:" -ForegroundColor Cyan
Get-Content -Raw -LiteralPath $mcpConfigPath
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. In Windsurf, open Cascade settings panel."
Write-Host "  2. Click 'Refresh' on the MCP servers list (or restart Windsurf)."
Write-Host "  3. You should see 'donut-browser' with a green status."
Write-Host "  4. Try asking Cascade:"
Write-Host "       'List my Donut Browser profiles'"
Write-Host "       'Open profile X, navigate to https://example.com, take a screenshot'"
