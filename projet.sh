#!/bin/bash
# Projet 2 - Groupe B1-4 - SCRIPT LINUX UNIQUE (SRV-PROXY01 et SRV-WAZUH01) - version finale du 29/10/2026
# Reconnait la machine par son nom. Aucun mot de passe n'est ecrit ici : ils sont demandes a l'execution.
#   sudo bash projet.sh          configuration de la machine (relancable sans risque)
#   sudo bash projet.sh test     recette (lecture seule)
#   sudo bash projet.sh scan     demonstration IDS : scans nmap (SRV-PROXY01)
# Normalement lance depuis SRV-AD01 par projet.ps1 (options 2, 4 et 5).
MODE="${1:-config}"
[ "$EUID" -eq 0 ] || { echo "Lancez avec sudo : sudo bash $0 $MODE"; exit 1; }

# ======================================================================== CONFIGURATION
config_proxy() {

WAZUH_IP=192.168.10.30
WAZUH_VER=4.14.9-1
REALM=GROUPE4.INTERNAL
DC=srv-ad01.groupe4.internal
FQDN=srv-proxy01.groupe4.internal

etape() { echo -e "\n\e[36m=== $* ===\e[0m"; }
ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
alerte(){ echo -e "\e[31m[!!]\e[0m $*"; }

[ "$EUID" -eq 0 ] || { alerte "Lancez avec sudo : sudo bash $0"; exit 1; }

# ---------------------------------------------------------------- 1
etape "1. Heure et DNS sur l'AD"
timedatectl set-timezone Europe/Paris
printf 'search groupe4.internal\nnameserver 192.168.10.10\n' > /etc/resolv.conf
grep -q '^NTP=192.168.10.10' /etc/systemd/timesyncd.conf || echo "NTP=192.168.10.10" >> /etc/systemd/timesyncd.conf
systemctl restart systemd-timesyncd
getent hosts "$DC" >/dev/null && ok "srv-ad01 resolu : $(getent hosts $DC)" || { alerte "srv-ad01 introuvable dans le DNS"; exit 1; }

# ---------------------------------------------------------------- 2
etape "2. Paquets"
echo "krb5-config krb5-config/default_realm string $REALM" | debconf-set-selections
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q squid-openssl curl wget krb5-user msktutil libsasl2-modules-gssapi-mit ldap-utils
ok "Paquets installes"

# ---------------------------------------------------------------- 3
etape "3. Agent Wazuh"
if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
  wget -q -O /tmp/wazuh-agent.deb "https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_VER}_amd64.deb"
  WAZUH_MANAGER="$WAZUH_IP" WAZUH_AGENT_NAME="SRV-PROXY01" WAZUH_AGENT_GROUP="default" dpkg -i /tmp/wazuh-agent.deb
fi
if ! grep -q '/var/log/squid/access.log' /var/ossec/etc/ossec.conf; then
  cat >> /var/ossec/etc/ossec.conf <<'EOF'

<ossec_config>
  <localfile>
    <log_format>squid</log_format>
    <location>/var/log/squid/access.log</location>
  </localfile>
</ossec_config>
EOF
fi
systemctl daemon-reload
systemctl enable wazuh-agent >/dev/null
systemctl restart wazuh-agent
ok "Agent Wazuh : $(systemctl is-active wazuh-agent), journal Squid suivi"

# ---------------------------------------------------------------- 4
etape "4. Autorite de certification et base SSL-Bump"
mkdir -p /etc/squid/ssl
if [ ! -f /etc/squid/ssl/squid-ca.crt ]; then
  openssl req -new -newkey rsa:4096 -sha256 -days 3650 -noenc -x509 \
    -subj "/C=FR/O=Groupe4/CN=Groupe4 Proxy CA" \
    -keyout /etc/squid/ssl/squid-ca.key -out /etc/squid/ssl/squid-ca.crt
fi
chown root:proxy /etc/squid/ssl/squid-ca.key
chmod 640 /etc/squid/ssl/squid-ca.key
chmod 644 /etc/squid/ssl/squid-ca.crt
if [ ! -d /var/spool/squid/ssl_db ]; then
  /usr/lib/squid/security_file_certgen -c -s /var/spool/squid/ssl_db -M 16MB
fi
chown -R proxy:proxy /var/spool/squid/ssl_db
sed -i 's/^http_port 3128$/#http_port 3128/' /etc/squid/squid.conf
ok "CA : $(openssl x509 -in /etc/squid/ssl/squid-ca.crt -noout -subject)"

# ---------------------------------------------------------------- 5
etape "5. Kerberos"
[ -f /etc/krb5.conf.orig ] || cp /etc/krb5.conf /etc/krb5.conf.orig 2>/dev/null || true
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = $REALM
    dns_lookup_kdc = false
    dns_lookup_realm = false
    rdns = false

[realms]
    $REALM = {
        kdc = $DC
        admin_server = $DC
    }

[domain_realm]
    .groupe4.internal = $REALM
    groupe4.internal = $REALM
EOF
if [ ! -f /etc/squid/HTTP.keytab ]; then
  echo "Mot de passe de l'Administrateur du domaine :"
  kinit Administrateur
  msktutil -c -b "CN=COMPUTERS" -s "HTTP/$FQDN" -k /etc/squid/HTTP.keytab \
    --computer-name SRV-PROXY01-K --upn "HTTP/$FQDN" --server "$DC" \
    --no-reverse-lookups --enctypes 24 --verbose
  kdestroy
fi
chgrp proxy /etc/squid/HTTP.keytab
chmod 640 /etc/squid/HTTP.keytab
klist -ke /etc/squid/HTTP.keytab | grep -q "HTTP/$FQDN@$REALM" && ok "Keytab HTTP/$FQDN pret" || { alerte "Keytab incomplet"; exit 1; }

# ---------------------------------------------------------------- 6
etape "6. Lecture de l'annuaire (svc-squid)"
LDAP_ARGS=(-R -K -S -b "dc=groupe4,dc=internal" -D svc-squid@groupe4.internal -W /etc/squid/ldap.pass
  -f "(&(objectClass=person)(sAMAccountName=%u)(memberOf=cn=%g,ou=Utilisateurs-G4,dc=groupe4,dc=internal))"
  -h "$DC")
if [ ! -f /etc/squid/ldap.pass ]; then
  read -r -s -p "Mot de passe de svc-squid : " MDP; echo
  printf '%s\n' "$MDP" > /etc/squid/ldap.pass
  unset MDP
fi
chown root:proxy /etc/squid/ldap.pass
chmod 640 /etc/squid/ldap.pass
R1=$(echo "j.martin GG-Internet" | sudo -u proxy /usr/lib/squid/ext_ldap_group_acl "${LDAP_ARGS[@]}" || true)
R2=$(echo "p.durand GG-Internet" | sudo -u proxy /usr/lib/squid/ext_ldap_group_acl "${LDAP_ARGS[@]}" || true)
echo "j.martin -> $R1 (attendu OK) ; p.durand -> $R2 (attendu ERR)"
[[ "$R1" == OK* ]] && ok "Lecture de GG-Internet fonctionnelle" || alerte "j.martin refuse : verifiez le mot de passe dans /etc/squid/ldap.pass (supprimez le fichier et relancez)"

# ---------------------------------------------------------------- 7
etape "7. Configuration finale de Squid"
[ -f /etc/squid/conf.d/groupe4.conf ] && cp /etc/squid/conf.d/groupe4.conf "/etc/squid/groupe4.conf.$(date +%Y%m%d-%H%M%S).bak"
cat > /etc/squid/conf.d/groupe4.conf <<'EOF'
# Groupe 4 - proxy Squid de SRV-PROXY01
visible_hostname srv-proxy01.groupe4.internal
acl reseau_interne src 192.168.10.0/24

# Inspection HTTPS (SSL-Bump)
http_port 3128 ssl-bump tls-cert=/etc/squid/ssl/squid-ca.crt tls-key=/etc/squid/ssl/squid-ca.key generate-host-certificates=on dynamic_cert_mem_cache_size=16MB
sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/spool/squid/ssl_db -M 16MB
sslcrtd_children 5
acl etape1 at_step SslBump1
acl sans_dechiffrement ssl::server_name .windowsupdate.com .update.microsoft.com
ssl_bump peek etape1
ssl_bump splice sans_dechiffrement
ssl_bump bump all

# Authentification Kerberos par l'AD
auth_param negotiate program /usr/lib/squid/negotiate_kerberos_auth -k /etc/squid/HTTP.keytab -s HTTP/srv-proxy01.groupe4.internal@GROUPE4.INTERNAL
auth_param negotiate children 10
auth_param negotiate keep_alive on
acl authentifie proxy_auth REQUIRED

# Appartenance au groupe GG-Internet
external_acl_type groupe_ad ttl=300 negative_ttl=60 %LOGIN /usr/lib/squid/ext_ldap_group_acl -R -K -S -b "dc=groupe4,dc=internal" -D svc-squid@groupe4.internal -W /etc/squid/ldap.pass -f "(&(objectClass=person)(sAMAccountName=%u)(memberOf=cn=%g,ou=Utilisateurs-G4,dc=groupe4,dc=internal))" -h srv-ad01.groupe4.internal
acl gg_internet external groupe_ad GG-Internet

# Regles d'acces, dans cet ordre
http_access deny !reseau_interne
http_access deny !authentifie
http_access allow gg_internet
http_access deny all
EOF
if squid -k parse 2>&1 | grep -E "FATAL|ERROR"; then
  alerte "Erreur dans la configuration de Squid (voir ci-dessus)"; exit 1
fi
systemctl restart squid
ok "Squid : $(systemctl is-active squid)"

# ---------------------------------------------------------------- Bilan
etape "Bilan"
timedatectl timesync-status | grep -E "Server|Offset" || true
ss -ltn | grep -q ':3128' && ok "Squid ecoute sur 3128"
EMETTEUR=$(curl -sv -o /dev/null -x http://127.0.0.1:3128 --cacert /etc/squid/ssl/squid-ca.crt https://www.debian.org 2>&1 | grep -i "issuer:" || true)
echo "Certificat vu par un client : ${EMETTEUR:-aucun (verifiez /var/log/squid/cache.log)}"
tail -n 3 /var/log/squid/access.log || true
echo -e "\nTermine. Ensuite : projet.ps1 option 1 sur SRV-AD01 (GPO du certificat), puis option 1 sur PC-CLT01."
}

config_webmin() {

etape() { echo -e "\n\e[36m=== $* ===\e[0m"; }
ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
info()  { echo -e "\e[33m[..]\e[0m $*"; }
[ "$EUID" -eq 0 ] || { echo "Lancez avec sudo : sudo bash $0"; exit 1; }

ADMIN=192.168.10.10     # seul poste autorise a ouvrir Webmin (SRV-AD01)

etape "1. Paquet Webmin (publication officielle sur GitHub)"
# download.webmin.com presente un certificat refuse depuis le reseau de l'ecole :
# on installe le paquet .deb publie par le projet Webmin sur GitHub (github.com est joignable).
rm -f /etc/apt/sources.list.d/webmin*.list /etc/apt/sources.list.d/webmin*.sources
if ! dpkg -s webmin >/dev/null 2>&1; then
  TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/webmin/webmin/releases/latest | sed 's#.*/tag/##')
  [ -n "$TAG" ] && [ "${TAG#http}" = "$TAG" ] || TAG=2.670
  info "Version $TAG"
  curl -fsSL -o /tmp/webmin.deb "https://github.com/webmin/webmin/releases/download/$TAG/webmin_${TAG}_all.deb"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /tmp/webmin.deb
fi
ok "Webmin $(cat /etc/webmin/version 2>/dev/null) installe"

etape "2. Calamaris et outils du cache"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq calamaris squidclient || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq squid-cgi || info "squid-cgi absent : statistiques du cache non disponibles (sans gravite)"
ok "Calamaris installe"
# squid-cgi installe Apache par dependance : inutile ici (Webmin lance cachemgr.cgi lui-meme), on l'arrete
if systemctl list-unit-files apache2.service >/dev/null 2>&1; then
  systemctl disable --now apache2 >/dev/null 2>&1 || true
  ok "Apache (installe avec squid-cgi) arrete et desactive : port 80 du proxy ferme"
fi

etape "3. Acces a Webmin limite a SRV-AD01 ($ADMIN) et a la machine elle-meme"
CONF=/etc/webmin/miniserv.conf
# Webmin ecoute aussi en IPv6 : un client IPv4 peut lui apparaitre sous la forme ::ffff:192.168.10.10
sed -i '/^allow=/d' "$CONF"
[ -z "$(tail -c1 "$CONF")" ] || echo >> "$CONF"
echo "allow=127.0.0.1 ::1 $ADMIN ::ffff:$ADMIN" >> "$CONF"
systemctl enable webmin >/dev/null 2>&1 || true
systemctl restart webmin
ok "Webmin redemarre"

etape "4. Module Squid de Webmin"
MOD=/etc/webmin/squid/config
if [ -f "$MOD" ]; then
  grep -q '^squid_conf=' "$MOD" && sed -i 's#^squid_conf=.*#squid_conf=/etc/squid/squid.conf#' "$MOD"
  grep -q '^log_dir=' "$MOD" && sed -i 's#^log_dir=.*#log_dir=/var/log/squid#' "$MOD"
  ok "Module Squid : /etc/squid/squid.conf, journaux /var/log/squid"
else
  info "Configuration du module Squid absente : elle sera creee a la premiere ouverture du module"
fi

etape "5. Verification"
systemctl is-active --quiet webmin && ok "Service webmin actif" || echo "[!!] webmin inactif : journalctl -u webmin"
for i in $(seq 1 15); do ss -ltn | grep -q ':10000 ' && break; sleep 2; done
ss -ltn | grep -q ':10000 ' && ok "Webmin ecoute sur le port 10000" || echo "[!!] port 10000 ferme"
command -v calamaris >/dev/null && ok "Calamaris present (icone 'Calamaris Log Analysis' du module Squid)"
squid -k parse >/dev/null 2>&1 && ok "Configuration Squid toujours valide (rien n'a ete modifie)"

echo -e "\nOuvrir dans Edge sur SRV-AD01 : https://192.168.10.20:10000"
echo "Connexion : compte adminproxy (membre de sudo). Le compte root de Debian n'a pas de mot de passe et ne peut pas se connecter."
echo "Puis : Servers > Squid Proxy Server. Les regles du projet sont dans /etc/squid/conf.d/groupe4.conf"
echo "(Edit Config Files) : ne pas les recreer dans les ecrans Access Control de Webmin."
}

