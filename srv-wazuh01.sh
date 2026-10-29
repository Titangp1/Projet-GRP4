#!/bin/bash
# Projet 2 - Groupe B1-4 - SRV-WAZUH01 (Ubuntu 24.04, 192.168.10.30)
# Wazuh doit deja etre installe (wazuh-install.sh -a, etape 7 du guide).
# Fait : heure sur l'AD, regle locale qui affiche chaque acces Squid, verification des services.
# Lancement : sudo bash srv-wazuh01.sh
set -euo pipefail

etape() { echo -e "\n\e[36m=== $* ===\e[0m"; }
ok()    { echo -e "\e[32m[OK]\e[0m $*"; }

[ "$EUID" -eq 0 ] || { echo "Lancez avec sudo : sudo bash $0"; exit 1; }

etape "1. Heure sur l'AD"
timedatectl set-timezone Europe/Paris
grep -q '^NTP=192.168.10.10' /etc/systemd/timesyncd.conf || echo "NTP=192.168.10.10" >> /etc/systemd/timesyncd.conf
systemctl restart systemd-timesyncd
ok "NTP = 192.168.10.10"

etape "2. Regle locale Squid (id 100200)"
REGLES=/var/ossec/etc/rules/local_rules.xml
if ! grep -q 'id="100200"' "$REGLES"; then
  cat >> "$REGLES" <<'EOF'

<group name="squid,proxy,">
  <rule id="100200" level="3">
    <if_sid>35000</if_sid>
    <description>Proxy Squid : acces web enregistre</description>
  </rule>
</group>
EOF
fi
systemctl restart wazuh-manager
ok "Regle 100200 chargee"

etape "3. Services"
for s in wazuh-indexer wazuh-manager wazuh-dashboard filebeat; do
  echo "$s : $(systemctl is-active $s)"
done
echo -e "\nAgents enregistres (attendus : SRV-AD01, PC-CLT01, SRV-PROXY01, FW01) :"
/var/ossec/bin/agent_control -l || true

etape "4. Evenements Squid recus par Wazuh"
python3 - <<'EOF'
import json
alertes = []
try:
    with open('/var/ossec/logs/alerts/alerts.json', encoding='utf-8', errors='ignore') as f:
        for ligne in f:
            try:
                a = json.loads(ligne)
            except ValueError:
                continue
            if 'squid' in a.get('rule', {}).get('groups', []):
                alertes.append(a)
except FileNotFoundError:
    pass
refus = [a for a in alertes if '/403 ' in a.get('full_log', '') or '/407 ' in a.get('full_log', '')]
print(f"Alertes Squid : {len(alertes)} dont {len(refus)} refus (403/407)")
for a in alertes[-8:]:
    r = a.get('rule', {})
    print(a.get('timestamp', '')[:19], a.get('agent', {}).get('name', ''), r.get('id', ''),
          r.get('description', '')[:38], '|', a.get('full_log', '')[:100])
if not alertes:
    print("Aucune : naviguez depuis PC-CLT01 (session j.martin), attendez une minute et relancez.")
EOF
