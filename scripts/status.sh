#!/usr/bin/env bash
# flesk status — puerta de fase 0/1
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

if [[ ! -f "$FRESK_CONFIG" ]]; then
  echo "Flesk: NO INSTALADO (falta $FRESK_CONFIG)"
  echo "Ejecuta: sudo /opt/flesk/install.sh  o  sudo ./install.sh"
  exit 3
fi

echo "=== Flesk status ==="
echo "Root:     $FRESK_ROOT"
echo "Config:   $FRESK_CONFIG"
echo "Panel:    http://${PUBLIC_IP:-IP}${PANEL_BASE_PATH:-/flesk}"
echo "Domain:   ${PANEL_DOMAIN:-(ninguno — LE del panel en espera)}"
echo "Admin:    ${ADMIN_EMAIL:-?}"
echo

ok=0
fail=0
check_svc() {
  local s="$1"
  if systemctl is-active --quiet "$s" 2>/dev/null; then
    printf '  %-18s active\n' "$s"
    ok=$((ok+1))
  else
    printf '  %-18s INACTIVE\n' "$s"
    fail=$((fail+1))
  fi
}

echo "Servicios:"
PHP_FPM_SVC="php${PHP_VERSION:-8.3}-fpm"
for s in nginx "$PHP_FPM_SVC" mariadb postfix dovecot bind9 fail2ban; do
  check_svc "$s"
done

echo
echo "Firewall (ufw):"
if command -v ufw >/dev/null 2>&1; then
  ufw status | head -20 || true
else
  echo "  ufw no instalado"
fi

echo
if [[ -f "${DB_PASS_FILE:-$FRESK_ROOT/var/.dbpass}" ]]; then
  if mysql_q -e "SELECT COUNT(*) FROM domains;" >/dev/null 2>&1; then
    n="$(mysql_q -e "SELECT COUNT(*) FROM domains;" | tr -d '[:space:]')"
    echo "MariaDB fresk: OK (dominios=$n)"
  else
    echo "MariaDB fresk: ERROR de conexión"
    fail=$((fail+1))
  fi
else
  echo "MariaDB fresk: sin .dbpass"
  fail=$((fail+1))
fi

echo
if [[ "$fail" -gt 0 ]]; then
  echo "Estado: DEGRADADO ($fail fallos, $ok ok)"
  exit 5
fi
echo "Estado: OK ($ok servicios)"
exit 0
