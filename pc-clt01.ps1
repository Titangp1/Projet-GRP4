#Requires -RunAsAdministrator
<#
  Projet 2 - Groupe B1-4 - PC-CLT01 (192.168.10.100)
  A lancer en session GROUPE4\Administrateur, PowerShell (admin), APRES srv-ad01.ps1 :
    powershell -ExecutionPolicy Bypass -File .\pc-clt01.ps1
  Fait : agent Wazuh, application des GPO, verifications (certificat, proxy, Kerberos).
  A faire AVANT l'etape 12 (blocage du web direct), sinon l'agent ne se telecharge plus.
#>

$ErrorActionPreference = "Stop"
$WazuhIP   = "192.168.10.30"
$WazuhVer  = "4.14.9-1"
$ProxyFQDN = "srv-proxy01.groupe4.internal"

function Etape($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function OK($t)    { Write-Host "[OK] $t" -ForegroundColor Green }
function Alerte($t){ Write-Host "[!!] $t" -ForegroundColor Red }

Etape "1. Domaine et DNS"
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -eq "groupe4.internal") { OK "PC-CLT01 est dans groupe4.internal" }
else { Alerte "Pas dans le domaine : faites l'etape 5 du guide (Add-Computer) puis relancez"; exit 1 }
Resolve-DnsName $ProxyFQDN | Select-Object Name, IPAddress | Format-Table -AutoSize

Etape "2. Agent Wazuh"
if (-not (Get-Service WazuhSvc -ErrorAction SilentlyContinue)) {
    $msi = "$env:TEMP\wazuh-agent.msi"
    Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-$WazuhVer.msi" -OutFile $msi -UseBasicParsing
    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$msi`" /q WAZUH_MANAGER=$WazuhIP WAZUH_AGENT_GROUP=default WAZUH_AGENT_NAME=PC-CLT01"
}
Start-Service WazuhSvc -ErrorAction SilentlyContinue
OK "Service Wazuh : $((Get-Service WazuhSvc).Status)"

Etape "3. GPO"
gpupdate /force | Out-Null
$gpo = gpresult /r /scope computer | Select-String "GPO-C-"
if ($gpo) { $gpo | ForEach-Object { OK $_.Line.Trim() } } else { Alerte "Aucune GPO-C-* appliquee : PC-CLT01 est-il dans OU=Postes-G4 ?" }

Etape "4. Certificat de la CA du proxy"
$ca = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*Groupe4 Proxy CA*"
if ($ca) { OK "Approuve : $($ca.Subject)" } else { Alerte "CA absente : relancez srv-ad01.ps1 apres srv-proxy01.sh, puis ce script" }

Etape "5. Proxy et authentification"
try {
    $r = Invoke-WebRequest -Uri "http://neverssl.com" -Proxy "http://$ProxyFQDN`:3128" -ProxyUseDefaultCredentials -UseBasicParsing
    OK "Acces web via le proxy pour $env:USERNAME : HTTP $($r.StatusCode)"
} catch {
    Alerte "Refus du proxy pour $env:USERNAME : $($_.Exception.Message) (normal si ce compte n'est pas dans GG-Internet)"
}
klist | Select-String "HTTP/"

Etape "6. Proxy obligatoire (regle de FW01)"
$direct = Test-NetConnection www.debian.org -Port 443 -WarningAction SilentlyContinue
if (-not $direct.RemoteAddress) { Alerte "www.debian.org introuvable dans le DNS : test impossible" }
elseif ($direct.TcpTestSucceeded) { Alerte "Acces direct au web encore possible : la regle de FW01 n'est pas en place (fw01.ps1)" }
else { OK "Acces direct au web bloque : tout passe par le proxy" }
$proxy = Test-NetConnection $ProxyFQDN -Port 3128 -WarningAction SilentlyContinue
if ($proxy.TcpTestSucceeded) { OK "Proxy joignable sur le port 3128" } else { Alerte "Proxy injoignable sur le port 3128" }

Write-Host "`nTermine. Redemarrez PC-CLT01, ouvrez une session GROUPE4\j.martin et testez Edge (edge://policy, https://www.debian.org)." -ForegroundColor Cyan
