<#
  Projet 2 - Groupe B1-4 - SCRIPT WINDOWS UNIQUE (SRV-AD01 et PC-CLT01)
  Un menu propose la configuration et la recette (tests en lecture seule) de chaque partie du projet.
  Aucun mot de passe n'est ecrit ici : ils sont demandes a l'execution.

  SRV-AD01 et PC-CLT01 (configuration), PowerShell en administrateur :
    md C:\Users\Public\g4 -Force | Out-Null; iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/projet.ps1 -UseBasicParsing -OutFile C:\Users\Public\g4\projet.ps1; powershell -ExecutionPolicy Bypass -File C:\Users\Public\g4\projet.ps1

  PC-CLT01, recette en session j.martin (le web direct est bloque : telechargement par le proxy) :
    voir README ; puis en session p.durand : powershell -ExecutionPolicy Bypass -File C:\Users\Public\g4\projet.ps1
#>
$Depot = "https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ======================================================================== CONFIGURATION
function Config-AD {
$ErrorActionPreference = "Stop"
$Domaine   = "groupe4.internal"
$DN        = "DC=groupe4,DC=internal"
$OUUsers   = "OU=Utilisateurs-G4,$DN"
$OUPostes  = "OU=Postes-G4,$DN"
$ProxyFQDN = "srv-proxy01.groupe4.internal"
$ProxyIP   = "192.168.10.20"
$WazuhIP   = "192.168.10.30"
$WazuhVer  = "4.14.9-1"
$CertPath  = "C:\Users\Administrateur\Desktop\squid-ca.crt"

function Etape($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function OK($t)    { Write-Host "[OK] $t" -ForegroundColor Green }
function Info($t)  { Write-Host "[..] $t" -ForegroundColor Yellow }
function Alerte($t){ Write-Host "[!!] $t" -ForegroundColor Red }

Import-Module ActiveDirectory, GroupPolicy, DnsServer

# ---------------------------------------------------------------- 1. Heure
Etape "1. Heure (NTP)"
w32tm /config /manualpeerlist:"0.fr.pool.ntp.org 1.fr.pool.ntp.org" /syncfromflags:manual /reliable:yes /update | Out-Null
Restart-Service w32time
Start-Sleep -Seconds 3
w32tm /resync | Out-Null
if (-not (Get-NetFirewallRule -DisplayName "NTP serveur (UDP 123)" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "NTP serveur (UDP 123)" -Direction Inbound -Protocol UDP -LocalPort 123 -Action Allow | Out-Null
}
OK "AD synchronise sur pool.ntp.org, port UDP 123 ouvert"

# ---------------------------------------------------------------- 2. DNS
Etape "2. DNS"
Set-DnsServerForwarder -IPAddress 192.168.10.254
if (-not (Get-DnsServerZone -Name "10.168.192.in-addr.arpa" -ErrorAction SilentlyContinue)) {
    Add-DnsServerPrimaryZone -NetworkId "192.168.10.0/24" -ReplicationScope "Forest"
}
$enregistrements = @{ "fw01" = "192.168.10.254"; "srv-proxy01" = $ProxyIP; "srv-wazuh01" = $WazuhIP }
foreach ($nom in $enregistrements.Keys) {
    if (-not (Get-DnsServerResourceRecord -ZoneName $Domaine -Name $nom -RRType A -ErrorAction SilentlyContinue)) {
        Add-DnsServerResourceRecordA -ZoneName $Domaine -Name $nom -IPv4Address $enregistrements[$nom] -CreatePtr
        OK "Enregistrement $nom -> $($enregistrements[$nom]) cree"
    } else { OK "Enregistrement $nom deja present" }
}
ipconfig /registerdns | Out-Null
OK "Redirecteur vers OPNsense, zone inverse et PTR de l'AD en place"

# ---------------------------------------------------------------- 3. Annuaire
Etape "3. Annuaire"
if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Utilisateurs-G4'")) {
    New-ADOrganizationalUnit -Name "Utilisateurs-G4" -Path $DN
}
if (-not (Get-ADGroup -Filter "Name -eq 'GG-Internet'")) {
    New-ADGroup -Name "GG-Internet" -GroupScope Global -GroupCategory Security -Path $OUUsers
}
$comptes = @(
    @{ Sam = "j.martin";  Nom = "Jeanne Martin"; Path = $OUUsers },
    @{ Sam = "p.durand";  Nom = "Paul Durand";   Path = $OUUsers },
    @{ Sam = "svc-squid"; Nom = "svc-squid";     Path = "CN=Users,$DN" }
)
foreach ($c in $comptes) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($c.Sam)'")) {
        $mdp = Read-Host -AsSecureString "Mot de passe pour $($c.Sam)"
        New-ADUser -Name $c.Nom -SamAccountName $c.Sam -UserPrincipalName "$($c.Sam)@$Domaine" -Path $c.Path -AccountPassword $mdp -Enabled $true
        OK "Compte $($c.Sam) cree"
    } else { OK "Compte $($c.Sam) deja present" }
}
Set-ADUser svc-squid -PasswordNeverExpires $true -CannotChangePassword $true
if (-not (Get-ADGroupMember GG-Internet | Where-Object SamAccountName -eq "j.martin")) {
    Add-ADGroupMember -Identity "GG-Internet" -Members "j.martin"
}
OK "Membres de GG-Internet : $((Get-ADGroupMember GG-Internet).SamAccountName -join ', ')"

