#!/usr/bin/env bash
# Flesk — renovación Let's Encrypt (fase 3)
# Uso: flesk ssl renew | renew-all
# Ejecuta certbot renew + actualiza not_after en ssl_certs + reload nginx si hubo cambio.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk ssl renew|renew-all" >&2
  echo "  Renueva certificados Let's Encrypt y actualiza ssl_certs.not_after." >&2
}

require_root
ensure_installed

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

lock "ssl:renew"
trap 'unlock' EXIT

if ! command -v certbot >/dev/null 2>&1; then
  die 3 "certbot no instalado"
fi

# Hook: marcar que hubo renovación real (certbot solo llama deploy-hook si renovó)
HOOK_FLAG="$FRESK_RUN/ssl-renewed.flag"
rm -f "$HOOK_FLAG"
DEPLOY_HOOK="touch $(printf '%q' "$HOOK_FLAG"); systemctl reload nginx"

log "INFO" "ssl.renew: certbot renew"
set +e
certbot renew --quiet --deploy-hook "$DEPLOY_HOOK" >/tmp/fresk-certbot-renew.out 2>/tmp/fresk-certbot-renew.err
CB_RC=$?
set -e

if [[ $CB_RC -ne 0 ]]; then
  log "ERROR" "certbot renew falló (rc=$CB_RC)"
  tail -n 30 /tmp/fresk-certbot-renew.err >&2 || true
  audit "cli" "ssl.renew" "-" "fail" "certbot rc=$CB_RC"
  die 5 "certbot renew falló"
fi

# Actualizar not_after / status para cada fila en ssl_certs
ROWS="$(mysql_q -e "SELECT c.id, d.name, c.path_fullchain, c.status FROM ssl_certs c JOIN domains d ON d.id = c.domain_id;" 2>/dev/null || true)"
UPDATED=0
EXPIRED=0
MISSING=0

while IFS=$'\t' read -r cid dname path_fc status || [[ -n "${cid:-}" ]]; do
  [[ -z "${cid:-}" ]] && continue
  if [[ -z "$path_fc" || ! -f "$path_fc" ]]; then
    mysql_q -e "UPDATE ssl_certs SET status='error' WHERE id=${cid};" 2>/dev/null || true
    MISSING=$((MISSING + 1))
    continue
  fi
  NOT_AFTER_RAW="$(openssl x509 -enddate -noout -in "$path_fc" 2>/dev/null | sed 's/notAfter=//' || true)"
  if [[ -z "$NOT_AFTER_RAW" ]]; then
    continue
  fi
  NOT_AFTER_SQL="$(date -u -d "$NOT_AFTER_RAW" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  [[ -z "$NOT_AFTER_SQL" ]] && continue
  # ¿Caducado?
  NOW_EPOCH="$(date -u +%s)"
  EXP_EPOCH="$(date -u -d "$NOT_AFTER_RAW" +%s 2>/dev/null || echo 0)"
  NEW_STATUS="active"
  if [[ "$EXP_EPOCH" -gt 0 && "$EXP_EPOCH" -lt "$NOW_EPOCH" ]]; then
    NEW_STATUS="expired"
    EXPIRED=$((EXPIRED + 1))
  fi
  mysql_q -e "UPDATE ssl_certs SET not_after='${NOT_AFTER_SQL}', status='${NEW_STATUS}' WHERE id=${cid};"
  UPDATED=$((UPDATED + 1))
done <<< "$ROWS"

RENEWED="no"
if [[ -f "$HOOK_FLAG" ]]; then
  RENEWED="yes"
  rm -f "$HOOK_FLAG"
fi

log "INFO" "ssl.renew ok renewed=$RENEWED updated=$UPDATED expired=$EXPIRED missing=$MISSING"
audit "cli" "ssl.renew" "-" "ok" "renewed=$RENEWED updated=$UPDATED"
echo "OK ssl.renew renewed=$RENEWED certs_updated=$UPDATED expired=$EXPIRED missing_files=$MISSING"
exit 0
