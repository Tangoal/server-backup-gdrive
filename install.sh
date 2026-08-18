#!/usr/bin/env bash
# Installe (ou réinstalle) le service et le timer de sauvegarde sur CETTE machine.
#
# Le dépôt peut être partagé entre plusieurs serveurs : l'unité systemd ne peut
# donc pas être versionnée avec un chemin ou un utilisateur en dur (le chemin
# d'installation et l'utilisateur du service peuvent différer d'une machine à
# l'autre — ex. root sur un serveur qui doit lire des configs système, un
# utilisateur sans sudo sans mot de passe sur un autre). Générée ici à partir
# du chemin réel du script et de l'utilisateur passé en argument — jamais
# commitée, jamais dans le dépôt.
#
# Usage : sudo ./install.sh <utilisateur-du-service>
#   sudo ./install.sh root      # ex: serveur nécessitant un accès root
#   sudo ./install.sh ubuntu    # ex: serveur cloud standard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="/etc/systemd/system"
NAME="server-backup-gdrive"

if [ "$(id -u)" != "0" ]; then
  echo "ERREUR: à lancer avec sudo (l'unité s'installe dans $UNIT_DIR)." >&2
  exit 1
fi

SERVICE_USER="${1:-}"
if [ -z "$SERVICE_USER" ]; then
  echo "ERREUR: utilisateur du service manquant." >&2
  echo "Usage: sudo ./install.sh <utilisateur>   (ex: root, ubuntu)" >&2
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "ERREUR: $SCRIPT_DIR/.env absent." >&2
  echo "Copier .env.example en .env, le remplir, puis relancer." >&2
  exit 1
fi

chmod +x "$SCRIPT_DIR/backup.sh"

cat > "$UNIT_DIR/$NAME.service" <<EOF
[Unit]
Description=Sauvegarde quotidienne du serveur vers Google Drive
Wants=network-online.target
After=network-online.target docker.service
# À décommenter uniquement sur un serveur qui a l'unité correspondante (elle
# redémarre la machine si un paquet l'exige, une fois la sauvegarde passée) :
#OnSuccess=reboot-if-needed.service

[Service]
Type=oneshot
# Généré par install.sh — ne pas éditer à la main, toute modification est
# perdue à la prochaine installation.
User=$SERVICE_USER
ExecStart=$SCRIPT_DIR/backup.sh
TimeoutStartSec=4h
EOF

cat > "$UNIT_DIR/$NAME.timer" <<'EOF'
[Unit]
Description=Lance server-backup-gdrive.service tous les jours à 0h00 UTC

[Timer]
OnCalendar=*-*-* 00:00:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "$NAME.timer"

echo "Installé depuis $SCRIPT_DIR — utilisateur du service : $SERVICE_USER"
systemctl list-timers "$NAME.timer" --no-pager
echo
echo "Run immédiat (facultatif) : sudo systemctl start $NAME.service"
