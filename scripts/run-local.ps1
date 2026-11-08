#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Device = 'windows'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$local = Join-Path $root '.local'
$desktopPath = Join-Path $local 'google-desktop-client.json'
$serverPath = Join-Path $local 'google-server-client-id.txt'
$definesPath = Join-Path $local 'google-defines.json'

if (-not (Test-Path -LiteralPath $desktopPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
    throw 'Missing local Google credentials. See the local OAuth setup in README.md.'
}

try {
    $credentials = Get-Content -LiteralPath $desktopPath -Raw | ConvertFrom-Json
} catch {
    throw 'Cannot read the local Desktop OAuth JSON. Download a valid Desktop app client JSON.'
}
$installed = $credentials.PSObject.Properties['installed']
if ($null -eq $installed -or
    $null -eq $installed.Value.PSObject.Properties['client_id'] -or
    $null -eq $installed.Value.PSObject.Properties['client_secret']) {
    throw 'Expected a Desktop app JSON with client_id and client_secret, not a Web client JSON.'
}
$serverId = (Get-Content -LiteralPath $serverPath -Raw).Trim()
$desktopId = [string]$installed.Value.client_id
$desktopSecret = [string]$installed.Value.client_secret
foreach ($id in @($serverId, $desktopId)) {
    if ($id -notmatch '^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$') {
        throw 'Invalid local Google OAuth client ID.'
    }
}
if ([string]::IsNullOrWhiteSpace($desktopSecret)) {
    throw 'Missing local Desktop client secret.'
}

$defines = @{
    GOOGLE_SERVER_CLIENT_ID = $serverId
    GOOGLE_DESKTOP_CLIENT_ID = $desktopId
    GOOGLE_DESKTOP_CLIENT_SECRET = $desktopSecret
} | ConvertTo-Json
[System.IO.File]::WriteAllText(
    $definesPath,
    $defines,
    [System.Text.UTF8Encoding]::new($false)
)

Push-Location $root
try {
    & flutter run -d $Device "--dart-define-from-file=$definesPath"
    if ($LASTEXITCODE -ne 0) {
        throw 'Local Flutter run failed. See Flutter output above.'
    }
} finally {
    Pop-Location
}
