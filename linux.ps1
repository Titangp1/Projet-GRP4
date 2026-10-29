# Projet 2 - Groupe B1-4 - lance les scripts Linux depuis SRV-AD01, par SSH
# Commande unique, dans PowerShell sur SRV-AD01 :
#   iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/linux.ps1 -UseBasicParsing | iex
# Ordre : SRV-WAZUH01 puis SRV-PROXY01. Les mots de passe sont demandes au fur et a mesure.

# Pas de guillemets dans la commande distante : Windows PowerShell 5.1 les transmet mal a ssh.
$Go = 'curl -fsSL https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.sh -o /tmp/go.sh && sudo bash /tmp/go.sh'

$machines = @(
    @{ Nom = "SRV-WAZUH01"; Cible = "adminwazuh@192.168.10.30" },
    @{ Nom = "SRV-PROXY01"; Cible = "adminproxy@192.168.10.20" }
)

foreach ($m in $machines) {
    Write-Host "`n##### $($m.Nom) ($($m.Cible)) #####" -ForegroundColor Cyan
    Write-Host "Mots de passe demandes : SSH, puis sudo (le meme)." -ForegroundColor Yellow
    ssh -t -o StrictHostKeyChecking=accept-new $m.Cible $Go
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[!!] $($m.Nom) s'est termine avec une erreur (code $LASTEXITCODE). Lisez les messages ci-dessus." -ForegroundColor Red
        $suite = Read-Host "Continuer quand meme avec la machine suivante ? (o/n)"
        if ($suite -ne "o") { return }
    } else {
        Write-Host "[OK] $($m.Nom) termine" -ForegroundColor Green
    }
}

Write-Host "`nEtape suivante : relancez le script de l'AD pour publier le certificat du proxy par GPO :" -ForegroundColor Cyan
Write-Host "  iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.ps1 -UseBasicParsing | iex"
