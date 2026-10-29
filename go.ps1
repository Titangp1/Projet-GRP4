# Projet 2 - Groupe B1-4 - lanceur Windows
# Reconnait la machine par son nom, telecharge son script depuis GitHub et l'execute.
# Commande unique, dans PowerShell (admin) :
#   iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.ps1 -UseBasicParsing | iex

$Depot = "https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "[!!] Ouvrez PowerShell en administrateur (clic droit sur Demarrer)" -ForegroundColor Red; return }

switch ($env:COMPUTERNAME) {
    "SRV-AD01" { $script = "srv-ad01.ps1" }
    "PC-CLT01" { $script = "pc-clt01.ps1" }
    default    { Write-Host "[!!] Machine $env:COMPUTERNAME inconnue (attendu SRV-AD01 ou PC-CLT01)" -ForegroundColor Red; return }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$local = Join-Path $env:TEMP $script
Write-Host "Telechargement de $script pour $env:COMPUTERNAME..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "$Depot/$script" -OutFile $local -UseBasicParsing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $local
