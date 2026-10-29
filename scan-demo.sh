#!/bin/bash
# Projet 2 - Groupe B1-4 - Demonstration IDS : scans nmap a detecter par Suricata (FW01) et Wazuh
# A lancer sur SRV-PROXY01 (sert de poste d'audit), apres fw01-ids.ps1 :
#   sudo bash scan-demo.sh
# Ne scanner QUE nos machines et scanme.nmap.org (cible officielle autorisee par le projet Nmap).
set -uo pipefail

etape() { echo -e "\n\e[36m=== $* ===\e[0m"; }
ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
[ "$EUID" -eq 0 ] || { echo "Lancez avec sudo : sudo bash $0"; exit 1; }

FW=192.168.10.254

etape "1. Installation de nmap"
command -v nmap >/dev/null || { apt-get update -qq && apt-get install -y -qq nmap curl; }
ok "$(nmap --version | head -1)"

etape "2. Decouverte du reseau LAN (ping scan)"
nmap -sn 192.168.10.0/24

etape "3. Scan SYN des 1000 ports courants de FW01"
nmap -sS -T4 $FW

etape "4. Detection des services et scripts NSE sur FW01 (ports 22, 53, 80, 443)"
nmap -sV -sC -p 22,53,80,443 $FW

etape "5. Detection du systeme d'exploitation de FW01"
nmap -O $FW

etape "6. Scan de scanme.nmap.org (cible autorisee) : User-Agent Nmap en clair sur le port 80"
nmap -sV -sC -p 80 scanme.nmap.org

etape "7. Test de controle : la chaine 'uid=0(root)' traverse FW01 (signature GPL ATTACK_RESPONSE)"
# testmynids.org n'existe plus : on envoie nous-memes la chaine a FW01 (la reponse importe peu)
curl -s -m 10 -o /dev/null "http://$FW/uid=0(root)" || true
echo "Requete envoyee vers $FW avec 'uid=0(root)'"

etape "Ou regarder"
echo " - OPNsense : Services > Intrusion Detection > Administration > onglet Alerts (source $(hostname -I | awk '{print $1}'))"
echo " - Wazuh    : Threat Hunting, filtre rule.groups: suricata  (ou rule.id: 100210)"
echo " - Les alertes arrivent dans Wazuh en 1 a 2 minutes."