# ---------------------------------------------------------------- 4. OU Postes-G4
Etape "4. OU Postes-G4"
if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Postes-G4'")) {
    New-ADOrganizationalUnit -Name "Postes-G4" -Path $DN
}
$pc = Get-ADComputer -Filter "Name -eq 'PC-CLT01'"
if ($pc) {
    if ($pc.DistinguishedName -notlike "*OU=Postes-G4*") { $pc | Move-ADObject -TargetPath $OUPostes }
    OK "PC-CLT01 est dans OU=Postes-G4"
} else { Alerte "PC-CLT01 n'est pas encore dans le domaine (etape 5 du guide), relancez ce script apres" }

function GPO-Lier($nom) {
    $g = Get-GPO -Name $nom -ErrorAction SilentlyContinue
    if (-not $g) { $g = New-GPO -Name $nom }
    $liens = (Get-GPInheritance -Target $OUPostes).GpoLinks.DisplayName
    if ($liens -notcontains $nom) { New-GPLink -Name $nom -Target $OUPostes | Out-Null }
    return $g
}

# ---------------------------------------------------------------- 5. GPO proxy Edge
Etape "5. GPO-C-ProxyEdge"
GPO-Lier "GPO-C-ProxyEdge" | Out-Null
$json = '{"ProxyMode":"fixed_servers","ProxyServer":"' + $ProxyFQDN + ':3128","ProxyBypassList":"<local>,*.groupe4.internal,192.168.10.0/24"}'
Set-GPRegistryValue -Name "GPO-C-ProxyEdge" -Key "HKLM\Software\Policies\Microsoft\Edge" -ValueName "ProxySettings" -Type String -Value $json | Out-Null
OK "Edge utilisera $ProxyFQDN`:3128"

# ---------------------------------------------------------------- 6. GPO certificat
Etape "6. GPO-C-CertificatProxy"
if (-not (Test-Path $CertPath)) {
    Info "Recuperation du certificat de la CA sur le proxy (mot de passe d'adminproxy)"
    try { scp "adminproxy@${ProxyIP}:/etc/squid/ssl/squid-ca.crt" $CertPath } catch { }
}
if (Test-Path $CertPath) {
    GPO-Lier "GPO-C-CertificatProxy" | Out-Null
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
    $empreinte = $cert.Thumbprint
    certutil -f -addstore Root $CertPath | Out-Null
    $blob = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\$empreinte").Blob
    $cle = "HKLM\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\Certificates\$empreinte"
    Set-GPRegistryValue -Name "GPO-C-CertificatProxy" -Key $cle -ValueName "Blob" -Type Binary -Value $blob | Out-Null
    OK "Certificat '$($cert.Subject)' ($empreinte) publie par GPO"
} else {
    Alerte "Certificat absent : lancez d'abord l'option 2 (proxy), puis relancez l'option 1"
}

