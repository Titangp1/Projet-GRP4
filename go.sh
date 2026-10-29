#!/bin/bash
# Projet 2 - Groupe B1-4 - lanceur Linux
# Reconnait la machine par son nom, telecharge son script depuis GitHub et l'execute.
# Commande unique :
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main/go.sh)"
set -euo pipefail
DEPOT=https://raw.githubusercontent.com/Titangp1/Projet-GRP4/main

[ "$EUID" -eq 0 ] || { echo "[!!] Lancez la commande avec sudo"; exit 1; }

case "$(hostname -s)" in
  srv-proxy01) SCRIPT=srv-proxy01.sh ;;
  srv-wazuh01) SCRIPT=srv-wazuh01.sh ;;
  *) echo "[!!] Machine $(hostname -s) inconnue (attendu srv-proxy01 ou srv-wazuh01)"; exit 1 ;;
esac

echo "Telechargement de $SCRIPT pour $(hostname -s)..."
curl -fsSL "$DEPOT/$SCRIPT" -o "/tmp/$SCRIPT"
bash "/tmp/$SCRIPT"
