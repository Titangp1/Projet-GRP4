<#
  Projet 2 - Groupe B1-4 - TESTS de PC-CLT01 (lecture seule : aucune configuration n'est modifiee)
  A lancer sur PC-CLT01, dans PowerShell, de preference en session GROUPE4\j.martin
  (puis une seconde fois en GROUPE4\p.durand pour verifier le refus) :
    powershell -ExecutionPolicy Bypass -File .\test-pc-clt01.ps1
  Un rapport est enregistre sur le Bureau (recette-PC-CLT01-<utilisateur>-<date>.txt).
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
