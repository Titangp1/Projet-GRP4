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

## Étape 5 – FW01 (à la main)

Dans l'interface web d'OPNsense : agent Wazuh (étape 8 du guide), puis règle de blocage du web direct (étape 12). À faire en dernier : après le blocage, PC-CLT01 ne peut plus télécharger depuis Internet.

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
| `linux.ps1` | SRV-AD01 | Lance go.sh par SSH sur les deux machines Linux, l'une après l'autre |
| `srv-ad01.ps1` | SRV-AD01 | Heure (NTP), DNS, comptes et GG-Internet, svc-squid, OU Postes-G4, GPO proxy Edge, GPO certificat, agent Wazuh |
| `srv-wazuh01.sh` | SRV-WAZUH01 | Heure sur l'AD, règle Wazuh 100200 (accès Squid visibles), vérification des services |
| `srv-proxy01.sh` | SRV-PROXY01 | Heure et DNS, paquets, agent Wazuh + journal Squid, CA et SSL-Bump, Kerberos, lecture de GG-Internet, configuration finale de Squid |
| `pc-clt01.ps1` | PC-CLT01 | Agent Wazuh, GPO, vérification du certificat, du proxy et de Kerberos |

## À savoir

- Après le script du proxy, Squid exige l'authentification Kerberos : un poste réglé à la main avec l'adresse 192.168.10.20 reçoit une fenêtre d'identifiants. Les postes doivent passer par la GPO, qui utilise le nom `srv-proxy01.groupe4.internal`.
- Si la GPO du certificat ne s'applique pas, importez `squid-ca.crt` à la main dans GPO-C-CertificatProxy (étape 10.3 du guide).
- Le mot de passe de svc-squid est stocké sur le proxy dans `/etc/squid/ldap.pass` (lisible par root et Squid seulement). Pour le changer : supprimez ce fichier et relancez le script du proxy.
- Après une modification d'un fichier sur GitHub, attendez environ 5 minutes avant de relancer : raw.githubusercontent.com garde l'ancienne version en cache.
