<#
  Projet 2 - Groupe B1-4 - FW01 : IDS Suricata configure par l'API d'OPNsense, depuis SRV-AD01
  Fait automatiquement (relancable sans risque) :
    1. Suricata active en mode IDS (alerte seulement) sur l'interface LAN, reseau protege 192.168.10.0/24
    2. Jeux de regles ET open : scan, attack_response, policy (telecharges puis charges)
    3. Verification : service Suricata en marche, nombre de regles chargees
  Prealable : une cle API root dans Telechargements (meme fichier que pour fw01.ps1, guide etape 5/11).
  A faire A LA MAIN avant (une fois) : Interfaces > Settings : cocher Hardware CRC, TSO et LRO
  (= desactives), VLAN Hardware Filtering = Disable, Save, puis redemarrer FW01.
  Commande, dans PowerShell sur SRV-AD01 :
    iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/fw01-ids.ps1 -UseBasicParsing | iex
  Le mode IPS (blocage) se regle ensuite a la main : guide, etape 14.5.
#>

$Fw      = "https://192.168.10.254"
$Jeux    = @("emerging-scan", "emerging-attack_response", "emerging-policy")

function Etape($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function OK($t)    { Write-Host "[OK] $t" -ForegroundColor Green }
function Info($t)  { Write-Host "[..] $t" -ForegroundColor Yellow }
function Alerte($t){ Write-Host "[!!] $t" -ForegroundColor Red }

Etape "0. Connexion a l'API d'OPNsense"
if (-not ("ToutAccepterG4I" -as [type])) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class ToutAccepterG4I : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; }
}
"@
}
[Net.ServicePointManager]::CertificatePolicy = New-Object ToutAccepterG4I
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
    # Pas de Content-Type JSON sur un GET : OPNsense repond alors 400
    $p = @{ Uri = "$Fw/api/$chemin"; Method = $methode; Headers = $H; UseBasicParsing = $true; TimeoutSec = 600 }
    if ($methode -eq "POST") {
        $p.ContentType = "application/json"
        $p.Body = if ($corps) { $corps | ConvertTo-Json -Depth 6 -Compress } else { "{}" }
    }
    Invoke-RestMethod @p
}

try { $avant = Api GET "ids/settings/get"; OK "API joignable, module IDS present" }
catch { Alerte "API ou module IDS inaccessible ($($_.Exception.Message))"; return }

# ---------------------------------------------------------------- 1. Reglages
Etape "1. Suricata en mode IDS sur le LAN"
$general = @{
    enabled    = "1"
    ips        = "0"                  # IDS : on alerte sans bloquer (le blocage IPS se regle a la main)
    promisc    = "1"
    interfaces = "lan"
    homenet    = "192.168.10.0/24"
}
$res = Api POST "ids/settings/set" @{ ids = @{ general = $general } }
if ($res.result -eq "saved") { OK "Suricata active sur LAN, reseau protege 192.168.10.0/24" }
else {
    Alerte "Reglages refuses : $($res | ConvertTo-Json -Depth 6 -Compress)"
    Info "Faites ces reglages a la main : Services > Intrusion Detection > Administration > Settings (guide 14.2)"
    return
}
# Hyperscan si possible (plus rapide), sinon on garde le choix par defaut
try {
    $r2 = Api POST "ids/settings/set" @{ ids = @{ general = @{ MPMAlgo = "hs" } } }
    if ($r2.result -eq "saved") { OK "Pattern matcher : Hyperscan" } else { Info "Hyperscan non retenu : pattern matcher par defaut" }
} catch { Info "Hyperscan non retenu : pattern matcher par defaut" }

# ---------------------------------------------------------------- 2. Regles
Etape "2. Jeux de regles ET open"
$liste = (Api GET "ids/settings/listRulesets").rows
foreach ($j in $Jeux) {
    $r = $liste | Where-Object { $_.filename -match "^$j\.rules" } | Select-Object -First 1
    if (-not $r) { Alerte "Jeu $j introuvable dans la liste (onglet Download)"; continue }
    if ("$($r.enabled)" -eq "1") { OK "$j deja active"; continue }
    $t = Api POST "ids/settings/toggleRuleset/$($r.filename)/1"
    OK "$j active ($($t.status))"
}
Info "Telechargement des regles et demarrage de Suricata (1 a 3 minutes)..."
try { Api POST "ids/service/reconfigure" | Out-Null } catch { Info "reconfigure : $($_.Exception.Message)" }
try { Api POST "ids/service/updateRules/wait" | Out-Null } catch { Api POST "ids/service/updateRules" | Out-Null; Start-Sleep -Seconds 90 }
Start-Sleep -Seconds 10

# ---------------------------------------------------------------- 3. Verification
Etape "3. Verification"
try { $etat = (Api GET "ids/service/status").status } catch { $etat = "inconnu" }
if ($etat -eq "running") { OK "Service Suricata : running" } else { Alerte "Service Suricata : $etat (voir Log File de l'IDS)" }
try {
    $n = (Api POST "ids/settings/searchInstalledRules" @{ current = 1; rowCount = 1 }).total
    OK "Regles installees : $n"
} catch { Info "Nombre de regles non lu" }

Write-Host "`nA faire ensuite :" -ForegroundColor Cyan
Write-Host " 1. Services > Wazuh Agent > Settings : 'Intrusion detection events' coche (alertes Suricata vers Wazuh)."
Write-Host " 2. SRV-WAZUH01 : relancer go.sh (regles 100210/100211 : scans en niveau 10)."
Write-Host " 3. SRV-PROXY01 : lancer scan-demo.sh (nmap) puis voir Alerts dans OPNsense et Threat Hunting dans Wazuh."
Write-Host " 4. Supprimer la cle API quand tout est fini."
