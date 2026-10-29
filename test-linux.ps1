<#
  Projet 2 - Groupe B1-4 - TESTS de SRV-PROXY01 et SRV-WAZUH01, lances depuis SRV-AD01 (lecture seule)
  PowerShell envoie a chaque serveur, par SSH, une liste de verifications qui ne modifient rien.
  Mots de passe demandes : SSH puis sudo (le meme), pour chaque serveur.
    powershell -ExecutionPolicy Bypass -File .\test-linux.ps1
#>

$communs = @'
ok=0; ko=0
t() { if eval "$2" >/dev/null 2>&1; then echo -e "\e[32m[OK]\e[0m    $1"; ok=$((ok+1)); else echo -e "\e[31m[ECHEC]\e[0m $1"; [ -n "$3" ] && echo "        -> $3"; ko=$((ko+1)); fi; }
titre() { echo -e "\n\e[36m=== $* ===\e[0m"; }
info() { echo -e "\e[33m[INFO]\e[0m  $*"; }
port() { timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
bilan() { titre "Bilan $(hostname)"; echo "$ok tests reussis, $ko en echec"; }
'@

$proxy = @'
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
t "Journal : acces autorises de j.martin" 'grep -q "j.martin@GROUPE4.INTERNAL" /var/log/squid/access.log'
t "Journal : refus 403 de p.durand" 'grep "p.durand@GROUPE4.INTERNAL" /var/log/squid/access.log | grep -q "/403 "' "Naviguer en session p.durand sur PC-CLT01"
t "Journal : pages HTTPS completes (GET https://)" 'grep -q " GET https://" /var/log/squid/access.log'
titre "5. Agent Wazuh"
t "Service wazuh-agent actif" 'systemctl is-active wazuh-agent'
t "Agent connecte au serveur" 'grep -q "status=.connected." /var/ossec/var/run/wazuh-agentd.state'
t "Serveur = 192.168.10.30" 'grep -q "<address>192.168.10.30</address>" /var/ossec/etc/ossec.conf'
t "Journal Squid suivi par l'agent" 'grep -q "/var/log/squid/access.log" /var/ossec/etc/ossec.conf'
titre "6. Interface graphique (Webmin) et outil de scan"
t "Service webmin actif" 'systemctl is-active webmin' "Lancer webmin.sh (guide etape 15)"
t "Webmin ecoute sur 10000" 'ss -ltn | grep -q ":10000 "'
t "Webmin reserve a SRV-AD01 (allow)" 'grep -q "^allow=.*192.168.10.10" /etc/webmin/miniserv.conf'
t "Calamaris installe (rapports Squid)" 'command -v calamaris'
t "nmap installe (demonstration IDS)" 'command -v nmap' "Lancer scan-demo.sh (guide etape 14)"
bilan
'@

$wazuh = @'
titre "1. Machine et heure"
t "Nom srv-wazuh01" '[ "$(hostname -s)" = srv-wazuh01 ]'
t "Adresse 192.168.10.30/24" 'ip -4 addr | grep -q "192.168.10.30/24"'
t "Heure synchronisee" 'timedatectl show -p NTPSynchronized --value | grep -q yes'
t "Espace disque utilise < 85 %" '[ "$(df --output=pcent / | tail -1 | tr -dc 0-9)" -lt 85 ]'
titre "2. Services Wazuh"
for s in wazuh-indexer wazuh-manager wazuh-dashboard filebeat; do t "Service $s actif" "systemctl is-active $s"; done
for p in 443 1514 1515 9200 55000; do t "Port $p en ecoute" "ss -ltn | grep -q \":$p \""; done
t "Regle locale 100200 (acces Squid)" 'grep -q "id=\"100200\"" /var/ossec/etc/rules/local_rules.xml'
t "Regles locales IDS 100210 et 100211" 'grep -q "id=\"100210\"" /var/ossec/etc/rules/local_rules.xml && grep -q "id=\"100211\"" /var/ossec/etc/rules/local_rules.xml' "Relancer go.sh sur SRV-WAZUH01"
titre "3. Agents"
A=$(/var/ossec/bin/agent_control -l 2>/dev/null)
for n in SRV-AD01 PC-CLT01 SRV-PROXY01 fw01; do t "Agent $n actif" "echo \"\$A\" | grep -i \"Name: $n\" | grep -q Active"; done
titre "4. Evenements recus"
J=/var/ossec/logs/alerts/alerts.json
t "Alertes Squid recues" "grep -q '\"squid\"' $J"
t "Refus Squid de p.durand dans Wazuh" "grep '\"squid\"' $J | grep -q 'p.durand'" "Naviguer en session p.durand, attendre une minute"
t "Evenements Windows de PC-CLT01" "grep -q '\"name\":\"PC-CLT01\"' $J"
t "Evenements du pare-feu FW01" "grep -qi '\"name\":\"fw01' $J"
t "Alertes IDS Suricata de FW01" "grep -q '\"suricata\"' $J" "Cocher Intrusion detection events dans l'agent de FW01, lancer scan-demo.sh"
t "Scan nmap detecte (regle 100210)" "grep -q '\"id\":\"100210\"' $J" "Lancer scan-demo.sh sur SRV-PROXY01"
info "Alertes Squid du jour : $(grep -c '"squid"' $J 2>/dev/null)"
info "Alertes Suricata du jour : $(grep -c '"suricata"' $J 2>/dev/null)"
bilan
'@

function Lancer($nom, $cible, $corps) {
    Write-Host "`n##### $nom ($cible) - mots de passe : SSH puis sudo #####" -ForegroundColor Cyan
    $txt = ($communs + "`n" + $corps) -replace "`r", ""
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($txt))
    ssh -t -o StrictHostKeyChecking=accept-new $cible "echo $b64 | base64 -d > /tmp/recette-g4.sh && sudo bash /tmp/recette-g4.sh; rm -f /tmp/recette-g4.sh"
}

$rapport = Join-Path ([Environment]::GetFolderPath("Desktop")) ("recette-LINUX-{0:yyyyMMdd-HHmm}.txt" -f (Get-Date))
Start-Transcript -Path $rapport | Out-Null
Lancer "SRV-PROXY01" "adminproxy@192.168.10.20" $proxy
Lancer "SRV-WAZUH01" "adminwazuh@192.168.10.30" $wazuh
Write-Host "`nRapport : $rapport"
Stop-Transcript | Out-Null
