<#
.SYNOPSIS
    Exposes the local backend on the public internet over HTTPS.

.DESCRIPTION
    Starts a Cloudflare "quick tunnel", which needs no account and no router
    configuration, and prints the public address to hand to a tester.

    Use this when the other person is NOT on your network. On the same Wi-Fi,
    the plain LAN address from run-server.ps1 is simpler and stays private.

    Read this before running it:

    * The address is reachable by anyone who has it. Registration is open and
      the auth endpoints have no rate limiting, so treat the URL as a secret and
      stop the tunnel when you are done.
    * A quick tunnel gets a NEW random address every time it starts. Testers set
      it in the app's Server field rather than rebuilding the APK.
    * The tunnel only forwards. The backend must already be running.

.EXAMPLE
    .\run-tunnel.ps1
    .\run-tunnel.ps1 -Port 8001
#>
[CmdletBinding()]
param(
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'

$cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
if (-not $cloudflared) {
    $fallback = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
    if (Test-Path $fallback) {
        $cloudflared = $fallback
    } else {
        Write-Host ''
        Write-Host '  cloudflared is not installed.' -ForegroundColor Yellow
        Write-Host '  Install it with:'
        Write-Host '    winget install --id Cloudflare.cloudflared --exact'
        Write-Host ''
        exit 1
    }
}

# Forwarding to a port with nothing behind it produces a tunnel that returns
# 502 for everything, which is a confusing way to learn the server is down.
$listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if (-not $listening) {
    Write-Host ''
    Write-Host "  Nothing is listening on port $Port." -ForegroundColor Yellow
    Write-Host '  Start the backend first, in another window:'
    Write-Host '    .\run-server.ps1'
    Write-Host ''
    exit 1
}

Write-Host ''
Write-Host '  Opening a public HTTPS tunnel to this machine.' -ForegroundColor White
Write-Host '  Anyone with the address can reach your backend. Stop it when done.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  Give the tester the https://...trycloudflare.com address below,'
Write-Host '  and have them paste it into Server on the app sign-in screen.'
Write-Host ''
Write-Host '  Ctrl+C to close the tunnel.'
Write-Host ''

& $cloudflared tunnel --url "http://localhost:$Port" --no-autoupdate
