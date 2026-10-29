<#
  Projet 2 - Groupe B1-4 - RECETTE COMPLETE (lecture seule : aucune configuration n'est modifiee)
  Reconnait la machine et lance les bons tests :
    - sur SRV-AD01 : tests de l'AD, de FW01, puis de SRV-PROXY01 et SRV-WAZUH01 par SSH
    - sur PC-CLT01 : tests du poste (en session j.martin, puis en session p.durand)
  SRV-AD01, PowerShell (admin) :
    iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/test.ps1 -UseBasicParsing | iex
  PC-CLT01, session j.martin (le web direct est bloque : on passe par le proxy) :
    (New-Object Net.WebClient -Property @{Proxy=(New-Object Net.WebProxy('http://srv-proxy01.groupe4.internal:3128') -Property @{UseDefaultCredentials=$true})}).DownloadString('https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/test.ps1') | iex
  PC-CLT01, session p.durand (refuse par le proxy) : reutilise la copie telechargee par j.martin :
    powershell -ExecutionPolicy Bypass -File C:\Users\Public\recette-g4\test-pc-clt01.ps1
  Les rapports sont enregistres sur le Bureau (recette-*.txt).
#>
$Depot = "https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main"
$Dossier = "C:\Users\Public\recette-g4"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Path $Dossier -Force | Out-Null

switch ($env:COMPUTERNAME) {
    "SRV-AD01" { $liste = @("test-srv-ad01.ps1", "test-fw01.ps1", "test-linux.ps1") }
    "PC-CLT01" { $liste = @("test-pc-clt01.ps1") }
    default    { Write-Host "[!!] Machine $env:COMPUTERNAME : lancez ce test depuis SRV-AD01 ou PC-CLT01" -ForegroundColor Red; return }
}

$wc = New-Object Net.WebClient
if ($env:COMPUTERNAME -eq "PC-CLT01") {
    $wp = New-Object Net.WebProxy("http://srv-proxy01.groupe4.internal:3128")
    $wp.UseDefaultCredentials = $true
    $wc.Proxy = $wp
}

foreach ($s in $liste) {
    $local = Join-Path $Dossier $s
    try { $wc.DownloadFile("$Depot/$s", $local) }
    catch {
        if (Test-Path $local) { Write-Host "[..] Telechargement impossible, copie locale utilisee : $local" -ForegroundColor Yellow }
        else { Write-Host "[!!] Telechargement de $s impossible : $($_.Exception.Message)" -ForegroundColor Red; continue }
    }
    Write-Host "`n################ $s ################" -ForegroundColor Magenta
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $local
}
Write-Host "`nRecette terminee. Rapports : Bureau, fichiers recette-*.txt" -ForegroundColor Cyan