# ---------------------------------------------------------------- 7. Agent Wazuh
Etape "7. Agent Wazuh"
if (-not (Get-Service WazuhSvc -ErrorAction SilentlyContinue)) {
    $msi = "$env:TEMP\wazuh-agent.msi"
    Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-$WazuhVer.msi" -OutFile $msi -UseBasicParsing
    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$msi`" /q WAZUH_MANAGER=$WazuhIP WAZUH_AGENT_GROUP=default WAZUH_AGENT_NAME=SRV-AD01"
}
Start-Service WazuhSvc -ErrorAction SilentlyContinue
OK "Service Wazuh : $((Get-Service WazuhSvc).Status)"

# ---------------------------------------------------------------- Bilan
Etape "Bilan"
w32tm /query /status | Select-String "Source|Couche"
Resolve-DnsName $ProxyFQDN | Select-Object Name, IPAddress | Format-Table -AutoSize
Get-GPInheritance -Target $OUPostes | Select-Object -ExpandProperty GpoLinks | Select-Object DisplayName, Enabled | Format-Table -AutoSize
Write-Host "Termine. Suite : option 2 (serveurs Linux) si pas encore faite, sinon projet.ps1 option 1 sur PC-CLT01." -ForegroundColor Cyan
}

function Config-PC {
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
else { Alerte "Pas dans le domaine : faites l'etape 5 du guide (Add-Computer) puis relancez"; return }
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
if ($ca) { OK "Approuve : $($ca.Subject)" } else { Alerte "CA absente : relancez l'option 1 sur SRV-AD01 apres l'option 2, puis ce script" }

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
elseif ($direct.TcpTestSucceeded) { Alerte "Acces direct au web encore possible : la regle de FW01 n'est pas en place (option 3 sur SRV-AD01)" }
else { OK "Acces direct au web bloque : tout passe par le proxy" }
$proxy = Test-NetConnection $ProxyFQDN -Port 3128 -WarningAction SilentlyContinue
if ($proxy.TcpTestSucceeded) { OK "Proxy joignable sur le port 3128" } else { Alerte "Proxy injoignable sur le port 3128" }

Write-Host "`nTermine. Redemarrez PC-CLT01, ouvrez une session GROUPE4\j.martin et testez Edge (edge://policy, https://www.debian.org)." -ForegroundColor Cyan
}

function Config-Linux {
    # SRV-WAZUH01 puis SRV-PROXY01 : chaque serveur telecharge et lance projet.sh (sans guillemets : PowerShell 5.1 les transmet mal a ssh)
    $cmd = 'curl -fsSL https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/projet.sh -o /tmp/projet.sh && sudo bash /tmp/projet.sh'
    foreach ($m in @(@{ Nom = "SRV-WAZUH01"; Cible = "adminwazuh@192.168.10.30" }, @{ Nom = "SRV-PROXY01"; Cible = "adminproxy@192.168.10.20" })) {
        Write-Host "`n##### $($m.Nom) ($($m.Cible)) - mots de passe : SSH puis sudo #####" -ForegroundColor Cyan
        ssh -t -o StrictHostKeyChecking=accept-new $m.Cible $cmd
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[!!] $($m.Nom) termine avec une erreur (code $LASTEXITCODE)." -ForegroundColor Red
            if ((Read-Host "Continuer avec la machine suivante ? (o/n)") -ne "o") { return }
        } else { Write-Host "[OK] $($m.Nom) termine" -ForegroundColor Green }
    }
    Write-Host "`nEnsuite : option 1 une seconde fois (publication du certificat du proxy par GPO)." -ForegroundColor Cyan
}

function Config-FW01-Base {
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
    # Pas de Content-Type JSON sur un GET : OPNsense repond alors 400 (corps JSON vide).
    $p = @{ Uri = "$Fw/api/$chemin"; Method = $methode; Headers = $H; UseBasicParsing = $true }
    if ($methode -eq "POST") {
        $p.ContentType = "application/json"
        $p.Body = if ($corps) { $corps | ConvertTo-Json -Depth 6 -Compress } else { "{}" }
    }
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

# syslog_programs vide dans le meme envoi : juste apres l'installation, sa valeur par defaut est refusee
$res = Api POST "wazuhagent/settings/set" @{ agent = @{ general = @{ enabled = "1"; server_address = $WazuhIP; agent_name = "FW01" }; logcollector = @{ syslog_programs = "" } } }
if ($res.result -eq "saved") { OK "Agent relie a $WazuhIP sous le nom FW01" }
else { Alerte "Reglages de l'agent refuses : $($res | ConvertTo-Json -Depth 6 -Compress)" }

try {
    $res = Api POST "wazuhagent/settings/set" @{ agent = @{ logcollector = @{ syslog_programs = "filterlog" } } }
    if ($res.result -eq "saved") { OK "Journaux du pare-feu (filterlog) envoyes a Wazuh" }
    else { Info "filterlog non propose : dans Services > Wazuh Agent, cochez les journaux du pare-feu si la liste les contient" }
} catch { Info "filterlog non propose : a cocher a la main si la liste le contient" }

try { Api POST "wazuhagent/service/reconfigure" | Out-Null } catch { Alerte "Demarrage de l'agent refuse : reglez-le dans Services > Wazuh Agent > Settings" }
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
Write-Host " 1. PC-CLT01 : projet.ps1 option 1 ; la section 6 doit afficher 'Acces direct au web bloque'."
Write-Host " 2. OPNsense > Firewall > Log Files > Live View : blocages de 192.168.10.100 (capture C12)."
Write-Host " 3. Wazuh > Agents management : FW01 doit etre actif (1 a 2 minutes)."
Write-Host " 4. OPNsense > System > Settings > General : Hostname fw01, Domain groupe4.internal, Timezone Europe/Paris."
}

