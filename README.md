# Projet 2 – Groupe B1-4 : scripts d'automatisation

Un script par machine. Chacun peut être relancé sans risque : ce qui est déjà fait est sauté. Aucun mot de passe n'est écrit dans les scripts, ils sont demandés à l'exécution : le dépôt peut rester public.

| Script | Machine | Ce qu'il fait |
| --- | --- | --- |
| `srv-ad01.ps1` | SRV-AD01 | Heure (NTP), DNS, comptes et GG-Internet, compte svc-squid, OU Postes-G4, GPO proxy Edge, GPO certificat du proxy, agent Wazuh |
| `srv-wazuh01.sh` | SRV-WAZUH01 | Heure sur l'AD, règle Wazuh 100200 (accès Squid visibles), vérification des services |
| `srv-proxy01.sh` | SRV-PROXY01 | Heure et DNS, paquets, agent Wazuh + journal Squid, CA et SSL-Bump, Kerberos (keytab), lecture de GG-Internet, configuration finale de Squid |
| `pc-clt01.ps1` | PC-CLT01 | Agent Wazuh, application des GPO, vérification du certificat, du proxy et de Kerberos |
| `go.ps1`, `go.sh` | Toutes | Lanceurs : reconnaissent la machine et exécutent le bon script |

OPNsense (agent Wazuh, règle de blocage du web direct) reste à faire dans son interface web : étapes 8 et 12 du guide.

## Ordre d'exécution

Prérequis : les étapes 1 à 7 du guide sont faites (VM installées, AD promu, PC-CLT01 dans le domaine, Squid et Wazuh installés).

1. **SRV-AD01** : `srv-ad01.ps1` (le certificat du proxy n'existe pas encore, c'est normal)
2. **SRV-WAZUH01** : `srv-wazuh01.sh`
3. **SRV-PROXY01** : `srv-proxy01.sh` (demande le mot de passe de l'Administrateur du domaine et celui de svc-squid)
4. **SRV-AD01** : relancer `srv-ad01.ps1` (il publie cette fois le certificat par GPO)
5. **PC-CLT01** : `pc-clt01.ps1`, puis redémarrage et test en session GROUPE4\j.martin
6. **FW01** : règle de blocage (étape 12 du guide), en dernier

## Une seule commande par machine

Les lanceurs `go.ps1` et `go.sh` reconnaissent la machine par son nom, téléchargent le bon script et l'exécutent.

**Windows** (SRV-AD01 et PC-CLT01), dans PowerShell en administrateur :

```powershell
iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.ps1 -UseBasicParsing | iex
```

**Linux** (SRV-PROXY01 et SRV-WAZUH01), en ssh depuis SRV-AD01 :

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.sh)"
```

Après une modification d'un fichier sur GitHub, attendez environ 5 minutes : raw.githubusercontent.com garde l'ancienne version en cache.

## À savoir

- Après `srv-proxy01.sh`, le proxy exige l'authentification Kerberos : un poste qui l'utilise par son adresse IP (réglage manuel) reçoit une fenêtre d'identifiants. Les postes doivent passer par la GPO, qui utilise le nom `srv-proxy01.groupe4.internal`.
- Si la GPO du certificat ne s'applique pas, importez `squid-ca.crt` à la main dans GPO-C-CertificatProxy (étape 10.3 du guide).
- Le mot de passe de svc-squid est stocké sur le proxy dans `/etc/squid/ldap.pass` (lisible par root et Squid seulement). Pour le changer : supprimez ce fichier et relancez `srv-proxy01.sh`.
