#!/bin/bash
# Projet 2 - Groupe B1-4 - SRV-PROXY01 (Debian 13, 192.168.10.20)
# Fait automatiquement, sans rien casser si on le relance :
#   1. Heure et DNS sur l'AD
#   2. Paquets : squid-openssl, Kerberos, msktutil, LDAP
#   3. Agent Wazuh + suivi du journal Squid
#   4. Autorite de certification du proxy + base SSL-Bump
#   5. Kerberos : krb5.conf, compte SRV-PROXY01-K et keytab
#   6. Mot de passe de lecture de l'annuaire (svc-squid) + test du groupe
#   7. Configuration finale de Squid (HTTPS inspecte + authentification AD)
# Aucun mot de passe n'est ecrit dans ce script : ils sont demandes a l'execution.
# Prerequis : srv-ad01.ps1 lance une premiere fois (heure, DNS, compte svc-squid).
# Lancement : sudo bash srv-proxy01.sh
set -euo pipefail

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
[ "$R1" = "OK" ] || alerte "j.martin refuse : verifiez le mot de passe dans /etc/squid/ldap.pass (supprimez le fichier et relancez)"

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
echo -e "\nTermine. Relancez maintenant srv-ad01.ps1 sur l'AD (GPO du certificat), puis pc-clt01.ps1."
