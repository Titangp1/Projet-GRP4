<#
  Projet 2 - Groupe B1-4 - FW01 (OPNsense 25.7) configure par son API, depuis SRV-AD01
  Fait automatiquement, sans rien casser si on le relance :
    1. Agent Wazuh : installe le plugin os-wazuh-agent et le relie a SRV-WAZUH01 (192.168.10.30)
    2. Dnsmasq arrete (aucun DHCP : toutes les adresses sont fixes)
    3. Alias Postes_clients (192.168.10.100) et Ports_web (80, 443)
    4. Regle LAN : blocage du web direct de PC-CLT01 (proxy obligatoire), journalisee
  Prealable, une seule fois : creer une cle API pour root dans OPNsense. Le fichier ..._apikey.txt
  se telecharge dans Telechargements de SRV-AD01 : le script le lit tout seul (sinon il demande la cle).
  Ne publiez jamais ce fichier.
  Commande, dans PowerShell sur SRV-AD01 :
    iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/fw01.ps1 -UseBasicParsing | iex
  A lancer EN DERNIER : ensuite PC-CLT01 ne sort plus sur le web que par le proxy.
#>

$Fw      = "https://192.168.10.254"
$WazuhIP = "192.168.10.30"
$Desc    = "Web direct interdit, passer par le proxy"

function Etape($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function OK($t)    { Write-Host "[OK] $t" -ForegroundColor Green }
function Info($t)  { Write-Host "[..] $t" -ForegroundColor Yellow }
function Alerte($t){ Write-Host "[!!] $t" -ForegroundColor Red }

# ---------------------------------------------------------------- 0. Connexion
Etape "0. Connexion a l'API d'OPNsense"
# Certificat auto-signe d'OPNsense accepte pour cette session uniquement
if (-not ("ToutAccepterG4" -as [type])) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class ToutAccepterG4 : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; }
}
"@
}
[Net.ServicePointManager]::CertificatePolicy = New-Object ToutAccepterG4
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$fichier = Get-ChildItem "$env:USERPROFILE\Downloads" -Filter "*apikey*.txt" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($fichier) {
    $lignes = Get-Content $fichier.FullName
    $cle    = (($lignes | Where-Object { $_ -match '^key=' })    -replace '^key=', '').Trim()
    $secret = (($lignes | Where-Object { $_ -match '^secret=' }) -replace '^secret=', '').Trim()
    OK "Cle API lue dans $($fichier.Name)"
} else {
    Info "Aucun fichier *apikey*.txt dans Telechargements : saisie manuelle"
    $cle       = Read-Host "Cle API (key)"
    $secretSec = Read-Host -AsSecureString "Secret API (secret)"
    $secret    = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSec))
}
$H = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${cle}:${secret}")) }

function Api($methode, $chemin, $corps) {
    $p = @{ Uri = "$Fw/api/$chemin"; Method = $methode; Headers = $H; ContentType = "application/json"; UseBasicParsing = $true }
    if ($methode -eq "POST") { $p.Body = if ($corps) { $corps | ConvertTo-Json -Depth 6 -Compress } else { "{}" } }
    Invoke-RestMethod @p
}

try { Api GET "firewall/alias/searchItem" | Out-Null; OK "API joignable sur $Fw" }
catch { Alerte "API inaccessible : cle/secret faux ou OPNsense injoignable ($($_.Exception.Message))"; return }

# ---------------------------------------------------------------- 1. Agent Wazuh
Etape "1. Agent Wazuh (plugin os-wazuh-agent)"
$installe = $true
try { Api GET "wazuhagent/settings/get" | Out-Null } catch { $installe = $false }
if (-not $installe) {
    Write-Host "Installation du plugin (1 a 3 minutes)" -NoNewline
    Api POST "core/firmware/install/os-wazuh-agent" | Out-Null
    Start-Sleep -Seconds 8
    $limite = (Get-Date).AddMinutes(6)
    do {
        Start-Sleep -Seconds 5
        Write-Host "." -NoNewline
        try { $s = Api GET "core/firmware/upgradestatus" } catch { $s = @{ status = "running" } }
    } while ($s.status -eq "running" -and (Get-Date) -lt $limite)
    Write-Host ""
    try { Api GET "wazuhagent/settings/get" | Out-Null; OK "Plugin installe" }
    catch { Alerte "Plugin toujours absent : installez-le a la main (System > Firmware > Plugins > os-wazuh-agent) puis relancez"; return }
} else { OK "Plugin deja installe" }

