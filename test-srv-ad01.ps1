<#
  Projet 2 - Groupe B1-4 - TESTS de SRV-AD01 (lecture seule : aucune configuration n'est modifiee)
  A lancer dans PowerShell (admin) sur SRV-AD01 :
    powershell -ExecutionPolicy Bypass -File .\test-srv-ad01.ps1
  Un rapport est enregistre sur le Bureau (recette-SRV-AD01-<date>.txt).
#>
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
Test-Point "Compte Kerberos du proxy SRV-PROXY01-K" { [bool](Get-ADComputer SRV-PROXY01-K) } "Relancer srv-proxy01.sh (msktutil)"
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
