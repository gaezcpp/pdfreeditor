<#
.SYNOPSIS
    Runs the backend so other devices on the same network can reach it.

.DESCRIPTION
    Two things differ from the plain `uvicorn` command in the README:

    * it binds to 0.0.0.0, not just localhost, so a phone on the same Wi-Fi can
      connect (localhost on a phone means the phone itself);
    * it prints the LAN address to build the Android app against.

    Reload is off on purpose. The file watcher restarts the server mid-request,
    which looks like a random network failure from the device.

.EXAMPLE
    .\run-server.ps1
    .\run-server.ps1 -Port 9000
#>
[CmdletBinding()]
param(
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (-not (Test-Path $python)) {
    throw "No virtualenv at $python. See README.md for setup."
}

# Fail before printing anything encouraging. Uvicorn's own error for this
# arrives *after* "Application startup complete", which reads as though the
# server came up and then died for some unrelated reason.
$inUse = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($inUse) {
    $owner = Get-Process -Id $inUse.OwningProcess -ErrorAction SilentlyContinue
    $name = if ($owner) { "$($owner.ProcessName) (PID $($owner.Id))" } else { "PID $($inUse.OwningProcess)" }

    Write-Host ''
    Write-Host "  Port $Port is already taken by $name." -ForegroundColor Yellow
    Write-Host '  It may be a server you started earlier in another window.'
    Write-Host ''
    Write-Host '  Either stop it:' -ForegroundColor White
    Write-Host "    Stop-Process -Id $($inUse.OwningProcess)"
    Write-Host '  or use a different port:' -ForegroundColor White
    Write-Host '    .\run-server.ps1 -Port 8001'
    Write-Host ''
    exit 1
}

# The address of this machine on the local network. Wi-Fi and Ethernet can both
# have one; prefer whichever currently carries the default route.
$address = Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
    Select-Object -First 1 -ExpandProperty IPv4Address |
    Select-Object -First 1 -ExpandProperty IPAddress

if (-not $address) { $address = 'localhost' }

Write-Host ''
Write-Host '  PDFree backend' -ForegroundColor White
Write-Host "  this machine : http://$address`:$Port" -ForegroundColor Green
Write-Host "  emulator     : http://10.0.2.2:$Port"
Write-Host "  docs         : http://localhost:$Port/docs"
Write-Host ''
Write-Host '  Build the Android app against it with:' -ForegroundColor White
Write-Host "  flutter build apk --release --dart-define=API_BASE_URL=http://$address`:$Port"
Write-Host ''
Write-Host '  Ctrl+C to stop.'
Write-Host ''

& $python -m uvicorn app.main:app --host 0.0.0.0 --port $Port --log-level info