function Config-FW01-IDS {
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
Write-Host " 2. Regles Wazuh 100210/100211 : deja ajoutees par l'option 2 (sinon relancez-la)."
Write-Host " 3. Option 4 (scans nmap), puis Alerts dans OPNsense et Threat Hunting dans Wazuh."
Write-Host " 4. Supprimer la cle API quand tout est fini."
}

function Config-FW01 {
    Config-FW01-Base
    Write-Host "`n--- IDS Suricata ---" -ForegroundColor Magenta
    Write-Host "Prealable : Interfaces > Settings : Hardware CRC, TSO et LRO coches (desactives), VLAN Hardware Filtering = Disable, puis redemarrage de FW01."
    if ((Read-Host "Est-ce fait ? (o = activer Suricata maintenant / n = plus tard)") -eq "o") { Config-FW01-IDS }
    else { Write-Host "[..] Suricata non active : relancez l'option 3 une fois ce reglage fait." -ForegroundColor Yellow }
}

function Demo-Scan {
    Write-Host "Scans nmap depuis SRV-PROXY01 (mots de passe : SSH puis sudo d'adminproxy)" -ForegroundColor Cyan
    ssh -t -o StrictHostKeyChecking=accept-new adminproxy@192.168.10.20 'curl -fsSL https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/projet.sh -o /tmp/projet.sh && sudo bash /tmp/projet.sh scan'
}

