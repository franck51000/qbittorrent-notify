#!/bin/bash
# telegram.sh "%I"
# qBittorrent -> Telegram (affiche IMDb via OMDb + infos WebAPI)
# Lance automatiquement par pushbullet.sh, ou utilisable seul.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/pushbullet.conf" ] && . "$SCRIPT_DIR/pushbullet.conf"

QB_URL="${QB_URL:-http://127.0.0.1:8080}"
QB_USER="${QB_USER:-}"
QB_PASS="${QB_PASS:-}"
TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
OMDB_KEY="${OMDB_KEY:-}"

LOG_FILE="$SCRIPT_DIR/telegram.log"
TIMEOUT=20
HASH="$(echo -n "${1:-}" | tr -d '\r\n\t ')"

log() { echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }

command -v curl >/dev/null || { log "curl manquant"; exit 1; }
command -v jq   >/dev/null || { log "jq manquant"; exit 1; }
if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then log "TG_TOKEN/TG_CHAT_ID vide"; exit 1; fi
[ -z "$HASH" ] && { log "hash vide"; exit 1; }

hsize() { local b="${1:-0}"; [ "$b" = "null" ] && b=0; numfmt --to=iec --suffix=B "$b" 2>/dev/null || echo "${b} B"; }
fdate() { if [ "${1:-0}" -gt 0 ] 2>/dev/null; then date -d "@$1" '+%d/%m/%Y %H:%M'; else echo "N/A"; fi; }
esc()   { echo -n "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# WebAPI qBittorrent
COOKIE="$(mktemp /tmp/qb_cookie.XXXXXX)"
LOGIN="$(curl --noproxy '*' -sS -m "$TIMEOUT" -c "$COOKIE" \
  --data-urlencode "username=$QB_USER" --data-urlencode "password=$QB_PASS" \
  "$QB_URL/api/v2/auth/login" 2>/dev/null || true)"
if [ "$LOGIN" != "Ok." ]; then log "login qB echoue: '$LOGIN'"; rm -f "$COOKIE"; exit 1; fi

PROPS="$(curl --noproxy '*' -sS -m "$TIMEOUT" -b "$COOKIE" "$QB_URL/api/v2/torrents/properties?hash=$HASH" 2>/dev/null)"
INFO="$(curl --noproxy '*' -sS -m "$TIMEOUT" -b "$COOKIE" "$QB_URL/api/v2/torrents/info?hashes=$HASH" 2>/dev/null | jq -c '.[0] // {}' 2>/dev/null)"
FILES="$(curl --noproxy '*' -sS -m "$TIMEOUT" -b "$COOKIE" "$QB_URL/api/v2/torrents/files?hash=$HASH" 2>/dev/null | jq 'length' 2>/dev/null)"
rm -f "$COOKIE"

echo "$PROPS" | jq -e . >/dev/null 2>&1 || PROPS="{}"
echo "$INFO"  | jq -e . >/dev/null 2>&1 || INFO="{}"
[ -z "$FILES" ] && FILES="N/A"

p() { echo "$PROPS" | jq -r "$1"; }
i() { echo "$INFO"  | jq -r "$1"; }

NAME="$(i '.name // "N/A"')"
CATEGORY="$(i '.category // ""')"
STATE="$(i '.state // "N/A"')"
TOTAL_SIZE="$(p '.total_size // 0')"
SAVE_PATH="$(p '.save_path // ""')"
TRACKER_DOMAIN="$(i '.tracker // ""' | sed -E 's#^https?://([^/]+).*#\1#')"
ADDED="$(fdate "$(p '.addition_date // 0')")"
DONE="$(fdate "$(p '.completion_date // 0')")"
DL_AVG="$(hsize "$(p '.dl_speed_avg // 0')")/s"

# Titre / annee / type depuis le nom
if echo "$NAME" | grep -qiE '[. ]S[0-9]{1,2}(E[0-9]{1,3})?[. ]'; then
  TYPE="series"
  EPISODE="$(echo "$NAME" | grep -oiE 'S[0-9]{1,2}(E[0-9]{1,3})?' | head -1 | tr a-z A-Z)"
  TITLE_RAW="$(echo "$NAME" | sed -E 's/[. ]S[0-9]{1,2}(E[0-9]{1,3})?[. ].*//I')"
else
  TYPE="movie"
  EPISODE=""
  TITLE_RAW="$(echo "$NAME" | sed -E 's/[. ]((19|20)[0-9]{2})[. ].*//')"
fi
YEAR="$(echo "$NAME" | grep -oE '(19|20)[0-9]{2}' | head -1)"
SEARCH_TITLE="$(echo "$TITLE_RAW" | tr '._' '  ')"

# OMDb (IMDb)
POSTER=""; IMDB_ID=""; IMDB_RATING=""; GENRE=""; TITLE_OK="$SEARCH_TITLE"
if [ -n "$OMDB_KEY" ]; then
  OMDB_ARGS=(-G "https://www.omdbapi.com/"
    --data-urlencode "apikey=$OMDB_KEY"
    --data-urlencode "t=$SEARCH_TITLE"
    --data-urlencode "type=$TYPE")
  if [ "$TYPE" = "movie" ] && [ -n "$YEAR" ]; then
    OMDB_ARGS+=(--data-urlencode "y=$YEAR")
  fi
  OMDB="$(curl -sS -m "$TIMEOUT" "${OMDB_ARGS[@]}" 2>/dev/null)"
  if [ "$(echo "$OMDB" | jq -r '.Response // "False"' 2>/dev/null)" = "True" ]; then
    POSTER="$(echo "$OMDB" | jq -r '.Poster // ""')"; [ "$POSTER" = "N/A" ] && POSTER=""
    IMDB_ID="$(echo "$OMDB" | jq -r '.imdbID // ""')"
    IMDB_RATING="$(echo "$OMDB" | jq -r '.imdbRating // ""')"
    GENRE="$(echo "$OMDB" | jq -r '.Genre // ""')"
    TITLE_OK="$(echo "$OMDB" | jq -r '.Title // ""')"
  else
    log "OMDb: aucun resultat pour '$SEARCH_TITLE' ($TYPE $YEAR)"
  fi
fi

# Message (legende Telegram limitee a 1024 caracteres)
CAPTION="🎬 <b>$(esc "$TITLE_OK")</b> ${EPISODE:+($EPISODE)}
"
[ -n "$IMDB_RATING" ] && [ "$IMDB_RATING" != "N/A" ] && CAPTION+="⭐ IMDb : ${IMDB_RATING}/10
"
[ -n "$GENRE" ] && CAPTION+="🎭 $(esc "$GENRE")
"
CAPTION+="
📦 <code>$(esc "$NAME")</code>
✅ État : $(esc "$STATE")
🏷 Catégorie : $(esc "${CATEGORY:-aucune}")
💾 Taille : $(hsize "$TOTAL_SIZE") | 📄 Fichiers : $FILES
⚡ Vitesse moy : $DL_AVG
🌐 Tracker : $(esc "${TRACKER_DOMAIN:-N/A}")
📁 $(esc "$SAVE_PATH")
🕒 Ajouté : $ADDED
🏁 Terminé : $DONE"
[ -n "$IMDB_ID" ] && CAPTION+="
🔗 <a href=\"https://www.imdb.com/title/$IMDB_ID/\">Fiche IMDb</a>"

CAPTION="$(echo "$CAPTION" | cut -c1-1000)"

API="https://api.telegram.org/bot${TG_TOKEN}"
TMP="$(mktemp /tmp/tg_resp.XXXXXX)"

send_photo() {
  curl -sS -m "$TIMEOUT" -o "$TMP" -w "%{http_code}" "$API/sendPhoto" \
    --data-urlencode "chat_id=$TG_CHAT_ID" \
    --data-urlencode "photo=$POSTER" \
    --data-urlencode "caption=$CAPTION" \
    --data-urlencode "parse_mode=HTML" 2>/dev/null || echo 000
}
send_text() {
  curl -sS -m "$TIMEOUT" -o "$TMP" -w "%{http_code}" "$API/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT_ID" \
    --data-urlencode "text=$CAPTION" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true" 2>/dev/null || echo 000
}

CODE="000"
[ -n "$POSTER" ] && CODE="$(send_photo)"
if [ "$CODE" != "200" ]; then
  [ -n "$POSTER" ] && log "sendPhoto echoue HTTP=$CODE $(tr '\n' ' ' < "$TMP") -> repli texte"
  CODE="$(send_text)"
fi

if [ "$CODE" = "200" ]; then
  HAS_POSTER="non"; [ -n "$POSTER" ] && HAS_POSTER="oui"
  log "OK Telegram: $NAME | poster=$HAS_POSTER | imdb=$IMDB_ID"
  rm -f "$TMP"; exit 0
fi

log "ECHEC Telegram HTTP=$CODE $(tr '\n' ' ' < "$TMP")"
rm -f "$TMP"; exit 1
