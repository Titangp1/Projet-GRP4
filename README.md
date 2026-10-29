# Projet 2 – Groupe B1-4 : scripts d'automatisation

Un script par machine, lancé par une seule commande à copier-coller. Chaque script peut être relancé sans risque : ce qui est déjà fait est sauté. Aucun mot de passe n'est écrit dans le dépôt, ils sont demandés à l'exécution.

Prérequis : les étapes 1 à 7 du guide sont faites (VM installées, AD promu, PC-CLT01 dans le domaine, Squid et Wazuh installés).

Astuce : ouvrez cette page dans Edge sur SRV-AD01 ou PC-CLT01, copiez la commande (Ctrl+C) et collez-la dans PowerShell avec un clic droit.

## Étape 1 – SRV-AD01

PowerShell en administrateur sur SRV-AD01 :

```powershell
iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.ps1 -UseBasicParsing | iex
```

Le message rouge « Certificat absent » est normal à ce stade.

## Étape 2 – SRV-WAZUH01 et SRV-PROXY01, depuis SRV-AD01

Toujours dans PowerShell sur SRV-AD01. Cette commande se connecte en SSH à SRV-WAZUH01 puis à SRV-PROXY01 et lance leur script :

```powershell
iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/linux.ps1 -UseBasicParsing | iex
```

Mots de passe demandés, dans l'ordre :

1. SRV-WAZUH01 : mot de passe d'adminwazuh (SSH), puis le même pour sudo.
2. SRV-PROXY01 : mot de passe d'adminproxy (SSH), puis le même pour sudo, puis celui de l'**Administrateur du domaine** (création du keytab Kerberos), puis celui de **svc-squid**.

Une seule machine à la fois, si besoin :

```powershell
ssh -t adminwazuh@192.168.10.30 'curl -fsSL https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.sh -o /tmp/go.sh && sudo bash /tmp/go.sh'
```

```powershell
ssh -t adminproxy@192.168.10.20 'curl -fsSL https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.sh -o /tmp/go.sh && sudo bash /tmp/go.sh'
```

## Étape 3 – SRV-AD01, une deuxième fois

