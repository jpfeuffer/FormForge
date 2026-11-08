#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Repository = 'jpfeuffer/FormForge',
    [string]$DesktopClientJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-ClientId([string]$Value, [string]$Name) {
    if ($Value -notmatch '^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$') {
        throw "$Name must be an OAuth client ID ending in .apps.googleusercontent.com."
    }
}

function Set-GitHubValue([string]$Kind, [string]$Name, [string]$Value) {
    $Value | & gh $Kind set $Name --repo $Repository
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload $Name. Earlier successful uploads remain; rerun to retry."
    }
    Write-Host "Uploaded $Name."
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI is missing. Install gh, then run gh auth login.'
}
& gh auth status
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub authentication failed. Run gh auth login, then retry.'
}

Write-Host "Configuring Google OAuth for $Repository."
Write-Host 'Existing values with these names will be replaced.'
Write-Host 'Use the Web client ID for Android; NEVER enter the Web client secret.'

$serverClientId = (Read-Host 'Web client ID (GOOGLE_SERVER_CLIENT_ID)').Trim()
Assert-ClientId $serverClientId 'Web client ID'

if ([string]::IsNullOrWhiteSpace($DesktopClientJson)) {
    $DesktopClientJson = Read-Host 'Desktop OAuth JSON path (leave empty to enter ID and secret manually)'
}

$desktopSecret = $null
$secureSecret = $null
$credentials = $null
$jsonText = $null
$pointer = [IntPtr]::Zero
try {
    if (-not [string]::IsNullOrWhiteSpace($DesktopClientJson)) {
        $DesktopClientJson = $DesktopClientJson.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $DesktopClientJson -PathType Leaf)) {
            throw 'Desktop OAuth JSON file does not exist.'
        }
        $jsonText = Get-Content -LiteralPath $DesktopClientJson -Raw
        try {
            $credentials = ConvertFrom-Json -InputObject $jsonText
        } catch {
            throw 'Desktop OAuth JSON is invalid. Download a Desktop app client JSON from Google.'
        }
        $installed = $credentials.PSObject.Properties['installed']
        if ($null -eq $installed) {
            throw 'Expected a Desktop app JSON with an installed section, not a Web client JSON.'
        }
        $idProperty = $installed.Value.PSObject.Properties['client_id']
        $secretProperty = $installed.Value.PSObject.Properties['client_secret']
        if ($null -eq $idProperty -or $null -eq $secretProperty) {
            throw 'Desktop OAuth JSON is missing its client ID or secret.'
        }
        $desktopClientId = [string]$idProperty.Value
        $desktopSecret = [string]$secretProperty.Value
    } else {
        $desktopClientId = (Read-Host 'Desktop client ID (GOOGLE_DESKTOP_CLIENT_ID)').Trim()
        $secureSecret = Read-Host 'Desktop client secret (GOOGLE_DESKTOP_CLIENT_SECRET; input hidden)' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
        $desktopSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }

    Assert-ClientId $desktopClientId 'Desktop client ID'
    if ([string]::IsNullOrWhiteSpace($desktopSecret) -or $desktopSecret -match '\s') {
        throw 'Desktop client secret is empty or contains whitespace. Copy the Desktop secret exactly.'
    }

    Set-GitHubValue 'variable' 'GOOGLE_SERVER_CLIENT_ID' $serverClientId
    Set-GitHubValue 'variable' 'GOOGLE_DESKTOP_CLIENT_ID' $desktopClientId
    Set-GitHubValue 'secret' 'GOOGLE_DESKTOP_CLIENT_SECRET' $desktopSecret
    Write-Host 'All three OAuth settings uploaded successfully. New builds will use them.'
} finally {
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    if ($null -ne $secureSecret) {
        $secureSecret.Dispose()
    }
    $desktopSecret = $null
    $credentials = $null
    $jsonText = $null
}
