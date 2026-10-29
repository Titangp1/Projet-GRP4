#Requires -RunAsAdministrator
<#
  Projet 2 - Groupe B1-4 - SRV-AD01 (192.168.10.10)
  Fait automatiquement, sans rien casser si on le relance :
    1. Heure : AD synchronise sur Internet, serveur de temps du reseau (UDP 123)
    2. DNS   : redirecteur, zone inverse, enregistrements fw01 / srv-proxy01 / srv-wazuh01
    3. Annuaire : OU Utilisateurs-G4, GG-Internet, j.martin, p.durand, svc-squid
    4. OU Postes-G4 et deplacement de PC-CLT01
    5. GPO-C-ProxyEdge (proxy impose dans Edge)
    6. GPO-C-CertificatProxy (CA du proxy approuvee) - si le certificat est disponible
    7. Agent Wazuh
  Aucun mot de passe n'est ecrit dans ce script : ils sont demandes a l'execution.
  A lancer dans PowerShell (admin) :
    powershell -ExecutionPolicy Bypass -File .\srv-ad01.ps1
#>

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
    Alerte "Certificat absent : lancez d'abord srv-proxy01.sh sur le proxy, puis relancez ce script"
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
Write-Host "Termine. Sur PC-CLT01 : lancez pc-clt01.ps1." -ForegroundColor Cyan
