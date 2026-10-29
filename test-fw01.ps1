<#
  Projet 2 - Groupe B1-4 - TESTS de FW01 (OPNsense), depuis SRV-AD01 (lecture seule)
  Tests reseau toujours faits. Tests de configuration faits en plus si une cle API est presente
  dans Telechargements (*apikey*.txt) : ils n'utilisent que des lectures (GET), rien n'est modifie.
    powershell -ExecutionPolicy Bypass -File .\test-fw01.ps1
#>
$ErrorActionPreference = "Continue"
$script:ok = 0; $script:ko = 0
function Titre($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Test-Point([string]$nom, [scriptblock]$test, [string]$aide = "") {
    # Un -match sur une liste renvoie les lignes trouvees (pas $true) : liste non vide = reussi
    try { $r = & $test; if ($r -is [array]) { $r = $r.Count -gt 0 -and $r -notcontains $false } else { $r = [bool]$r } } catch { $r = $false }
    if ($r) { Write-Host "[OK]    $nom" -ForegroundColor Green; $script:ok++ }
    else { Write-Host "[ECHEC] $nom" -ForegroundColor Red; if ($aide) { Write-Host "        -> $aide" -ForegroundColor DarkYellow }; $script:ko++ }
}
function Info([string]$t) { Write-Host "[INFO]  $t" -ForegroundColor Yellow }
function Port([string]$h, [int]$p) {
    $c = New-Object Net.Sockets.TcpClient
    try { $a = $c.BeginConnect($h, $p, $null, $null); $r = $a.AsyncWaitHandle.WaitOne(2000) -and $c.Connected; $c.Close(); return $r } catch { return $false }
}

$Fw = "192.168.10.254"
$rapport = Join-Path ([Environment]::GetFolderPath("Desktop")) ("recette-FW01-{0:yyyyMMdd-HHmm}.txt" -f (Get-Date))
Start-Transcript -Path $rapport | Out-Null

Titre "1. Reseau"
Test-Point "FW01 repond au ping ($Fw)" { Test-Connection $Fw -Count 2 -Quiet }
Test-Point "Interface web d'OPNsense (TCP 443)" { Port $Fw 443 }
Test-Point "DNS Unbound de FW01 resout debian.org" { [bool](Resolve-DnsName debian.org -Server $Fw -DnsOnly -ErrorAction Stop) }
Test-Point "NAT : l'AD sort sur Internet (1.1.1.1:443)" { Port "1.1.1.1" 443 }
Test-Point "Nom fw01.groupe4.internal -> $Fw" { (Resolve-DnsName fw01.groupe4.internal -ErrorAction Stop).IPAddress -contains $Fw }

$fichier = Get-ChildItem "$env:USERPROFILE\Downloads" -Filter "*apikey*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $fichier) {
    Info "Pas de cle API dans Telechargements : tests de configuration de FW01 non faits."
    Info "Le blocage du web direct se verifie avec test-pc-clt01.ps1 sur PC-CLT01."
} else {
    Titre "2. Configuration (API d'OPNsense, lecture seule)"
    if (-not ("ToutAccepterG4T" -as [type])) {
        Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class ToutAccepterG4T : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; }
}
"@
    }
    [Net.ServicePointManager]::CertificatePolicy = New-Object ToutAccepterG4T
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $l = Get-Content $fichier.FullName
    $cle = (($l | Where-Object { $_ -match '^key=' }) -replace '^key=', '').Trim()
    $sec = (($l | Where-Object { $_ -match '^secret=' }) -replace '^secret=', '').Trim()
    $H = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${cle}:${sec}")) }
    # ConvertFrom-Json de PowerShell 5.1 refuse les reponses d'OPNsense qui contiennent des cles ne differant
    # que par la casse (listes d'options des pages de reglages) : on lit le JSON avec JavaScriptSerializer.
    Add-Type -AssemblyName System.Web.Extensions
    $js = New-Object Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue
    function Lire($chemin) {
        $brut = (Invoke-WebRequest -Uri "https://$Fw/api/$chemin" -Headers $H -Method Get -UseBasicParsing).Content
        $js.DeserializeObject($brut)
    }

    # Selon la version, searchRule pagine ou filtre par interface : on essaie plusieurs recherches
    $regle = $null
    foreach ($q in @("firewall/filter/searchRule?interface=lan&rowCount=-1&searchPhrase=Web%20direct",
                     "firewall/filter/searchRule?rowCount=-1&searchPhrase=Web%20direct",
                     "firewall/filter/searchRule?rowCount=-1",
                     "firewall/filter/searchRule")) {
        try { $regle = (Lire $q).rows | Where-Object { $_.description -eq "Web direct interdit, passer par le proxy" } | Select-Object -First 1 } catch { }
        if ($regle) { break }
    }
    Test-Point "Regle 'Web direct interdit' presente" { [bool]$regle } "Firewall > Rules : verifier la regle (le blocage reel se teste sur PC-CLT01)"
    if ($regle) {
        Test-Point "Regle active, action block, journalisee" { $regle.enabled -eq "1" -and $regle.action -match "block" -and $regle.log -eq "1" }
        Test-Point "Source Postes_clients, ports Ports_web" { $regle.source_net -match "Postes_clients" -and $regle.destination_port -match "Ports_web" }
    }
    Test-Point "Alias Postes_clients" { [bool](Lire "firewall/alias/getAliasUUID/Postes_clients").uuid }
    Test-Point "Alias Ports_web" { [bool](Lire "firewall/alias/getAliasUUID/Ports_web").uuid }
    Test-Point "Agent Wazuh de FW01 en marche" { (Lire "wazuhagent/service/status").status -eq "running" }
    Test-Point "Agent Wazuh relie a 192.168.10.30" { (Lire "wazuhagent/settings/get").agent.general.server_address -eq "192.168.10.30" }
    Test-Point "Dnsmasq desactive (adresses fixes)" { (Lire "dnsmasq/settings/get").dnsmasq.enable -eq "0" }
    Titre "3. IDS Suricata (API, lecture seule)"
    $g = $null; try { $g = (Lire "ids/settings/get").ids.general } catch { }
    Test-Point "Suricata active" { $g.enabled -eq "1" } "fw01-ids.ps1 ou guide etape 14"
    Test-Point "Suricata surveille l'interface LAN" { $g.interfaces.lan.selected -eq 1 }
    Test-Point "Service Suricata en marche" { (Lire "ids/service/status").status -eq "running" }
    $jeux = $null; try { $jeux = (Lire "ids/settings/listRulesets").rows } catch { }
    Test-Point "Jeu de regles ET open emerging-scan active" { [bool]($jeux | Where-Object { $_.filename -match "^emerging-scan" -and "$($_.enabled)" -eq "1" }) }
    if ($g) { Info ("Mode : {0}" -f $(if ($g.ips -eq "1") { "IPS (blocage)" } else { "IDS (alerte seulement)" })) }
    Info "Pensez a supprimer la cle API apres les tests (onglet ApiKeys)."
}

Titre "Bilan FW01"
$couleur = if ($script:ko -eq 0) { "Green" } else { "Red" }
Write-Host ("{0} tests reussis, {1} en echec" -f $script:ok, $script:ko) -ForegroundColor $couleur
Write-Host "Rapport : $rapport"
Stop-Transcript | Out-Null
