#!/usr/bin/env bash
# Flesk — contestador automático por buzón (Dovecot Sieve/Pigeonhole "vacation")
#   flesk mail vacation get <user@dominio>        configuración en JSON
#   flesk mail vacation set <user@dominio>        JSON por stdin: {"enabled":true,"subject":"…","body":"…","html":false,"start":"AAAA-MM-DD","end":"AAAA-MM-DD"}
#   flesk mail vacation off <user@dominio>
#   flesk mail vacation sync                      regenera los scripts desde la BD
# Como mucho una respuesta al día por remitente (:days 1); no responde a listas, robots ni avisos automáticos.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
require_root
ensure_installed
ACTION="${1:-}"; shift || true
case "$ACTION" in
  get|set|off)
    [[ $# -ge 1 ]] || die 2 "Uso: flesk mail vacation $ACTION <user@dominio>"
    EMAIL="$(valid_email "$1")" || die 2 "Email inválido: $1"
    command -v sievec >/dev/null 2>&1 || die 4 "Falta dovecot-sieve (apt install dovecot-sieve dovecot-lmtpd)"
    if [[ "$ACTION" == "get" ]]; then
      exec php "$FRESK_ROOT/lib/mail-vacation.php" get "$EMAIL"
    fi
    lock "mail:$EMAIL"; trap 'unlock' EXIT
    set +e
    OUT="$(php "$FRESK_ROOT/lib/mail-vacation.php" "$ACTION" "$EMAIL" 2>&1)"; rc=$?
    set -e
    echo "$OUT"
    if [[ $rc -eq 0 ]]; then
      log "INFO" "mail.vacation $EMAIL $ACTION ok"
      audit "cli" "mail.vacation" "$EMAIL" "ok" "$(printf '%s' "$OUT" | head -1 | cut -c1-200)"
    else
      audit "cli" "mail.vacation" "$EMAIL" "error" "$(printf '%s' "$OUT" | head -1 | cut -c1-200)"
    fi
    exit "$rc"
    ;;
  sync)
    php "$FRESK_ROOT/lib/mail-vacation.php" sync
    ;;
  *) die 2 "Uso: flesk mail vacation get|set|off <user@dominio> | sync" ;;
esac
