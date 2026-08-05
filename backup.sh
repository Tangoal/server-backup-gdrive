#!/usr/bin/env bash
# Sauvegarde quotidienne portable d'un serveur vers Google Drive (rclone).
#
# Ce script ne connaît AUCUN nom de machine : tout ce qui est spécifique à un
# serveur (remote rclone, chemins, exclusions, destinataire des alertes) vit
# dans le `.env` posé à côté de lui. Le même fichier tourne à l'identique sur
# chaque serveur, avec son propre `.env`. Voir `.env.example` et `CLAUDE.md`.
#
# Ce qu'il produit à chaque exécution, dans un dossier de staging temporaire :
#   databases/<conteneur>.sql.gz  — pg_dump de chaque conteneur Postgres détecté
#   volumes/<volume>.tar.gz       — un tar par volume Docker nommé détecté
#   workspace/<nom>.tar.gz        — le dossier de travail, hors motifs exclus
#   configs/<nom>.tar.gz          — une archive par chemin de config critique
# puis pousse le tout vers le Drive en GFS (daily/weekly/monthly datés, avec
# rétention par palier), plus une synchro incrémentale séparée du dossier de
# travail. Le staging est effacé en fin de run.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${BACKUP_ENV_FILE:-$SCRIPT_DIR/.env}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------------------
# Erreurs : chaque étape ratée est enregistrée puis le run continue (une base
# injoignable ne doit pas priver de sauvegarde tout le reste du serveur). Le
# bilan part par mail en fin de run et fixe le code de sortie.
# ---------------------------------------------------------------------------
ERRORS=()
step_failed() {
  ERRORS+=("$1")
  log "ECHEC: $1"
}

# Toute commande qui échoue hors des chemins gérés explicitement ci-dessous
# (donc un vrai bug ou un imprévu) coupe le run et alerte immédiatement.
on_unexpected_error() {
  local line="$1"
  ERRORS+=("erreur inattendue ligne $line")
  log "ECHEC: erreur inattendue ligne $line"
  send_report
  exit 1
}
trap 'on_unexpected_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "ERREUR: fichier de configuration introuvable : $ENV_FILE" >&2
  echo "Copier .env.example en .env et le remplir." >&2
  exit 1
fi

: "${RCLONE_REMOTE:?RCLONE_REMOTE doit être défini dans $ENV_FILE}"

RCLONE_CONFIG="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"
STAGING_ROOT="${BACKUP_STAGING_DIR:-/var/tmp/server-backup-gdrive}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/workspace}"
BACKUP_EXCLUDE_PATTERNS="${BACKUP_EXCLUDE_PATTERNS:-.git,node_modules}"
BACKUP_EXCLUDE_VOLUMES="${BACKUP_EXCLUDE_VOLUMES:-}"
BACKUP_CONFIG_PATHS="${BACKUP_CONFIG_PATHS:-}"
RETENTION_DAILY="${RETENTION_DAILY:-14}"
RETENTION_WEEKLY="${RETENTION_WEEKLY:-8}"
RETENTION_MONTHLY="${RETENTION_MONTHLY:-12}"
BACKUP_LABEL="${BACKUP_LABEL:-$(hostname -s)}"
# Préfixe d'objet des mails. Par défaut : [Nom-de-machine] [Backup].
BACKUP_SUBJECT_PREFIX="${BACKUP_SUBJECT_PREFIX:-[${BACKUP_LABEL^}] [Backup]}"
# 1 = un mail à chaque run, succès compris. 0 = uniquement en cas d'échec.
BACKUP_MAIL_ON_SUCCESS="${BACKUP_MAIL_ON_SUCCESS:-1}"
RESEND_API_KEY="${RESEND_API_KEY:-}"
ALERT_EMAIL_TO="${ALERT_EMAIL_TO:-}"
ALERT_EMAIL_FROM="${ALERT_EMAIL_FROM:-onboarding@resend.dev}"

DATE="$(date -u +%Y-%m-%d)"
STAGING="$STAGING_ROOT/$DATE"
RCLONE=(rclone --config "$RCLONE_CONFIG" --stats=0)