config_wazuh() {

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
CHANGE=0
if ! grep -q 'id="100200"' "$REGLES"; then
  CHANGE=1
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
  CHANGE=1
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
# Redemarrage seulement si une regle a ete ajoutee : sinon les agents se deconnectent 1 a 2 minutes pour rien
if [ "$CHANGE" = 1 ]; then
  systemctl restart wazuh-manager
  ok "Wazuh manager redemarre avec les regles locales (agents reconnectes sous 2 minutes)"
else
  ok "Regles deja en place : pas de redemarrage de Wazuh"
fi

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
    print("Aucune : activez Suricata (option 3 de projet.ps1), cochez 'Intrusion detection events' dans l'agent Wazuh de FW01,")
    print("lancez l'option 4 de projet.ps1, attendez 2 minutes et relancez.")
EOF
}

demo_scan() {

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
}

# ======================================================================== RECETTE (lecture seule)
ok=0; ko=0
t() { if eval "$2" >/dev/null 2>&1; then echo -e "\e[32m[OK]\e[0m    $1"; ok=$((ok+1)); else echo -e "\e[31m[ECHEC]\e[0m $1"; [ -n "$3" ] && echo "        -> $3"; ko=$((ko+1)); fi; }
titre() { echo -e "\n\e[36m=== $* ===\e[0m"; }
info() { echo -e "\e[33m[INFO]\e[0m  $*"; }
port() { timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
bilan() { titre "Bilan $(hostname)"; echo "$ok tests reussis, $ko en echec"; }

test_proxy() {
titre "1. Machine, DNS et heure"
t "Nom srv-proxy01" '[ "$(hostname -s)" = srv-proxy01 ]'
t "Adresse 192.168.10.20/24" 'ip -4 addr | grep -q "192.168.10.20/24"'
t "DNS = AD (192.168.10.10)" 'grep -q "^nameserver 192.168.10.10" /etc/resolv.conf'
t "srv-ad01.groupe4.internal resolu" 'getent hosts srv-ad01.groupe4.internal'
t "Heure synchronisee" 'timedatectl show -p NTPSynchronized --value | grep -q yes'
t "Serveur NTP = AD (192.168.10.10)" 'timedatectl show-timesync -p ServerName --value | grep -q 192.168.10.10' "NTP=192.168.10.10 dans /etc/systemd/timesyncd.conf"
t "Kerberos de l'AD joignable (88)" 'port 192.168.10.10 88'
t "LDAP de l'AD joignable (389)" 'port 192.168.10.10 389'
titre "2. Squid"
t "Paquet squid-openssl installe" 'dpkg -s squid-openssl'
t "Service squid actif" 'systemctl is-active squid'
t "Squid ecoute sur 3128" 'ss -ltn | grep -q ":3128 "'
t "Configuration sans ERROR ni FATAL" '! squid -k parse 2>&1 | grep -Eq "FATAL|ERROR"'
t "groupe4.conf : ssl-bump, Kerberos, groupe AD, refus final" 'grep -q ssl-bump /etc/squid/conf.d/groupe4.conf && grep -q negotiate_kerberos_auth /etc/squid/conf.d/groupe4.conf && grep -q ext_ldap_group_acl /etc/squid/conf.d/groupe4.conf && grep -q "http_access deny all" /etc/squid/conf.d/groupe4.conf'
titre "3. Inspection HTTPS"
t "CA Groupe4 Proxy CA presente" 'openssl x509 -in /etc/squid/ssl/squid-ca.crt -noout -subject | grep -q "Groupe4 Proxy CA"'
t "Certificat d'autorite (CA:TRUE)" 'openssl x509 -in /etc/squid/ssl/squid-ca.crt -noout -text | grep -q "CA:TRUE"'
t "CA valide encore 30 jours" 'openssl x509 -in /etc/squid/ssl/squid-ca.crt -noout -checkend 2592000'
t "Cle privee protegee (640 root:proxy)" '[ "$(stat -c %a:%U:%G /etc/squid/ssl/squid-ca.key)" = 640:root:proxy ]'
t "Base des certificats generes (ssl_db)" '[ "$(stat -c %U /var/spool/squid/ssl_db)" = proxy ]'
t "Site HTTPS rechiffre par le proxy (issuer Groupe4 Proxy CA)" 'curl -sv -o /dev/null -m 20 -x http://127.0.0.1:3128 --cacert /etc/squid/ssl/squid-ca.crt https://www.debian.org 2>&1 | grep -i "issuer:" | grep -q "Groupe4 Proxy CA"'
titre "4. Authentification AD"
t "Keytab HTTP/srv-proxy01.groupe4.internal" 'klist -ke /etc/squid/HTTP.keytab | grep -q "HTTP/srv-proxy01.groupe4.internal@GROUPE4.INTERNAL"'
t "Keytab lisible par Squid (groupe proxy)" '[ "$(stat -c %G /etc/squid/HTTP.keytab)" = proxy ]'
t "Mot de passe svc-squid protege (640)" '[ "$(stat -c %a /etc/squid/ldap.pass)" = 640 ]'
L='/usr/lib/squid/ext_ldap_group_acl -R -K -S -b dc=groupe4,dc=internal -D svc-squid@groupe4.internal -W /etc/squid/ldap.pass -h srv-ad01.groupe4.internal -f (&(objectClass=person)(sAMAccountName=%u)(memberOf=cn=%g,ou=Utilisateurs-G4,dc=groupe4,dc=internal))'
t "Annuaire : j.martin membre de GG-Internet" 'echo "j.martin GG-Internet" | sudo -u proxy $L | grep -q ^OK'
t "Annuaire : p.durand refuse" 'echo "p.durand GG-Internet" | sudo -u proxy $L | grep -q ^ERR'
LOGS="/var/log/squid/access.log /var/log/squid/access.log.1"   # journal du jour et de la veille (rotation quotidienne)
t "Journal : acces autorises de j.martin" 'grep -hqs "j.martin@GROUPE4.INTERNAL" $LOGS'
t "Journal : refus 403 de p.durand" 'grep -hs "p.durand@GROUPE4.INTERNAL" $LOGS | grep -q "/403 "' "Naviguer en session p.durand sur PC-CLT01, puis relancer"
t "Journal : pages HTTPS completes (GET https://)" 'grep -hqs " GET https://" $LOGS'
titre "5. Agent Wazuh"
t "Service wazuh-agent actif" 'systemctl is-active wazuh-agent'
t "Agent connecte au serveur" 'grep -q "status=.connected." /var/ossec/var/run/wazuh-agentd.state'
t "Serveur = 192.168.10.30" 'grep -q "<address>192.168.10.30</address>" /var/ossec/etc/ossec.conf'
t "Journal Squid suivi par l'agent" 'grep -q "/var/log/squid/access.log" /var/ossec/etc/ossec.conf'
titre "6. Interface graphique (Webmin) et outil de scan"
t "Service webmin actif" 'systemctl is-active webmin' "Relancer l'option 2 de projet.ps1 (guide etape 15)"
t "Webmin ecoute sur 10000" 'ss -ltn | grep -q ":10000 "'
t "Webmin reserve a SRV-AD01 (allow)" 'grep -q "^allow=.*192.168.10.10" /etc/webmin/miniserv.conf'
t "Calamaris installe (rapports Squid)" 'command -v calamaris'
t "nmap installe (demonstration IDS)" 'command -v nmap' "Option 4 de projet.ps1 (guide etape 14)"
bilan
}

test_wazuh() {
titre "1. Machine et heure"
t "Nom srv-wazuh01" '[ "$(hostname -s)" = srv-wazuh01 ]'
t "Adresse 192.168.10.30/24" 'ip -4 addr | grep -q "192.168.10.30/24"'
t "Heure synchronisee" 'timedatectl show -p NTPSynchronized --value | grep -q yes'
t "Espace disque utilise < 85 %" '[ "$(df --output=pcent / | tail -1 | tr -dc 0-9)" -lt 85 ]'
titre "2. Services Wazuh"
for s in wazuh-indexer wazuh-manager wazuh-dashboard filebeat; do t "Service $s actif" "systemctl is-active $s"; done
for p in 443 1514 1515 9200 55000; do t "Port $p en ecoute" "ss -ltn | grep -q \":$p \""; done
t "Regle locale 100200 (acces Squid)" 'grep -q "id=\"100200\"" /var/ossec/etc/rules/local_rules.xml'
t "Regles locales IDS 100210 et 100211" 'grep -q "id=\"100210\"" /var/ossec/etc/rules/local_rules.xml && grep -q "id=\"100211\"" /var/ossec/etc/rules/local_rules.xml' "Relancer l'option 2 de projet.ps1"
titre "3. Agents"
A=$(/var/ossec/bin/agent_control -l 2>/dev/null)
for n in SRV-AD01 PC-CLT01 SRV-PROXY01 fw01; do t "Agent $n actif" "echo \"\$A\" | grep -i \"Name: $n\" | grep -q Active"; done
titre "4. Evenements recus"
J=/var/ossec/logs/alerts/alerts.json
t "Alertes Squid recues" "grep -q '\"squid\"' $J"
t "Refus Squid de p.durand dans Wazuh" "grep '\"squid\"' $J | grep -q 'p.durand'" "Naviguer en session p.durand sur PC-CLT01, attendre 2 minutes, relancer"
t "Evenements Windows de PC-CLT01" "grep -q '\"name\":\"PC-CLT01\"' $J"
t "Evenements du pare-feu FW01" "grep -qi '\"name\":\"fw01' $J"
t "Alertes IDS Suricata de FW01" "grep -q '\"suricata\"' $J" "Cocher Intrusion detection events dans l'agent de FW01, option 4 de projet.ps1"
t "Scan nmap detecte (regle 100210)" "grep -q '\"id\":\"100210\"' $J" "Option 4 de projet.ps1"
info "Alertes Squid du jour : $(grep -c '"squid"' $J 2>/dev/null)"
info "Alertes Suricata du jour : $(grep -c '"suricata"' $J 2>/dev/null)"
bilan
}

# ======================================================================== AIGUILLAGE
HOTE="$(hostname -s)"
case "$MODE:$HOTE" in
  config:srv-proxy01) set -euo pipefail; config_proxy; config_webmin ;;
  config:srv-wazuh01) set -euo pipefail; config_wazuh ;;
  test:srv-proxy01)   set -uo pipefail; test_proxy ;;
  test:srv-wazuh01)   set -uo pipefail; test_wazuh ;;
  scan:*)             set -uo pipefail; demo_scan ;;
  *) echo "[!!] Mode '$MODE' ou machine '$HOTE' inconnu (machines : srv-proxy01, srv-wazuh01 ; modes : config, test, scan)"; exit 1 ;;
esac
