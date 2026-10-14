#!/usr/bin/env bash
# Flesk — baja de credenciales efímeras de Adminer (fks_*).
# Uso: flesk db logout <fks_usuario> | --expired | --all
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

require_root
ensure_installed

[[ $# -eq 1 ]] || die 2 "Uso: flesk db logout <fks_usuario>|--expired|--all"
MODE="$1"
NOW="$(date +%s)"
drop_user() {
  local u="$1"
  [[ "$u" =~ ^fks_[0-9]{10}_[a-f0-9]{10}$ ]] || return 0
  # Cierra sus conexiones abiertas y borra la cuenta
  local ids
  ids="$(mysql_admin_q -e "SELECT ID FROM information_schema.PROCESSLIST WHERE USER='${u}';" || true)"
  for id in $ids; do [[ "$id" =~ ^[0-9]+$ ]] && { mysql_admin_q -e "KILL ${id};" || true; }; done
  mysql_admin_q -e "DROP USER IF EXISTS '${u}'@'localhost';"
  log "INFO" "db.logout user=$u"
  audit "cli" "db.logout" "$u" "ok" ""
}
case "$MODE" in
  --expired|--all)
    USERS="$(mysql_admin_q -e "SELECT DISTINCT User FROM mysql.user WHERE User LIKE 'fks\\_%';")"
    n=0
    for u in $USERS; do
      [[ "$u" =~ ^fks_([0-9]{10})_[a-f0-9]{10}$ ]] || continue
      if [[ "$MODE" == "--all" || "${BASH_REMATCH[1]}" -le "$NOW" ]]; then drop_user "$u"; n=$((n+1)); fi
    done
    echo "OK purged=$n"
    ;;
  *)
    [[ "$MODE" =~ ^fks_[0-9]{10}_[a-f0-9]{10}$ ]] || die 2 "Usuario no válido (solo credenciales fks_ efímeras)"
    drop_user "$MODE"
    echo "OK user=$MODE"
    ;;
esac
exit 0