$res = Api POST "wazuhagent/settings/set" @{ agent = @{ general = @{ enabled = "1"; server_address = $WazuhIP; agent_name = "FW01" } } }
if ($res.result -eq "saved") { OK "Agent relie a $WazuhIP sous le nom FW01" }
else { Alerte "Reglages de l'agent refuses : $($res | ConvertTo-Json -Depth 6 -Compress)" }

try {
    $res = Api POST "wazuhagent/settings/set" @{ agent = @{ logcollector = @{ syslog_programs = "filterlog" } } }
    if ($res.result -eq "saved") { OK "Journaux du pare-feu (filterlog) envoyes a Wazuh" }
    else { Info "filterlog non propose : dans Services > Wazuh Agent, cochez les journaux du pare-feu si la liste les contient" }
} catch { Info "filterlog non propose : a cocher a la main si la liste le contient" }

Api POST "wazuhagent/service/reconfigure" | Out-Null
Start-Sleep -Seconds 5
try { $etat = (Api GET "wazuhagent/service/status").status } catch { $etat = "inconnu" }
if ($etat -eq "running") { OK "Service Wazuh de FW01 : running" } else { Alerte "Service Wazuh de FW01 : $etat" }

# ---------------------------------------------------------------- 2. Dnsmasq
Etape "2. Dnsmasq (DHCP inutile : adresses fixes)"
try {
    $res = Api POST "dnsmasq/settings/set" @{ dnsmasq = @{ enable = "0" } }
    Api POST "dnsmasq/service/reconfigure" | Out-Null
    if ($res.result -eq "saved") { OK "Dnsmasq desactive" } else { Info "Dnsmasq : $($res | ConvertTo-Json -Compress)" }
} catch { Info "Dnsmasq non modifie : $($_.Exception.Message)" }

# ---------------------------------------------------------------- 3. Alias
Etape "3. Alias"
function Alias($nom, $type, $contenu, $descAlias) {
    $r = Api GET "firewall/alias/getAliasUUID/$nom"
    if ($r.uuid) { OK "Alias $nom deja present"; return }
    $res = Api POST "firewall/alias/addItem" @{ alias = @{ enabled = "1"; name = $nom; type = $type; content = $contenu; description = $descAlias } }
    if ($res.result -eq "saved") { OK "Alias $nom cree" } else { Alerte "Alias $nom refuse : $($res | ConvertTo-Json -Depth 6 -Compress)" }
}
Alias "Postes_clients" "host" "192.168.10.100" "Postes utilisateurs (PC-CLT01)"
Alias "Ports_web" "port" "80`n443" "HTTP et HTTPS"
Api POST "firewall/alias/reconfigure" | Out-Null

# ---------------------------------------------------------------- 4. Regle
Etape "4. Regle : web direct interdit pour PC-CLT01"
$regles = Api GET "firewall/filter/searchRule"
if (@($regles.rows | Where-Object { $_.description -eq $Desc }).Count -gt 0) {
    OK "Regle deja presente"
} else {
    $regle = @{ rule = @{
        enabled = "1"; sequence = "1"; action = "block"; quick = "1"; interface = "lan"; direction = "in"
        ipprotocol = "inet"; protocol = "TCP/UDP"
        source_net = "Postes_clients"; destination_net = "any"; destination_port = "Ports_web"
        log = "1"; description = $Desc } }
    $res = Api POST "firewall/filter/addRule" $regle
    if ($res.result -eq "saved") { OK "Regle creee" } else { Alerte "Regle refusee : $($res | ConvertTo-Json -Depth 6 -Compress)"; return }
}
$ap = Api POST "firewall/filter/apply"
OK "Regles appliquees ($($ap.status))"
Info "Les regles creees par l'API passent avant 'Default allow LAN to any rule'."

# ---------------------------------------------------------------- Bilan
Etape "Bilan"
(Api GET "firewall/filter/searchRule").rows | Select-Object enabled, action, source_net, destination_port, description | Format-Table -AutoSize
Write-Host "A faire ensuite :" -ForegroundColor Cyan
Write-Host " 1. PC-CLT01 : relancez go.ps1 ; la section 6 doit afficher 'Acces direct au web bloque'."
Write-Host " 2. OPNsense > Firewall > Log Files > Live View : blocages de 192.168.10.100 (capture C12)."
Write-Host " 3. Wazuh > Agents management : FW01 doit etre actif (1 a 2 minutes)."
Write-Host " 4. OPNsense > System > Settings > General : Hostname fw01, Domain groupe4.internal, Timezone Europe/Paris."
