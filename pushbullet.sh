#!/bin/bash
# pushbullet.sh
# qBittorrent -> Pushbullet via WebAPI, puis lance aussi telegram.sh
# Commande qBittorrent (fin de telechargement) :
# /chemin/vers/pushbullet.sh "%I"

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/pushbullet.conf"
[ -f "$CONF" ] && . "$CONF"

API_TOKEN="${API_TOKEN:-}"
QB_URL="${QB_URL:-http://127.0.0.1:8080}"
QB_USER="${QB_USER:-}"
QB_PASS="${QB_PASS:-}"

API_URL="https://api.pushbullet.com/v2/pushes"
LOG_FILE="$SCRIPT_DIR/pushbullet.log"
TG_SCRIPT="$SCRIPT_DIR/telegram.sh"
TG_LOG="$SCRIPT_DIR/telegram.log"
RETRY=3
TIMEOUT=20

HASH="$(echo -n "${1:-}" | tr -d '\r\n\t ')"

log() { echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }

# Lancement Telegram en arriere-plan (si present)
TG_PID=""
if [ -n "$HASH" ]; then
  if [ -x "$TG_SCRIPT" ]; then
    "$TG_SCRIPT" "$HASH" >> "$TG_LOG" 2>&1 &
    TG_PID=$!
  else
    log "telegram.sh introuvable ou non executable: $TG_SCRIPT"
  fi
fi

finish() {
  local code="${1:-0}"
  [ -n "$TG_PID" ] && wait "$TG_PID" 2>/dev/null
  exit "$code"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { log "ERREUR binaire manquant: $1"; finish 1; }
}

hsize() {
  local b="${1:-0}"
  [ "$b" = "null" ] && b=0
  numfmt --to=iec --suffix=B "$b" 2>/dev/null || echo "${b} B"
}

fdate() {
  local ts="${1:-0}"
  if [ "$ts" -gt 0 ] 2>/dev/null; then date -d "@$ts" '+%d/%m/%Y %H:%M:%S'; else echo "N/A"; fi
}

fdur() {
  local s="${1:-0}"
  printf '%dj %dh %dm' $((s/86400)) $((s%86400/3600)) $((s%3600/60))
}

require_bin curl
require_bin jq

[ -z "$API_TOKEN" ] && { log "ERREUR: API_TOKEN vide (pushbullet.conf)"; finish 1; }
[ -z "$HASH" ] && { log "ERREUR: hash vide (argument %I manquant)"; finish 1; }

# Login WebAPI qBittorrent
COOKIE="$(mktemp /tmp/qb_cookie.XXXXXX)"
LOGIN_RESP="$(curl --noproxy '*' -sS -m "$TIMEOUT" -c "$COOKIE" \
  --data-urlencode "username=$QB_USER" \
  --data-urlencode "password=$QB_PASS" \
  "$QB_URL/api/v2/auth/login" 2>/dev/null || true)"

if [ "$LOGIN_RESP" != "Ok." ]; then
  log "ERREUR login qBittorrent: '$LOGIN_RESP'"
  rm -f "$COOKIE"
  finish 1
fi

PROPS="$(curl --noproxy '*' -sS -m "$TIMEOUT" -b "$COOKIE" \
  "$QB_URL/api/v2/torrents/properties?hash=$HASH" 2>/dev/null || echo "{}")"

INFO="$(curl --noproxy '*' -sS -m "$TIMEOUT" -b "$COOKIE" \
  "$QB_URL/api/v2/torrents/info?hashes=$HASH" 2>/dev/null | jq -c '.[0] // {}' 2>/dev/null || echo "{}")"

FILES="$(curl --noproxy '*' -sS -m "$TIMEOUT" -b "$COOKIE" \
  "$QB_URL/api/v2/torrents/files?hash=$HASH" 2>/dev/null | jq 'length' 2>/dev/null || echo "N/A")"

rm -f "$COOKIE"

echo "$PROPS" | jq -e . >/dev/null 2>&1 || PROPS="{}"
echo "$INFO"  | jq -e . >/dev/null 2>&1 || INFO="{}"
[ -z "$FILES" ] && FILES="N/A"

p() { echo "$PROPS" | jq -r "$1"; }
i() { echo "$INFO"  | jq -r "$1"; }

NAME="$(i '.name // "N/A"')"
STATE="$(i '.state // "N/A"')"
CATEGORY="$(i '.category // ""')"
TAGS="$(i '.tags // ""')"
TRACKER="$(i '.tracker // ""')"
CONTENT_PATH="$(i '.content_path // ""')"
SAVE_PATH="$(p '.save_path // ""')"

# Ne garder que le domaine du tracker (masque la passkey)
TRACKER="$(echo "$TRACKER" | sed -E 's#^(https?://[^/]+).*#\1#')"

