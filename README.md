# Projet 2 – Groupe B1-4 : scripts d'automatisation (version finale du 29 octobre 2026)

Deux scripts seulement :

| Fichier | Où | Rôle |
| --- | --- | --- |
| `projet.ps1` | SRV-AD01, PC-CLT01 | Menu : configuration de l'AD, des serveurs Linux (par SSH), de FW01 (par l'API), du poste client, démonstration nmap et recette |
| `projet.sh` | SRV-PROXY01, SRV-WAZUH01 | Configuration de la machine (Squid, HTTPS, Kerberos, Webmin / règles Wazuh), recette (`test`), scans nmap (`scan`). Lancé automatiquement par `projet.ps1` |

Chaque partie peut être relancée sans risque : ce qui est déjà fait est sauté. Aucun mot de passe n'est écrit dans le dépôt, ils sont demandés à l'exécution. La recette ne modifie aucune configuration.

Prérequis : étapes 1 à 7 du guide faites (VM installées, AD promu, PC-CLT01 dans le domaine, Squid et Wazuh installés).

Astuce : ouvrez cette page dans Edge sur SRV-AD01 ou PC-CLT01, copiez la commande avec le bouton de copie et collez-la dans PowerShell avec un clic droit.

## Lancer le menu (SRV-AD01 et PC-CLT01)

PowerShell **en administrateur** :

```powershell
md C:\Users\Public\g4 -Force | Out-Null; iwr https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/projet.ps1 -UseBasicParsing -OutFile C:\Users\Public\g4\projet.ps1; powershell -ExecutionPolicy Bypass -File C:\Users\Public\g4\projet.ps1
```

Menu sur SRV-AD01 :

| Option | Effet |
| --- | --- |
| 1 | SRV-AD01 : heure, DNS, comptes et GG-Internet, svc-squid, OU Postes-G4, GPO du proxy et du certificat, agent Wazuh |
| 2 | Par SSH : SRV-WAZUH01 (règles 100200, 100210, 100211) puis SRV-PROXY01 (agent Wazuh, CA et SSL-Bump, Kerberos, groupe AD, Squid final, Webmin et Calamaris). Mots de passe : SSH puis sudo pour chaque serveur, puis Administrateur du domaine et svc-squid pour le proxy |
| 3 | FW01 par l'API : agent Wazuh, Dnsmasq arrêté, alias, règle « Web direct interdit », puis IDS Suricata |
| 4 | Démonstration IDS : scans nmap depuis SRV-PROXY01 |
| 5 | Recette complète : AD, FW01, proxy et Wazuh |
| 6 | Recette de FW01 seule |

Menu sur PC-CLT01 (session GROUPE4\Administrateur) : 1 = configuration du poste, 5 = recette.

## Ordre d'une installation complète

1. SRV-AD01 : option **1** (le message « Certificat absent » est normal à ce stade).
2. SRV-AD01 : option **2**.
3. SRV-AD01 : option **1** une seconde fois (le certificat du proxy est publié par GPO).
4. PC-CLT01 : option **1**, puis redémarrer PC-CLT01.
5. FW01 : créer une clé API (System ▸ Access ▸ Users, onglet Users, ligne root, icône ticket « Create and download API key for this user ») ; le fichier `…apikey.txt` arrive dans Téléchargements. Pour l'IDS, régler aussi Interfaces ▸ Settings (Hardware CRC, TSO et LRO cochés, VLAN Hardware Filtering = Disable) et redémarrer FW01.
6. SRV-AD01 : option **3**, en dernier (ensuite PC-CLT01 ne sort plus sur le web que par le proxy). Puis à la main : System ▸ Settings ▸ General, Hostname `fw01`, Domain `groupe4.internal`, Timezone `Europe/Paris`.
7. OPNsense ▸ Services ▸ Wazuh Agent ▸ Settings : vérifier que « Intrusion detection events » est coché.
8. SRV-AD01 : option **4** (scans nmap), puis voir Services ▸ Intrusion Detection ▸ Administration ▸ Alerts dans OPNsense et Threat Hunting (`rule.groups: suricata`) dans Wazuh.
9. Webmin : Edge sur SRV-AD01, https://192.168.10.20:10000, compte adminproxy, puis Servers ▸ Squid Proxy Server.
10. Supprimer la clé API (onglet ApiKeys) et le fichier `…apikey.txt`.

## Recette

**SRV-AD01** : menu, option **5** (option **6** pour FW01 seul). Les tests de FW01 par l'API demandent une clé API dans Téléchargements.

**PC-CLT01, session GROUPE4\j.martin** (PowerShell normal ; le web direct étant bloqué, le téléchargement passe par le proxy) :

```powershell
md C:\Users\Public\g4 -Force | Out-Null; $wc = New-Object Net.WebClient; $wc.Proxy = New-Object Net.WebProxy('http://srv-proxy01.groupe4.internal:3128'); $wc.Proxy.UseDefaultCredentials = $true; $wc.DownloadFile('https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/projet.ps1', 'C:\Users\Public\g4\projet.ps1'); powershell -ExecutionPolicy Bypass -File C:\Users\Public\g4\projet.ps1
```

**PC-CLT01, session GROUPE4\p.durand** (refusé par le proxy : il réutilise la copie de j.martin ; le test attend un refus 403) :

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\Public\g4\projet.ps1
```

Sans droits d'administrateur, le script lance directement la recette. Les rapports `recette-*.txt` sont enregistrés sur le Bureau.

Les tests « refus 403 de p.durand » (journal de Squid et Wazuh) cherchent une trace récente : s'ils échouent, naviguez quelques minutes en session p.durand sur PC-CLT01, attendez 2 minutes et relancez la recette.

Résultat de la recette finale du 29 octobre 2026 : SRV-AD01 44/44, FW01 17/17, SRV-PROXY01 36/36, SRV-WAZUH01 25/25, PC-CLT01 18/18 en session j.martin et 18/18 en session p.durand.

## Optionnel – SSH sans mot de passe depuis SRV-AD01

À faire une fois dans PowerShell sur SRV-AD01 (Entrée trois fois pour ssh-keygen). Ensuite, seul le mot de passe sudo est demandé.

```powershell
ssh-keygen -t ed25519
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh adminwazuh@192.168.10.30 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh adminproxy@192.168.10.20 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

## À savoir

- Squid exige l'authentification Kerberos : un poste réglé à la main avec l'adresse 192.168.10.20 reçoit une fenêtre d'identifiants. Les postes doivent passer par la GPO, qui utilise le nom `srv-proxy01.groupe4.internal`.
- Si la GPO du certificat ne s'applique pas, importez `squid-ca.crt` à la main dans GPO-C-CertificatProxy (étape 10.3 du guide).
- Le mot de passe de svc-squid est stocké sur le proxy dans `/etc/squid/ldap.pass` (lisible par root et Squid seulement). Pour le changer : supprimez ce fichier et relancez l'option 2.
- Webmin est installé depuis le paquet officiel publié sur GitHub (le dépôt download.webmin.com est refusé depuis le réseau de l'école). Il n'est accessible que depuis SRV-AD01. Les règles du projet restent dans `/etc/squid/conf.d/groupe4.conf` : ne pas les recréer dans les écrans Access Control de Webmin.
- Après une modification d'un fichier sur GitHub, attendez environ 5 minutes avant de relancer : raw.githubusercontent.com garde l'ancienne version en cache.
