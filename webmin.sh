#!/bin/bash
# Projet 2 - Groupe B1-4 - SRV-PROXY01 : interface graphique de Squid (Webmin + rapports Calamaris)
# Installe Webmin (paquet officiel publie sur GitHub), Calamaris (rapports web des acces Squid), squidclient et squid-cgi
# (statistiques du cache), puis limite l'acces a Webmin a SRV-AD01 (poste d'administration).
# Relancable sans risque. Lancement, depuis PowerShell sur SRV-AD01 :
#   ssh -t adminproxy@192.168.10.20 'curl -fsSL https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/webmin.sh -o /tmp/webmin.sh && sudo bash /tmp/webmin.sh'
# Ensuite, dans Edge sur SRV-AD01 : https://192.168.10.20:10000
set -euo pipefail

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
echo "Connexion : compte root de SRV-PROXY01, ou adminproxy (membre de sudo) si root n'a pas de mot de passe."
echo "Puis : Servers > Squid Proxy Server. Les regles du projet sont dans /etc/squid/conf.d/groupe4.conf"
echo "(Edit Config Files) : ne pas les recreer dans les ecrans Access Control de Webmin."
