#!/bin/bash
# Projet 2 - Groupe B1-4 - SRV-WAZUH01 (Ubuntu 24.04, 192.168.10.30)
# Wazuh doit deja etre installe (wazuh-install.sh -a, etape 7 du guide).
# Fait : heure sur l'AD, regle locale Squid (100200), regles IDS Suricata (100210/100211),
# verification des services, des agents et des evenements Squid et Suricata recus.
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
ok "Regle 100200 presente"

etape "2b. Regles locales IDS Suricata de FW01 (id 100210 scans, 100211 reponses d'attaque)"
if ! grep -q 'id="100210"' "$REGLES"; then
  cp "$REGLES" "$REGLES.avant-ids"
  cat >> "$REGLES" <<'EOF2'

<group name="ids,suricata,">
  <rule id="100210" level="10">
    <if_sid>86601</if_sid>
    <field name="alert.signature" type="pcre2">(?i)scan|nmap</field>
    <description>IDS FW01 : scan reseau detecte - $(alert.signature)</description>
    <mitre>
      <id>T1046</id>
    </mitre>
  </rule>
  <rule id="100211" level="12">
    <if_sid>86601</if_sid>
    <field name="alert.signature" type="pcre2">(?i)attack_response</field>
    <description>IDS FW01 : reponse d'attaque detectee - $(alert.signature)</description>
  </rule>
</group>
EOF2
fi
# Verification de la syntaxe avant redemarrage ; retour arriere si erreur
if /var/ossec/bin/wazuh-analysisd -t >/dev/null 2>&1; then
  ok "Regles 100210 et 100211 valides"
else
  echo "[!!] Regles refusees par wazuh-analysisd : retour a la version precedente"
  [ -f "$REGLES.avant-ids" ] && cp "$REGLES.avant-ids" "$REGLES"
fi
systemctl restart wazuh-manager
ok "Wazuh manager redemarre avec les regles locales"

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

etape "5. Alertes IDS Suricata (FW01) recues par Wazuh"
python3 - <<'EOF'
import json
ids = []
try:
    with open('/var/ossec/logs/alerts/alerts.json', encoding='utf-8', errors='ignore') as f:
        for ligne in f:
            try:
                a = json.loads(ligne)
            except ValueError:
                continue
            if 'suricata' in a.get('rule', {}).get('groups', []):
                ids.append(a)
except FileNotFoundError:
    pass
scans = [a for a in ids if a.get('rule', {}).get('id') in ('100210', '100211')]
print(f"Alertes Suricata : {len(ids)} dont {len(scans)} en niveau eleve (100210/100211)")
for a in ids[-8:]:
    r = a.get('rule', {}); d = a.get('data', {})
    print(a.get('timestamp', '')[:19], r.get('id', ''), 'niv', r.get('level', ''), '|',
          d.get('src_ip', ''), '->', d.get('dest_ip', ''), '|', d.get('alert', {}).get('signature', '')[:70])
if not ids:
    print("Aucune : activez Suricata (fw01-ids.ps1), cochez 'Intrusion detection events' dans l'agent Wazuh de FW01,")
    print("lancez scan-demo.sh sur SRV-PROXY01, attendez 2 minutes et relancez.")
EOF