Le certificat du proxy existe maintenant : le script le récupère (mot de passe d'adminproxy) et le publie par GPO.

```powershell
iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.ps1 -UseBasicParsing | iex
```

## Étape 4 – PC-CLT01

Session GROUPE4\Administrateur, PowerShell en administrateur :

```powershell
iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.ps1 -UseBasicParsing | iex
```

Puis redémarrez PC-CLT01, ouvrez une session GROUPE4\j.martin et testez Edge : `edge://policy`, puis https://www.debian.org (certificat délivré par Groupe4 Proxy CA).

## Étape 5 – FW01 (OPNsense), depuis SRV-AD01, en dernier

1. Dans Edge sur SRV-AD01, interface web d'OPNsense (https://192.168.10.254) : System ▸ Access ▸ Users, onglet **Users** (pas ApiKeys), ligne root, colonne Commands : icône ticket « Create and download API key for this user » ▸ **Yes**. Le fichier `fw01.groupe4.internal_root_apikey.txt` (lignes `key=` et `secret=`) se télécharge dans Téléchargements ; ne le publiez jamais.
2. PowerShell sur SRV-AD01 :

```powershell
iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/fw01.ps1 -UseBasicParsing | iex
```

Le script lit tout seul le fichier de clé (sinon il demande la clé puis le secret), installe et règle l'agent Wazuh de FW01 (manager 192.168.10.30), désactive Dnsmasq, crée les alias `Postes_clients` et `Ports_web` et la règle qui bloque le web direct de PC-CLT01.

3. À la main, 1 minute : System ▸ Settings ▸ General : Hostname `fw01`, Domain `groupe4.internal`, Timezone `Europe/Paris`, Save.

À faire en dernier : après le blocage, PC-CLT01 ne peut plus télécharger depuis Internet sans passer par le proxy.

## Étape 6 – Vérifications finales

PC-CLT01, PowerShell en administrateur (la section 6 doit afficher « Accès direct au web bloqué ») :

```powershell
iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.ps1 -UseBasicParsing | iex
```

SRV-WAZUH01, depuis PowerShell sur SRV-AD01 (liste des agents et derniers événements Squid reçus) :

```powershell
ssh -t adminwazuh@192.168.10.30 'curl -fsSL https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.sh -o /tmp/go.sh && sudo bash /tmp/go.sh'
```

## Recette : tester toutes les machines (lecture seule)

Les scripts `test*.ps1` vérifient tout le projet sans modifier aucune configuration. Chaque test affiche [OK] ou [ECHEC] avec une piste de correction, et un rapport `recette-*.txt` est enregistré sur le Bureau.

**SRV-AD01**, PowerShell en administrateur : tests de l'AD, de FW01, puis de SRV-PROXY01 et SRV-WAZUH01 par SSH (mots de passe SSH puis sudo pour chaque serveur Linux).

```powershell
iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/test.ps1 -UseBasicParsing | iex
```

Pour tester aussi la configuration de FW01 par son API (lecture seule), créez avant une clé API (étape 5) : le test la lit dans Téléchargements. Supprimez-la ensuite.

**PC-CLT01**, session GROUPE4\j.martin (le web direct étant bloqué, le téléchargement passe par le proxy) :

```powershell
(New-Object Net.WebClient -Property @{Proxy=(New-Object Net.WebProxy('http://srv-proxy01.groupe4.internal:3128') -Property @{UseDefaultCredentials=$true})}).DownloadString('https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/test.ps1') | iex
```

Puis session GROUPE4\p.durand (refusé par le proxy, il réutilise la copie de j.martin) ; le test attend cette fois un refus 403 :

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\Public\recette-g4\test-pc-clt01.ps1
```

## Optionnel – SSH sans mot de passe depuis SRV-AD01

À faire une fois dans PowerShell sur SRV-AD01 (Entrée trois fois pour ssh-keygen). Ensuite, seul le mot de passe sudo est demandé.

```powershell
ssh-keygen -t ed25519
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh adminwazuh@192.168.10.30 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh adminproxy@192.168.10.20 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

## Contenu du dépôt

| Fichier | Machine | Ce qu'il fait |
| --- | --- | --- |
| `go.ps1` | SRV-AD01, PC-CLT01 | Reconnaît la machine Windows et lance son script |
| `go.sh` | SRV-WAZUH01, SRV-PROXY01 | Reconnaît la machine Linux et lance son script |
| `fw01.ps1` | SRV-AD01 | Configure FW01 par l'API d'OPNsense : agent Wazuh, arrêt de Dnsmasq, alias, règle de blocage du web direct |
| `linux.ps1` | SRV-AD01 | Lance go.sh par SSH sur les deux machines Linux, l'une après l'autre |
| `srv-ad01.ps1` | SRV-AD01 | Heure (NTP), DNS, comptes et GG-Internet, svc-squid, OU Postes-G4, GPO proxy Edge, GPO certificat, agent Wazuh |
| `srv-wazuh01.sh` | SRV-WAZUH01 | Heure sur l'AD, règle Wazuh 100200 (accès Squid visibles), vérification des services, des agents et des événements Squid |
| `srv-proxy01.sh` | SRV-PROXY01 | Heure et DNS, paquets, agent Wazuh + journal Squid, CA et SSL-Bump, Kerberos, lecture de GG-Internet, configuration finale de Squid |
| `pc-clt01.ps1` | PC-CLT01 | Agent Wazuh, GPO, vérification du certificat, du proxy, de Kerberos et du blocage du web direct |
| `test.ps1` | SRV-AD01, PC-CLT01 | Recette : reconnaît la machine et lance les tests (lecture seule) |
| `test-srv-ad01.ps1` | SRV-AD01 | Tests de l'AD : réseau, comptes, groupe, SPN, DNS, heure, GPO, agent Wazuh, ports |
| `test-fw01.ps1` | SRV-AD01 | Tests de FW01 : ping, web, DNS, NAT ; règle, alias, agent Wazuh et Dnsmasq si une clé API est présente |
| `test-linux.ps1` | SRV-AD01 | Tests de SRV-PROXY01 et SRV-WAZUH01 par SSH : Squid, HTTPS, Kerberos, annuaire, journaux, Wazuh, agents, alertes |
| `test-pc-clt01.ps1` | PC-CLT01 | Tests du poste : domaine, heure, GPO, certificat, blocage du web direct, HTTPS inspecté, Kerberos, autorisation selon GG-Internet |

## À savoir

- Après le script du proxy, Squid exige l'authentification Kerberos : un poste réglé à la main avec l'adresse 192.168.10.20 reçoit une fenêtre d'identifiants. Les postes doivent passer par la GPO, qui utilise le nom `srv-proxy01.groupe4.internal`.
- Si la GPO du certificat ne s'applique pas, importez `squid-ca.crt` à la main dans GPO-C-CertificatProxy (étape 10.3 du guide).
- Le mot de passe de svc-squid est stocké sur le proxy dans `/etc/squid/ldap.pass` (lisible par root et Squid seulement). Pour le changer : supprimez ce fichier et relancez le script du proxy.
- Après une modification d'un fichier sur GitHub, attendez environ 5 minutes avant de relancer : raw.githubusercontent.com garde l'ancienne version en cache.