# ======================================================================== RECETTE (lecture seule)
function Recette-AD {
$ErrorActionPreference = "Continue"
$script:ok = 0; $script:ko = 0; $script:av = 0
function Titre($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Test-Point([string]$nom, [scriptblock]$test, [string]$aide = "") {
    # Un -match sur une liste renvoie les lignes trouvees (pas $true) : liste non vide = reussi
    try { $r = & $test; if ($r -is [array]) { $r = $r.Count -gt 0 -and $r -notcontains $false } else { $r = [bool]$r } } catch { $r = $false }
    if ($r) { Write-Host "[OK]    $nom" -ForegroundColor Green; $script:ok++ }
    else { Write-Host "[ECHEC] $nom" -ForegroundColor Red; if ($aide) { Write-Host "        -> $aide" -ForegroundColor DarkYellow }; $script:ko++ }
}
function Avert([string]$t) { Write-Host "[INFO]  $t" -ForegroundColor Yellow; $script:av++ }
function Port([string]$h, [int]$p) {
    $c = New-Object Net.Sockets.TcpClient
    try { $a = $c.BeginConnect($h, $p, $null, $null); $r = $a.AsyncWaitHandle.WaitOne(2000) -and $c.Connected; $c.Close(); return $r } catch { return $false }
}

$rapport = Join-Path ([Environment]::GetFolderPath("Desktop")) ("recette-SRV-AD01-{0:yyyyMMdd-HHmm}.txt" -f (Get-Date))
Start-Transcript -Path $rapport | Out-Null
Import-Module ActiveDirectory, GroupPolicy, DnsServer -ErrorAction SilentlyContinue
$D = "groupe4.internal"; $DN = "DC=groupe4,DC=internal"

Titre "1. Machine et reseau"
Test-Point "Nom de la machine = SRV-AD01" { $env:COMPUTERNAME -eq "SRV-AD01" }
Test-Point "Adresse 192.168.10.10/24" { [bool](Get-NetIPAddress -IPAddress 192.168.10.10 -PrefixLength 24 -ErrorAction Stop) }
Test-Point "Passerelle 192.168.10.254" { (Get-NetRoute -DestinationPrefix 0.0.0.0/0).NextHop -contains "192.168.10.254" }
Test-Point "Pare-feu FW01 joignable (ping)" { Test-Connection 192.168.10.254 -Count 2 -Quiet }
Test-Point "Sortie Internet (TCP 443 vers 1.1.1.1)" { Port "1.1.1.1" 443 } "Verifier le WAN de FW01"

Titre "2. Active Directory"
# Attention : $d et $D sont la meme variable pour PowerShell (insensible a la casse) : on utilise $dom
$dom = Get-ADDomain -ErrorAction SilentlyContinue
Test-Point ("Domaine groupe4.internal (NetBIOS GROUPE4) - lu : {0} / {1}" -f $dom.DNSRoot, $dom.NetBIOSName) { $dom.DNSRoot -eq $D -and $dom.NetBIOSName -eq "GROUPE4" }
Test-Point "Services NTDS, DNS, KDC et Netlogon demarres" { @("NTDS","DNS","Kdc","Netlogon" | ForEach-Object { (Get-Service $_).Status -eq "Running" }) -notcontains $false }
Test-Point "OU Utilisateurs-G4" { [bool](Get-ADOrganizationalUnit -Filter "Name -eq 'Utilisateurs-G4'") }
Test-Point "OU Postes-G4" { [bool](Get-ADOrganizationalUnit -Filter "Name -eq 'Postes-G4'") }
Test-Point "Groupe GG-Internet dans Utilisateurs-G4" { (Get-ADGroup GG-Internet).DistinguishedName -like "*OU=Utilisateurs-G4*" }
Test-Point "j.martin actif et membre de GG-Internet" { (Get-ADUser j.martin).Enabled -and ((Get-ADGroupMember GG-Internet).SamAccountName -contains "j.martin") }
Test-Point "p.durand actif et NON membre de GG-Internet" { (Get-ADUser p.durand).Enabled -and -not ((Get-ADGroupMember GG-Internet).SamAccountName -contains "p.durand") }
Test-Point "Compte de service svc-squid actif, mot de passe sans expiration" { $u = Get-ADUser svc-squid -Properties PasswordNeverExpires; $u.Enabled -and $u.PasswordNeverExpires }
Test-Point "PC-CLT01 dans OU=Postes-G4" { (Get-ADComputer PC-CLT01).DistinguishedName -like "*OU=Postes-G4*" }
Test-Point "Compte Kerberos du proxy SRV-PROXY01-K" { [bool](Get-ADComputer SRV-PROXY01-K) } "Relancer l'option 2 (msktutil)"
Test-Point "SPN HTTP/srv-proxy01.groupe4.internal enregistre" { ((setspn -Q HTTP/srv-proxy01.groupe4.internal) -join " ") -match "SRV-PROXY01-K" }

Titre "3. DNS"
Test-Point "Redirecteur vers 192.168.10.254" { (Get-DnsServerForwarder).IPAddress.IPAddressToString -contains "192.168.10.254" }
Test-Point "Zone inverse 10.168.192.in-addr.arpa" { [bool](Get-DnsServerZone -Name "10.168.192.in-addr.arpa") }
foreach ($e in @(@("fw01","192.168.10.254"), @("srv-ad01","192.168.10.10"), @("srv-proxy01","192.168.10.20"), @("srv-wazuh01","192.168.10.30"), @("pc-clt01","192.168.10.100"))) {
    $n = $e[0]; $ip = $e[1]
    Test-Point "$n.$D -> $ip" { (Resolve-DnsName "$n.$D" -Type A -DnsOnly -ErrorAction Stop).IPAddress -contains $ip }
}
Test-Point "Resolution inverse 192.168.10.20 -> srv-proxy01" { (Resolve-DnsName 192.168.10.20 -DnsOnly -ErrorAction Stop).NameHost -like "srv-proxy01*" }
Test-Point "Resolution Internet (debian.org)" { [bool](Resolve-DnsName debian.org -DnsOnly -ErrorAction Stop) }

Titre "4. Heure"
$st = w32tm /query /status 2>&1 | Out-String
Test-Point "Source NTP = pool.ntp.org" { $st -match "pool\.ntp\.org" }
Test-Point "Regle pare-feu Windows 'NTP serveur (UDP 123)' active" { (Get-NetFirewallRule -DisplayName "NTP serveur (UDP 123)").Enabled -eq "True" }
Test-Point "Fuseau horaire Paris (Romance Standard Time)" { (Get-TimeZone).Id -eq "Romance Standard Time" }

Titre "5. GPO"
$liens = (Get-GPInheritance -Target "OU=Postes-G4,$DN").GpoLinks
Test-Point "GPO-C-ProxyEdge liee a Postes-G4 et active" { ($liens | Where-Object DisplayName -eq "GPO-C-ProxyEdge").Enabled }
Test-Point "GPO-C-CertificatProxy liee a Postes-G4 et active" { ($liens | Where-Object DisplayName -eq "GPO-C-CertificatProxy").Enabled }
$v = (Get-GPRegistryValue -Name "GPO-C-ProxyEdge" -Key "HKLM\Software\Policies\Microsoft\Edge" -ValueName "ProxySettings" -ErrorAction SilentlyContinue).Value
Test-Point "ProxySettings = fixed_servers, srv-proxy01.groupe4.internal:3128" { $v -match '"ProxyMode":"fixed_servers"' -and $v -match 'srv-proxy01\.groupe4\.internal:3128' }
$cert = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*Groupe4 Proxy CA*" | Select-Object -First 1
Test-Point "Certificat 'Groupe4 Proxy CA' connu de l'AD" { [bool]$cert }
if ($cert) {
    Test-Point "Certificat publie dans GPO-C-CertificatProxy" { [bool](Get-GPRegistryValue -Name "GPO-C-CertificatProxy" -Key "HKLM\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\Certificates\$($cert.Thumbprint)" -ErrorAction Stop) }
    Test-Point "Certificat valide encore plus de 30 jours ($($cert.NotAfter.ToString('dd/MM/yyyy')))" { $cert.NotAfter -gt (Get-Date).AddDays(30) }
}

Titre "6. Agent Wazuh"
Test-Point "Service WazuhSvc demarre" { (Get-Service WazuhSvc).Status -eq "Running" }
Test-Point "Agent relie a 192.168.10.30" { (Get-Content "${env:ProgramFiles(x86)}\ossec-agent\ossec.conf" -Raw) -match "<address>192\.168\.10\.30</address>" }
$etat = Get-Content "${env:ProgramFiles(x86)}\ossec-agent\wazuh-agent.state" -ErrorAction SilentlyContinue | Out-String
Test-Point "Agent connecte au serveur Wazuh" { $etat -match "status='connected'" }

Titre "7. Services joignables depuis l'AD"
foreach ($s in @(@("FW01 interface web","192.168.10.254",443), @("FW01 DNS","192.168.10.254",53), @("Proxy Squid","192.168.10.20",3128), @("Proxy SSH","192.168.10.20",22), @("Wazuh interface web","192.168.10.30",443), @("Wazuh agents","192.168.10.30",1514), @("Wazuh enregistrement","192.168.10.30",1515))) {
    $n = $s[0]; $h = $s[1]; $p = $s[2]
    Test-Point "$n ($h`:$p)" { Port $h $p }
}

Titre "Bilan SRV-AD01"
$couleur = if ($script:ko -eq 0) { "Green" } else { "Red" }
Write-Host ("{0} tests reussis, {1} en echec" -f $script:ok, $script:ko) -ForegroundColor $couleur
Write-Host "Rapport : $rapport"
Stop-Transcript | Out-Null
}

function Recette-FW01 {
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
    Info "Le blocage du web direct se verifie avec la recette de PC-CLT01."
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
    Test-Point "Suricata active" { $g.enabled -eq "1" } "Option 3 ou guide etape 14"
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
}

function Recette-PC {
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
    try { $a = $c.BeginConnect($h, $p, $null, $null); $r = $a.AsyncWaitHandle.WaitOne(3000) -and $c.Connected; $c.Close(); return $r } catch { return $false }
}

$Proxy = "srv-proxy01.groupe4.internal"
$rapport = Join-Path ([Environment]::GetFolderPath("Desktop")) ("recette-PC-CLT01-{0}-{1:yyyyMMdd-HHmm}.txt" -f $env:USERNAME, (Get-Date))
Start-Transcript -Path $rapport | Out-Null
$membre = (whoami /groups) -match "GG-Internet"
Info ("Session : {0}\{1} - membre de GG-Internet : {2}" -f $env:USERDOMAIN, $env:USERNAME, [bool]$membre)

Titre "1. Machine, reseau, domaine"
Test-Point "Nom de la machine = PC-CLT01" { $env:COMPUTERNAME -eq "PC-CLT01" }
Test-Point "Adresse 192.168.10.100" { [bool](Get-NetIPAddress -IPAddress 192.168.10.100 -ErrorAction Stop) }
Test-Point "Serveur DNS = 192.168.10.10" { (Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses).ServerAddresses -contains "192.168.10.10" }
Test-Point "Membre du domaine groupe4.internal" { $c = Get-CimInstance Win32_ComputerSystem; $c.PartOfDomain -and $c.Domain -eq "groupe4.internal" }
Test-Point "Session ouverte avec un compte du domaine GROUPE4" { $env:USERDOMAIN -eq "GROUPE4" } "Ouvrir une session GROUPE4\j.martin"
Test-Point "Nom du proxy resolu (192.168.10.20)" { (Resolve-DnsName $Proxy -ErrorAction Stop).IPAddress -contains "192.168.10.20" }
$ecart = w32tm /stripchart /computer:srv-ad01.groupe4.internal /samples:1 /dataonly 2>&1 | Select-String -Pattern "([+-]\d+[\.,]\d+)s" | Select-Object -First 1
if ($ecart) { $sec = [double]($ecart.Matches[0].Groups[1].Value -replace ",", ".") } else { $sec = 999 }
Test-Point ("Ecart d'heure avec l'AD inferieur a 5 minutes ({0:N3} s)" -f $sec) { [math]::Abs($sec) -lt 300 } "Kerberos refuse au-dela de 5 minutes"

Titre "2. GPO appliquees"
$ps = (Get-ItemProperty "HKLM:\Software\Policies\Microsoft\Edge" -Name ProxySettings -ErrorAction SilentlyContinue).ProxySettings
Test-Point "Strategie Edge ProxySettings recue (proxy impose)" { $ps -match "fixed_servers" -and $ps -match "srv-proxy01\.groupe4\.internal:3128" } "gpupdate /force puis redemarrer"
Test-Point "Certificat 'Groupe4 Proxy CA' dans les racines de confiance" { [bool](Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*Groupe4 Proxy CA*") }
Test-Point "Aucun proxy manuel dans les parametres Windows" { (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings").ProxyEnable -ne 1 } "Parametres > Proxy : desactiver 'Utiliser un serveur proxy'"

Titre "3. Proxy obligatoire (regle de FW01)"
Test-Point "Acces DIRECT au web bloque (www.debian.org:443)" { -not (Port "www.debian.org" 443) } "Regle 'Web direct interdit' de FW01 absente ou inactive"
Test-Point "Acces DIRECT au web bloque (neverssl.com:80)" { -not (Port "neverssl.com" 80) }
Test-Point "Proxy joignable ($Proxy`:3128)" { Port $Proxy 3128 }

Titre "4. Navigation par le proxy : HTTPS inspecte et authentification Kerberos"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$code = 0; $emetteur = ""
try {
    $req = [Net.HttpWebRequest]::Create("https://www.debian.org/")
    $wp = New-Object Net.WebProxy("http://$Proxy`:3128")
    $wp.UseDefaultCredentials = $true
    $req.Proxy = $wp
    $req.Timeout = 20000
    $rep = $req.GetResponse(); $code = [int]$rep.StatusCode; $rep.Close()
} catch [Net.WebException] {
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { Info "Erreur : $($_.Exception.Message)" }
}
try { $emetteur = $req.ServicePoint.Certificate.Issuer } catch { }
Info "Reponse : HTTP $code ; certificat emis par : $emetteur"
Test-Point "Certificat du site fabrique par le proxy (Groupe4 Proxy CA)" { $emetteur -match "Groupe4 Proxy CA" } "Inspection HTTPS inactive ou CA non approuvee"
if ($membre) {
    Test-Point "Membre de GG-Internet : page autorisee (HTTP 200)" { $code -eq 200 }
} else {
    Test-Point "Non membre de GG-Internet : page refusee par le proxy (HTTP 403)" { $code -eq 403 } "Un 407 signifie que l'authentification Kerberos n'a pas abouti"
}
$tickets = klist 2>&1 | Out-String
Test-Point "Ticket Kerberos HTTP/srv-proxy01.groupe4.internal obtenu" { $tickets -match "HTTP/srv-proxy01\.groupe4\.internal" } "Verifier l'heure et le nom du proxy (pas d'adresse IP)"

Titre "5. Agent Wazuh"
Test-Point "Service WazuhSvc demarre" { (Get-Service WazuhSvc).Status -eq "Running" }
$etat = Get-Content "${env:ProgramFiles(x86)}\ossec-agent\wazuh-agent.state" -ErrorAction SilentlyContinue | Out-String
if ($etat) { Test-Point "Agent connecte au serveur Wazuh" { $etat -match "status='connected'" } }
else { Info "Etat de l'agent illisible avec ce compte (normal hors administrateur)" }
Test-Point "Serveur Wazuh joignable (192.168.10.30:1514)" { Port "192.168.10.30" 1514 }

Titre "Bilan PC-CLT01 ($env:USERNAME)"
$couleur = if ($script:ko -eq 0) { "Green" } else { "Red" }
Write-Host ("{0} tests reussis, {1} en echec" -f $script:ok, $script:ko) -ForegroundColor $couleur
Write-Host "Rapport : $rapport"
Stop-Transcript | Out-Null
}

function Recette-Linux {
    $rapport = Join-Path ([Environment]::GetFolderPath("Desktop")) ("recette-LINUX-{0:yyyyMMdd-HHmm}.txt" -f (Get-Date))
    Start-Transcript -Path $rapport | Out-Null
    $cmd = 'curl -fsSL https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/projet.sh -o /tmp/projet.sh && sudo bash /tmp/projet.sh test'
    foreach ($m in @(@{ Nom = "SRV-PROXY01"; Cible = "adminproxy@192.168.10.20" }, @{ Nom = "SRV-WAZUH01"; Cible = "adminwazuh@192.168.10.30" })) {
        Write-Host "`n##### $($m.Nom) ($($m.Cible)) - mots de passe : SSH puis sudo #####" -ForegroundColor Cyan
        ssh -t -o StrictHostKeyChecking=accept-new $m.Cible $cmd
    }
    Write-Host "`nRapport : $rapport"
    Stop-Transcript | Out-Null
}

# ======================================================================== MENU
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
switch ($env:COMPUTERNAME) {
    "SRV-AD01" {
        if (-not $admin) { Write-Host "[!!] Ouvrez PowerShell en administrateur" -ForegroundColor Red; break }
        do {
            Write-Host "`n================ PROJET 2 - SRV-AD01 ================" -ForegroundColor Cyan
            Write-Host " 1  Configurer SRV-AD01 (heure, DNS, comptes, GPO, agent Wazuh)"
            Write-Host " 2  Configurer SRV-WAZUH01 puis SRV-PROXY01 par SSH (Wazuh, Squid, HTTPS, Kerberos, Webmin)"
            Write-Host " 3  Configurer FW01 par l'API (agent Wazuh, blocage du web direct, IDS Suricata)"
            Write-Host " 4  Demonstration IDS : scans nmap depuis SRV-PROXY01"
            Write-Host " 5  Recette complete : AD, FW01, proxy, Wazuh (lecture seule)"
            Write-Host " 6  Recette de FW01 seule (lecture seule, sans mot de passe)"
            Write-Host " Q  Quitter"
            Write-Host " Ordre d'une installation complete : 1, 2, 1, puis option 1 sur PC-CLT01, puis 3, puis 4." -ForegroundColor DarkGray
            $c = (Read-Host "Choix").Trim().ToUpper()
            switch ($c) {
                "1" { Config-AD }
                "2" { Config-Linux }
                "3" { Config-FW01 }
                "4" { Demo-Scan }
                "5" { Recette-AD; Recette-FW01; Recette-Linux }
                "6" { Recette-FW01 }
            }
        } while ($c -ne "Q")
    }
    "PC-CLT01" {
        if (-not $admin) { Recette-PC; break }   # session j.martin ou p.durand : recette directement
        do {
            Write-Host "`n================ PROJET 2 - PC-CLT01 ================" -ForegroundColor Cyan
            Write-Host " 1  Configurer PC-CLT01 (agent Wazuh, GPO, verifications)"
            Write-Host " 5  Recette du poste (lecture seule ; a faire aussi en session j.martin et p.durand)"
            Write-Host " Q  Quitter"
            $c = (Read-Host "Choix").Trim().ToUpper()
            switch ($c) { "1" { Config-PC } "5" { Recette-PC } }
        } while ($c -ne "Q")
    }
    default { Write-Host "[!!] Machine $env:COMPUTERNAME : lancez ce script sur SRV-AD01 ou PC-CLT01" -ForegroundColor Red }
}
