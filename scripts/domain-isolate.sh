#!/usr/bin/env bash
# Flesk — migra un dominio existente al aislamiento por dominio (rc3), de forma idempotente:
#   flesk domain isolate <dominio>|--all
# 1) usuario/grupo fk_<dominio> (+ www-data y el usuario del panel en el grupo)
# 2) pool PHP-FPM propio (php-fpm -t; restaura si falla) y espera al socket
# 3) recarga nginx (sus workers adquieren el grupo nuevo)
# 4) dueños: lo que era de www-data/root pasa a fk_<dominio> (los ficheros de usuarios SFTP conservan dueño)
# 5) vhost (y reglas de apps) → fastcgi_pass al socket propio; nginx -t; si falla, restaura el vhost
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/isolation.sh"
require_root
ensure_installed
[[ $# -ge 1 ]] || die 2 "Uso: flesk domain isolate <dominio>|--all"

NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/fresk-enabled}"

isolate_one() {
  local d="$1" u vf sock f changed=0 bakdir i=0
  local -a origs=()
  [[ -n "$(mysql_q -e "SELECT id FROM domains WHERE name='${d}' LIMIT 1;")" ]] || die 3 "Dominio no registrado: $d"
  vf="$NGINX_ENABLED/$d.conf"
  [[ -f "$vf" ]] || die 3 "Sin vhost para $d"
  lock "domain:$d"
  u="$(iso_ensure_user "$d")"
  iso_write_pool "$d"
  iso_reload_fpm "$d"
  if nginx -t 2>"$FRESK_RUN/nginx-t.$$"; then reload_service nginx; sleep 2; else cat "$FRESK_RUN/nginx-t.$$" >&2; rm -f "$FRESK_RUN/nginx-t.$$"; die 6 "nginx -t falla antes de migrar $d (no se toca nada más)"; fi
  rm -f "$FRESK_RUN/nginx-t.$$"
  iso_fix_perms "$d" --recursive
  sock="$(iso_sock "$d")"
  bakdir="$(mktemp -d "$FRESK_RUN/isolate.XXXXXX")"
  for f in "$vf" /etc/nginx/fresk-apps/"$d"/*.conf /etc/nginx/fresk-apps/"$d"/server/*.conf; do
    [[ -f "$f" ]] || continue
    grep -q 'fastcgi_pass unix:' "$f" || continue
    backup_file "$f"
    i=$((i+1)); origs+=("$f"); cp -a "$f" "$bakdir/$i"
    # Solo cambia sockets que no sean ya el del dominio ni el del panel
    sed -i -E "\#fastcgi_pass unix:(${sock}|${PANEL_FPM_SOCK});#! s#fastcgi_pass unix:[^;]+;#fastcgi_pass unix:${sock};#" "$f"
    cmp -s "$f" "$bakdir/$i" || changed=1
  done
  if [[ "$changed" == "1" ]]; then
    if nginx -t 2>"$FRESK_RUN/nginx-t.$$"; then
      reload_service nginx
      SYS="${VHOSTS_ROOT:-/var/www/vhosts}/system/$d/conf"; [[ -d "$SYS" ]] && cp -a "$vf" "$SYS/nginx.conf"
    else
      cat "$FRESK_RUN/nginx-t.$$" >&2 || true
      for ((i=1; i<=${#origs[@]}; i++)); do cp -a "$bakdir/$i" "${origs[$((i-1))]}"; done
      nginx -t >/dev/null 2>"$FRESK_RUN/nginx-t.$$" && reload_service nginx || true
      rm -rf "$bakdir" "$FRESK_RUN/nginx-t.$$"
      die 6 "nginx -t falló al cambiar el socket de $d; vhost restaurado"
    fi
    rm -f "$FRESK_RUN/nginx-t.$$"
  fi
  rm -rf "$bakdir"
  unlock
  log "INFO" "domain.isolate $d ok user=$u sock=$sock vhost_changed=$changed"
  audit "cli" "domain.isolate" "$d" "ok" "user=$u"
  echo "OK domain=$d user=$u sock=$sock"
}

if [[ "$1" == "--all" ]]; then
  while read -r d; do
    [[ -n "$d" ]] || continue
    d="$(valid_domain "$d")" || continue
    isolate_one "$d"
  done < <(mysql_q -e "SELECT name FROM domains ORDER BY id;")
else
  D="$(valid_domain "$1")" || die 2 "Dominio inválido"
  isolate_one "$D"
fi
exit 0
