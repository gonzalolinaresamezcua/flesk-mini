#!/usr/bin/env bash
# Flesk — claves DKIM por dominio (OpenDKIM, selector "default", RSA 2048)
#   flesk dkim ensure <dominio>   crea la clave si falta y la activa; imprime DKIM_TXT=<valor TXT>
#   flesk dkim show <dominio>     imprime DKIM_TXT=<valor TXT>
#   flesk dkim del <dominio>      borra la clave y la quita de las tablas
#   flesk dkim sync               regenera KeyTable/SigningTable desde las claves presentes
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

DKIM_DIR="${DKIM_DIR:-/etc/opendkim}"
DKIM_KEYS="$DKIM_DIR/keys"
SELECTOR="default"

usage() { echo "Uso: flesk dkim ensure|show|del <dominio> | flesk dkim sync" >&2; }

require_root
ACTION="${1:-}"; shift || true

dkim_sync_tables() {
  mkdir -p "$DKIM_KEYS"
  local kt st d f
  kt="$(mktemp)"; st="$(mktemp)"
  for f in "$DKIM_KEYS"/*/"$SELECTOR".private; do
    [[ -f "$f" ]] || continue
    d="$(basename "$(dirname "$f")")"
    valid_domain "$d" >/dev/null || continue
    printf '%s._domainkey.%s %s:%s:%s\n' "$SELECTOR" "$d" "$d" "$SELECTOR" "$f" >> "$kt"
    printf '*@%s %s._domainkey.%s\n' "$d" "$SELECTOR" "$d" >> "$st"
  done
  install -m 644 -o root -g root "$kt" "$DKIM_DIR/KeyTable"
  install -m 644 -o root -g root "$st" "$DKIM_DIR/SigningTable"
  rm -f "$kt" "$st"
  if systemctl is-active --quiet opendkim 2>/dev/null; then
    systemctl reload opendkim 2>/dev/null || systemctl restart opendkim || true
  fi
}

dkim_txt() {
  local f="$DKIM_KEYS/$1/$SELECTOR.txt"
  [[ -f "$f" ]] || return 1
  # Une las cadenas entrecomilladas del registro generado por opendkim-genkey
  awk -F'"' '{for(i=2;i<=NF;i+=2) printf "%s", $i}' "$f"
}

case "$ACTION" in
  ensure)
    [[ $# -ge 1 ]] || { usage; die 2 "Falta dominio"; }
    DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido: $1"
    command -v opendkim-genkey >/dev/null 2>&1 || die 3 "opendkim-tools no está instalado"
    lock "dkim:$DOMAIN"; trap 'unlock' EXIT
    KD="$DKIM_KEYS/$DOMAIN"
    if [[ ! -s "$KD/$SELECTOR.private" ]]; then
      install -d -m 750 -o opendkim -g opendkim "$KD"
      opendkim-genkey -b 2048 -r -s "$SELECTOR" -d "$DOMAIN" -D "$KD"
      log "INFO" "dkim: clave creada para $DOMAIN"
      audit "cli" "dkim.create" "$DOMAIN" "ok" "selector=$SELECTOR"
    fi
    chown -R opendkim:opendkim "$KD"; chmod 750 "$KD"; chmod 600 "$KD/$SELECTOR.private"; chmod 644 "$KD/$SELECTOR.txt"
    dkim_sync_tables
    echo "DKIM_TXT=$(dkim_txt "$DOMAIN")"
    ;;
  show)
    [[ $# -ge 1 ]] || { usage; die 2 "Falta dominio"; }
    DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido: $1"
    t="$(dkim_txt "$DOMAIN")" || die 4 "Sin clave DKIM para $DOMAIN"
    echo "DKIM_TXT=$t"
    ;;
  del|remove|rm)
    [[ $# -ge 1 ]] || { usage; die 2 "Falta dominio"; }
    DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido: $1"
    if [[ -d "$DKIM_KEYS/$DOMAIN" ]]; then
      rm -rf -- "${DKIM_KEYS:?}/$DOMAIN"
      audit "cli" "dkim.del" "$DOMAIN" "ok" ""
    fi
    dkim_sync_tables
    echo "OK dkim del $DOMAIN"
    ;;
  sync) dkim_sync_tables; echo "OK dkim sync" ;;
  *) usage; die 2 "Acción inválida" ;;
esac