TOTAL_SIZE="$(p '.total_size // 0')"
TE="$(p '.time_elapsed // 0')"
if [ "$TE" -gt 315360000 ] 2>/dev/null; then TIME_ACTIVE="N/A"; else TIME_ACTIVE="$(fdur "$TE")"; fi
SEEDING_TIME="$(fdur "$(p '.seeding_time // 0')")"

ETA_RAW="$(p '.eta // 0')"
if [ "$ETA_RAW" -ge 8640000 ] 2>/dev/null; then ETA="∞"; else ETA="$(fdur "$ETA_RAW")"; fi

DOWNLOADED="$(hsize "$(p '.total_downloaded // 0')")"
UPLOADED="$(hsize "$(p '.total_uploaded // 0')")"

# Ratio calcule (uploade / taille) : plus fiable que share_ratio
RATIO="$(p 'if (.total_size // 0) > 0 then ((.total_uploaded // 0) / .total_size * 100 | round / 100) else 0 end')"

DL_AVG="$(hsize "$(p '.dl_speed_avg // 0')")/s"
UP_AVG="$(hsize "$(p '.up_speed_avg // 0')")/s"

DL_LIMIT="$(p '.dl_limit // -1')"; if [ "$DL_LIMIT" = "-1" ]; then DL_LIMIT="∞"; else DL_LIMIT="$(hsize "$DL_LIMIT")/s"; fi
UP_LIMIT="$(p '.up_limit // -1')"; if [ "$UP_LIMIT" = "-1" ]; then UP_LIMIT="∞"; else UP_LIMIT="$(hsize "$UP_LIMIT")/s"; fi

SEEDS="$(p '.seeds // 0')/$(p '.seeds_total // 0')"
PEERS="$(p '.peers // 0')/$(p '.peers_total // 0')"
CONNS="$(p '.nb_connections // 0')/$(p '.nb_connections_limit // 0')"
REANNOUNCE="$(p '.reannounce // 0')"

WASTED="$(hsize "$(p '.total_wasted // 0')")"
PIECES_HAVE="$(p '.pieces_have // 0')"
PIECES_NUM="$(p '.pieces_num // 0')"
PIECE_SIZE="$(hsize "$(p '.piece_size // 0')")"

ADDED_ON="$(fdate "$(p '.addition_date // 0')")"
COMPLETED_ON="$(fdate "$(p '.completion_date // 0')")"
CREATED_ON="$(fdate "$(p '.creation_date // 0')")"
CREATED_BY="$(p '.created_by // "N/A"')"
COMMENT="$(p '.comment // ""' | cut -c1-120)"

TITLE="qBittorrent : $NAME"
BODY="Nom: $NAME
État: $STATE
Catégorie: ${CATEGORY:-aucune}
Tags: ${TAGS:-aucun}
Taille: $(hsize "$TOTAL_SIZE") | Pièces: ${PIECES_HAVE}/${PIECES_NUM} x ${PIECE_SIZE}
Fichiers: ${FILES}
Time Active: ${TIME_ACTIVE}
Seeding: ${SEEDING_TIME}
ETA: ${ETA}
Téléchargé: ${DOWNLOADED} | Uploadé: ${UPLOADED}
Ratio: ${RATIO}
Vitesse moy: ↓ ${DL_AVG} | ↑ ${UP_AVG}
Limites: ↓ ${DL_LIMIT} | ↑ ${UP_LIMIT}
Seeds: ${SEEDS} | Peers: ${PEERS}
Connexions: ${CONNS}
Reannounce: ${REANNOUNCE}s
Wasted: ${WASTED}
Ajouté: ${ADDED_ON}
Terminé: ${COMPLETED_ON}
Créé le: ${CREATED_ON}
Créé par: ${CREATED_BY}
Commentaire: ${COMMENT:-aucun}
Tracker: ${TRACKER:-N/A}
Dossier: ${SAVE_PATH:-N/A}
Chemin: ${CONTENT_PATH:-N/A}
Torrent Hash: ${HASH}
Date: $(date '+%d/%m/%Y %H:%M:%S')"

JSON="$(jq -n --arg title "$TITLE" --arg body "$BODY" '{type:"note",title:$title,body:$body}')"

TMP_RESP="$(mktemp /tmp/pb_resp.XXXXXX)"
for n in $(seq 1 "$RETRY"); do
  HTTP_CODE="$(curl -sS -o "$TMP_RESP" -w "%{http_code}" \
    --max-time "$TIMEOUT" \
    -H "Access-Token: $API_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST -d "$JSON" "$API_URL" 2>/dev/null || echo "000")"

  if [ "$HTTP_CODE" = "200" ]; then
    log "OK Pushbullet: $NAME | Hash=$HASH | Ratio=$RATIO"
    rm -f "$TMP_RESP"
    finish 0
  fi

  log "ECHEC $n/$RETRY HTTP=$HTTP_CODE resp=$(tr '\n' ' ' < "$TMP_RESP" 2>/dev/null)"
  sleep 2
done

log "ECHEC FINAL Pushbullet: $NAME | Hash=$HASH"
rm -f "$TMP_RESP"
finish 1