# ---------------------------------------------------------------------------
# Compte rendu Resend — un mail à chaque run, succès compris (aligné sur
# gdrive-nas-mirror) : le mail de succès sert de preuve de vie, c'est son
# absence qui doit alerter. Sans clé API, on se contente de le dire dans le
# journal (le run reste en échec si ERRORS n'est pas vide, visible via
# `systemctl status`).
# ---------------------------------------------------------------------------
send_report() {
  local body subject
  if [ ${#ERRORS[@]} -gt 0 ]; then
    subject="$BACKUP_SUBJECT_PREFIX ÉCHEC (${#ERRORS[@]}) — $DATE"
  else
    if [ "$BACKUP_MAIL_ON_SUCCESS" != "1" ]; then
      return 0
    fi
    subject="$BACKUP_SUBJECT_PREFIX OK — $DATE"
  fi

  body="Sauvegarde $BACKUP_LABEL du $DATE"
  if [ ${#ERRORS[@]} -gt 0 ]; then
    body+=" : ${#ERRORS[@]} étape(s) en échec.\n\n"
    local e
    for e in "${ERRORS[@]}"; do body+="  - $e\n"; done
  else
    body+=" : aucune erreur.\n"
  fi
  body+="\nRemote : $RCLONE_REMOTE\nJournal : journalctl -u server-backup-gdrive.service -n 100\n"

  if [ -z "$RESEND_API_KEY" ] || [ -z "$ALERT_EMAIL_TO" ]; then
    log "ALERTE non envoyée (RESEND_API_KEY ou ALERT_EMAIL_TO absent de $ENV_FILE)"
    return 0
  fi

  log "envoi de l'alerte Resend -> $ALERT_EMAIL_TO"
  local payload http
  payload="$(printf '{"from":"%s","to":["%s"],"subject":"%s","text":"%s"}' \
    "$ALERT_EMAIL_FROM" "$ALERT_EMAIL_TO" "$subject" "$body")"
  http="$(curl -sS -o /tmp/resend-response.$$ -w '%{http_code}' \
    -X POST https://api.resend.com/emails \
    -H "Authorization: Bearer $RESEND_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1)" || http="000"
  if [ "$http" = "200" ]; then
    log "alerte Resend envoyée (HTTP 200)"
  else
    log "ATTENTION: alerte Resend en échec (HTTP $http) : $(cat /tmp/resend-response.$$ 2>/dev/null)"
  fi
  rm -f "/tmp/resend-response.$$"
}

# ---------------------------------------------------------------------------
# Outils
# ---------------------------------------------------------------------------

# Le code de retour de `tar` est VOLONTAIREMENT ignoré partout dans ce script :
# il vaut 1 ou 2 dès qu'un fichier a changé pendant la lecture ou a été sauté
# (base vivante, dossier appartenant à root), alors que l'archive produite est
# parfaitement valide. S'y fier faisait jeter l'archive à chaque passage.
# Le seul juge de la validité d'une archive est `gzip -t`, ci-dessous.
# Écriture en .part, validation, puis renommage : jamais d'archive tronquée en
# place sous un nom définitif.
check_gz() {
  local part="$1" final="$2" what="$3"
  if [ -s "$part" ] && gzip -t "$part" 2>/dev/null; then
    mv "$part" "$final"
    log "  gzip -t OK  $(basename "$final") ($(du -h "$final" | cut -f1))"
    return 0
  fi
  rm -f "$part"
  step_failed "$what (archive invalide ou vide)"
  return 1
}

# Transforme une liste séparée par des virgules en tableau (espaces ignorés).
split_csv() {
  local IFS=','
  SPLIT_RESULT=()
  read -ra SPLIT_RESULT <<< "$1" || true
  local i
  for i in "${!SPLIT_RESULT[@]}"; do
    SPLIT_RESULT[$i]="$(echo "${SPLIT_RESULT[$i]}" | xargs)"
  done
}

log "=== sauvegarde $BACKUP_LABEL — $DATE ==="
log "staging : $STAGING · remote : $RCLONE_REMOTE"
rm -rf "$STAGING"
mkdir -p "$STAGING"/{databases,volumes,workspace,configs}

HAS_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  HAS_DOCKER=1
else
  log "docker indisponible — étapes bases et volumes sautées"
fi

# ---------------------------------------------------------------------------
# 1. Bases Postgres — auto-découverte
# ---------------------------------------------------------------------------
# Est considéré comme une base Postgres tout conteneur en cours d'exécution
# dont l'environnement porte POSTGRES_DB (ce que posent toutes les images
# officielles postgres et leurs dérivées type pgvector/timescale). Les
# identifiants sont lus dans l'environnement du conteneur au moment du dump —
# jamais stockés en clair ici ni dans le .env.
if [ "$HAS_DOCKER" = "1" ]; then
  log "--- bases Postgres ---"
  found_db=0
  while read -r container; do
    if [ -z "$container" ]; then continue; fi
    if ! docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null \
        | grep -q '^POSTGRES_DB='; then
      continue
    fi
    found_db=1
    log "pg_dump $container"
    if docker exec "$container" sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' 2>/dev/null \
        | gzip > "$STAGING/databases/$container.sql.gz.part"; then
      check_gz "$STAGING/databases/$container.sql.gz.part" \
               "$STAGING/databases/$container.sql.gz" "pg_dump $container" || true
    else
      rm -f "$STAGING/databases/$container.sql.gz.part"
      step_failed "pg_dump $container (commande en échec)"
    fi
  done < <(docker ps --format '{{.Names}}')
  if [ "$found_db" = "0" ]; then log "aucun conteneur Postgres détecté"; fi
fi

# ---------------------------------------------------------------------------
# 2. Volumes Docker nommés — auto-découverte
# ---------------------------------------------------------------------------
# Tous les volumes nommés sont pris, sauf ceux listés dans
# BACKUP_EXCLUDE_VOLUMES (motifs glob acceptés). Les volumes anonymes (nom =
# 64 caractères hexadécimaux, créés à la volée par Docker) sont ignorés : ils
# ne survivent pas à un `docker compose down -v` et ne portent rien de durable.
# Le tar passe par un conteneur alpine, ce qui évite d'avoir besoin de root
# pour lire /var/lib/docker/volumes.
if [ "$HAS_DOCKER" = "1" ]; then
  log "--- volumes Docker ---"
  split_csv "$BACKUP_EXCLUDE_VOLUMES"
  EXCLUDED_VOLUMES=("${SPLIT_RESULT[@]}")
  while read -r vol; do
    if [ -z "$vol" ]; then continue; fi
    if [[ "$vol" =~ ^[0-9a-f]{64}$ ]]; then
      continue
    fi
    skip=0
    for pattern in "${EXCLUDED_VOLUMES[@]}"; do
      if [ -z "$pattern" ]; then continue; fi
      # shellcheck disable=SC2053
      if [[ "$vol" == $pattern ]]; then skip=1; break; fi
    done
    if [ "$skip" = "1" ]; then
      log "SKIP volume $vol (BACKUP_EXCLUDE_VOLUMES)"
      continue
    fi
    log "tar volume $vol"
    docker run --rm -v "$vol":/data:ro alpine \
      tar czf - -C /data . 2>/dev/null > "$STAGING/volumes/$vol.tar.gz.part" || true
    check_gz "$STAGING/volumes/$vol.tar.gz.part" \
             "$STAGING/volumes/$vol.tar.gz" "tar volume $vol" || true
  done < <(docker volume ls --format '{{.Name}}')
fi

# ---------------------------------------------------------------------------
# 3. Dossier de travail (code + docs)
# ---------------------------------------------------------------------------
# ⚠️ GNU tar n'applique `--exclude` qu'aux opérandes qui le SUIVENT : les
# exclusions doivent rester AVANT le nom du dossier, sinon elles sont ignorées
# en silence (piège rencontré deux fois sur l'ancien script, cf. CLAUDE.md).
log "--- dossier de travail ---"
if [ -d "$WORKSPACE_DIR" ]; then
  split_csv "$BACKUP_EXCLUDE_PATTERNS"
  WS_NAME="$(basename "$WORKSPACE_DIR")"
  WS_PARENT="$(dirname "$WORKSPACE_DIR")"
  TAR_EXCLUDES=()
  for pattern in "${SPLIT_RESULT[@]}"; do
    if [ -z "$pattern" ]; then continue; fi
    TAR_EXCLUDES+=("--exclude=$pattern")
  done
  log "tar $WORKSPACE_DIR (exclut : $BACKUP_EXCLUDE_PATTERNS)"
  tar "${TAR_EXCLUDES[@]}" --ignore-failed-read \
    -czf "$STAGING/workspace/$WS_NAME.tar.gz.part" -C "$WS_PARENT" "$WS_NAME" 2>/dev/null || true
  check_gz "$STAGING/workspace/$WS_NAME.tar.gz.part" \
           "$STAGING/workspace/$WS_NAME.tar.gz" "tar $WORKSPACE_DIR" || true
else
  log "SKIP dossier de travail ($WORKSPACE_DIR introuvable)"
fi

# ---------------------------------------------------------------------------
# 4. Configs critiques
# ---------------------------------------------------------------------------
# Une archive par chemin listé dans BACKUP_CONFIG_PATHS. Le nom de l'archive
# est dérivé du chemin (/etc/cloudflared -> etc-cloudflared.tar.gz). Un chemin
# absent est signalé mais ne fait pas échouer le run : la liste est la même
# ambition pour tous les serveurs, tous n'ont pas les mêmes services.
log "--- configs ---"
split_csv "$BACKUP_CONFIG_PATHS"
for path in "${SPLIT_RESULT[@]}"; do
  if [ -z "$path" ]; then continue; fi
  path="${path/#\~/$HOME}"
  if [ ! -e "$path" ]; then
    log "SKIP config $path (absent)"
    continue
  fi
  name="$(echo "${path#/}" | sed 's|^\.||; s|/|-|g; s|^-*||; s|^\.*||')"
  if [ -z "$name" ]; then name="config"; fi
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  log "tar config $path"
  tar --ignore-failed-read -czf "$STAGING/configs/$name.tar.gz.part" \
    -C "$parent" "$base" 2>/dev/null || true
  check_gz "$STAGING/configs/$name.tar.gz.part" \
           "$STAGING/configs/$name.tar.gz" "tar config $path" || true
done

log "staging terminé ($(du -sh "$STAGING" | cut -f1))"

# ---------------------------------------------------------------------------
# 5. Envoi vers Google Drive — GFS daily/weekly/monthly
# ---------------------------------------------------------------------------
# Chaque run écrit un snapshot daté sous daily/. Le dimanche, ce snapshot est
# recopié côté serveur Drive (copie serveur-à-serveur : aucun octet ne remonte
# une deuxième fois) vers weekly/, le 1er du mois vers monthly/. Chaque palier
# garde ensuite ses N snapshots les plus récents, les plus anciens sont purgés.
#
# `workspace/` est le seul dossier du staging EXCLU de ces snapshots : son tar
# pèse plusieurs centaines de Mo, or 14+8+12 = 34 snapshots le multiplieraient
# jusqu'à saturer le quota du Drive à lui tout seul. Il est couvert autrement,
# par la synchro incrémentale de l'étape 6 (un seul exemplaire, à jour). Le tar
# est quand même produit et vérifié à chaque run : c'est lui qui garantit que
# le dossier est archivable, et il reste disponible en local dans le staging
# jusqu'à la purge (2 jours).
if ! "${RCLONE[@]}" listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE%%:*}:$"; then
  step_failed "remote rclone '${RCLONE_REMOTE%%:*}' absent de $RCLONE_CONFIG"
  send_report
  exit 1
fi

# Garde les N sous-dossiers datés les plus récents d'un palier, purge le reste.
prune_tier() {
  local tier="$1" keep="$2" dirs=() victim
  mapfile -t dirs < <("${RCLONE[@]}" lsf --dirs-only "$RCLONE_REMOTE/$tier" 2>/dev/null \
                      | sed 's|/$||' | sort)
  local total=${#dirs[@]}
  [ "$total" -le "$keep" ] && return 0
  for victim in "${dirs[@]:0:$((total - keep))}"; do
    log "purge $tier/$victim (rétention $keep)"
    "${RCLONE[@]}" purge "$RCLONE_REMOTE/$tier/$victim" 2>/dev/null \
      || log "ATTENTION: purge $tier/$victim en échec"
  done
}

log "--- envoi GFS ---"
log "copie -> $RCLONE_REMOTE/daily/$DATE (hors workspace/)"
if "${RCLONE[@]}" copy "$STAGING" "$RCLONE_REMOTE/daily/$DATE" --exclude '/workspace/**'; then
  prune_tier daily "$RETENTION_DAILY"

  # Dimanche -> weekly, 1er du mois -> monthly. Copie serveur-à-serveur.
  TIERS=()
  if [ "$(date -u +%u)" = "7" ]; then TIERS+=("weekly:$RETENTION_WEEKLY"); fi
  if [ "$(date -u +%d)" = "01" ]; then TIERS+=("monthly:$RETENTION_MONTHLY"); fi
  for entry in "${TIERS[@]}"; do
    tier="${entry%%:*}"; keep="${entry##*:}"
    log "copie serveur-à-serveur -> $RCLONE_REMOTE/$tier/$DATE"
    if "${RCLONE[@]}" copy "$RCLONE_REMOTE/daily/$DATE" "$RCLONE_REMOTE/$tier/$DATE"; then
      prune_tier "$tier" "$keep"
    else
      step_failed "copie GFS vers $tier/$DATE"
    fi
  done
else
  step_failed "envoi du snapshot daily/$DATE"
fi

# ---------------------------------------------------------------------------
# 6. Dossier de travail en incrémental, hors GFS
# ---------------------------------------------------------------------------
# Le tar du dossier de travail est dans les snapshots GFS ci-dessus, mais il ne
# donne pas de vue "à jour" pratique à parcourir. Cette synchro-là copie
# l'arborescence réelle vers un seul chemin fixe : rclone ne retransfère que ce
# qui a changé, et la taille sur le Drive reste celle du dossier, quel que soit
# le nombre de jours écoulés (pas de multiplication par le GFS).
if [ -d "$WORKSPACE_DIR" ]; then
  log "--- synchro incrémentale du dossier de travail ---"
  split_csv "$BACKUP_EXCLUDE_PATTERNS"
  RCLONE_EXCLUDES=()
  for pattern in "${SPLIT_RESULT[@]}"; do
    if [ -z "$pattern" ]; then continue; fi
    RCLONE_EXCLUDES+=(--exclude "$pattern/**" --exclude "$pattern")
  done
  log "sync $WORKSPACE_DIR -> $RCLONE_REMOTE/workspace-latest"
  "${RCLONE[@]}" sync "$WORKSPACE_DIR" "$RCLONE_REMOTE/workspace-latest" \
    "${RCLONE_EXCLUDES[@]}" --fast-list \
    || step_failed "sync incrémental de $WORKSPACE_DIR"
fi

# ---------------------------------------------------------------------------
# 7. Nettoyage et bilan
# ---------------------------------------------------------------------------
# Le staging est vidé de ce qui est déjà parti dans le cloud ; seul le tar du
# dossier de travail est conservé (il n'est pas dans les snapshots), puis purgé
# par ancienneté au run suivant.
rm -rf "$STAGING"/{databases,volumes,configs}
find "$STAGING_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +2 -exec rm -rf {} \; 2>/dev/null || true

send_report

if [ ${#ERRORS[@]} -gt 0 ]; then
  log "=== terminé avec ${#ERRORS[@]} échec(s) ==="
  exit 1
fi

log "=== sauvegarde terminée sans erreur ==="
