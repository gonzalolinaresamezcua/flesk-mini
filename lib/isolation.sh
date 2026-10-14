#!/usr/bin/env bash
# Flesk — aislamiento por dominio (rc3): usuario de sistema + grupo + pool PHP-FPM propio.
#   Usuario/grupo  fk_<dominio>  (sin shell, sin contraseña, home = /var/www/vhosts/<dominio>)
#   Pool           /etc/php/<ver>/fpm/pool.d/flesk-<dominio>.conf  → socket /run/php/flesk-<dominio>.sock (0660 www-data: solo nginx)
#   Árbol          <vroot> root:root 755 (chroot SFTP) · httpdocs/apps/private <u>:<u> 2770 · tmp <u> 770 · logs root:<u> 750
#   Miembros del grupo <u>: www-data (nginx sirve estáticos) y el usuario del panel (gestor de archivos). Nadie más.
# Sourceado por scripts/*.sh después de lib/common.sh.
# shellcheck disable=SC2034

PANEL_USER="${PANEL_USER:-flesk}"
PANEL_FPM_SOCK="${PANEL_FPM_SOCK:-/run/php/flesk-panel.sock}"
ISO_DISABLE_FUNCTIONS="${ISO_DISABLE_FUNCTIONS:-exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec,dl,posix_kill,posix_setuid,posix_setgid,posix_seteuid,posix_setegid,posix_setsid,posix_mkfifo}"

# Nombre del usuario de sistema del dominio (máx. 32 caracteres; sufijo hash si no cabe)
iso_user_for() {
  local d="$1" s u
  s="$(printf '%s' "$d" | tr -c 'a-z0-9' '_')"
  u="fk_$s"
  if (( ${#u} > 32 )); then
    u="fk_${s:0:20}_$(printf '%s' "$d" | sha1sum | cut -c1-8)"
  fi
  printf '%s' "$u"
}

iso_vroot() { printf '%s/%s' "${VHOSTS_ROOT:-/var/www/vhosts}" "$1"; }
iso_sock() { printf '/run/php/flesk-%s.sock' "$1"; }

# Versión PHP del dominio (BD) con FPM instalado; si no, la del servidor
iso_php_ver() {
  local d="$1" v="${ISO_PHP_VER:-}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+$ && -d "/etc/php/$v/fpm/pool.d" ]] && { printf '%s' "$v"; return 0; }
  v="$(mysql_q -e "SELECT php_version FROM domains WHERE name='${d}' LIMIT 1;" 2>/dev/null || true)"
  [[ "$v" =~ ^[0-9]+\.[0-9]+$ && -d "/etc/php/$v/fpm/pool.d" ]] || v="${PHP_VERSION:-8.3}"
  printf '%s' "$v"
}
iso_pool_file() { printf '/etc/php/%s/fpm/pool.d/flesk-%s.conf' "$2" "$1"; }

# ¿Está el dominio aislado? (usuario fk_ dueño de httpdocs y pool presente)
iso_is_isolated() {
  local d="$1" u; u="$(iso_user_for "$d")"
  id "$u" >/dev/null 2>&1 && [[ "$(stat -c %U -- "$(iso_vroot "$d")/httpdocs" 2>/dev/null)" == "$u" ]] \
    && [[ -f "$(iso_pool_file "$d" "$(iso_php_ver "$d")")" ]]
}

# Usuario efectivo del dominio: dueño de httpdocs si no es root ni www-data; si no, el fk_ calculado
iso_domain_user() {
  local d="$1" o
  o="$(stat -c %U -- "$(iso_vroot "$d")/httpdocs" 2>/dev/null || true)"
  if [[ -n "$o" && "$o" != "root" && "$o" != "${WEB_USER:-www-data}" && "$o" != "UNKNOWN" ]]; then printf '%s' "$o"; else iso_user_for "$d"; fi
}

# Crea (idempotente) grupo + usuario del dominio y añade www-data y el usuario del panel al grupo
iso_ensure_user() {
  local d="$1" u vroot home
  u="$(iso_user_for "$d")"; vroot="$(iso_vroot "$d")"
  getent group "$u" >/dev/null 2>&1 || groupadd --system "$u"
  if id "$u" >/dev/null 2>&1; then
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ "$home" == "$vroot" ]] || die 4 "El usuario $u ya existe y no pertenece a $d (home=$home)"
  else
    useradd --system -g "$u" -d "$vroot" -M -s /usr/sbin/nologin -c "Flesk $d" "$u"
  fi
  usermod -L "$u" 2>/dev/null || true
  gpasswd -a "${WEB_USER:-www-data}" "$u" >/dev/null
  if id "$PANEL_USER" >/dev/null 2>&1; then gpasswd -a "$PANEL_USER" "$u" >/dev/null; fi
  printf '%s' "$u"
}

# Ajusta dueños/permisos del árbol del dominio. Con --recursive migra lo que sea de www-data/root/sin dueño.
# Los ficheros de usuarios SFTP del dominio conservan su dueño (solo se ajusta el grupo).
iso_fix_perms() {
  local d="$1" mode="${2:-}" u vroot x
  u="$(iso_user_for "$d")"; vroot="$(iso_vroot "$d")"
  [[ -d "$vroot" && ! -L "$vroot" ]] || die 3 "Falta $vroot"
  mkdir -p "$vroot/httpdocs" "$vroot/logs" "$vroot/tmp"
  chown root:root "$vroot"; chmod 755 "$vroot"
  for x in httpdocs apps private; do
    [[ -d "$vroot/$x" && ! -L "$vroot/$x" ]] || continue
    if [[ "$mode" == "--recursive" ]]; then
      find -P "$vroot/$x" -xdev \( -user "${WEB_USER:-www-data}" -o -user root -o -nouser \) -exec chown -h "$u" {} +
      find -P "$vroot/$x" -xdev ! -group "$u" -exec chgrp -h "$u" {} +
      find -P "$vroot/$x" -xdev -type d ! -perm -2000 -exec chmod g+s {} +
    fi
    chown "$u:$u" "$vroot/$x"; chmod 2770 "$vroot/$x"
  done
  chown "$u:$u" "$vroot/tmp"; chmod 770 "$vroot/tmp"
  install -d -m 700 -o "$u" -g "$u" "$vroot/tmp/sessions"
  chown root:"$u" "$vroot/logs"; chmod 750 "$vroot/logs"
  [[ -f "$vroot/logs/php-error.log" ]] || install -m 640 -o "$u" -g "$u" /dev/null "$vroot/logs/php-error.log"
  chown "$u:$u" "$vroot/logs/php-error.log"; chmod 640 "$vroot/logs/php-error.log"
}

# Escribe el pool del dominio, valida con php-fpm -t (restaura si falla). No recarga.
iso_write_pool() {
  local d="$1" u ver pf vroot tmp bak=""
  u="$(iso_user_for "$d")"; ver="$(iso_php_ver "$d")"; pf="$(iso_pool_file "$d" "$ver")"; vroot="$(iso_vroot "$d")"
  tmp="$(mktemp "$FRESK_RUN/pool.XXXXXX")"
  render_template "$FRESK_ROOT/templates/php-fpm-domain-pool.conf" "$tmp" \
    "DOMAIN=$d" "USER=$u" "SOCK=$(iso_sock "$d")" "VROOT=$vroot" "WEB_USER=${WEB_USER:-www-data}" "DISABLE_FUNCTIONS=$ISO_DISABLE_FUNCTIONS"
  if [[ -f "$pf" ]]; then
    if cmp -s "$tmp" "$pf"; then rm -f "$tmp"; return 0; fi
    bak="$FRESK_RUN/pool.bak.$$"; cp -a "$pf" "$bak"
  fi
  atomic_install "$tmp" "$pf" 644 root:root; rm -f "$tmp"
  if ! "php-fpm$ver" -t >"$FRESK_RUN/php-fpm-t.$$" 2>&1; then
    cat "$FRESK_RUN/php-fpm-t.$$" >&2 || true
    if [[ -n "$bak" ]]; then mv -f "$bak" "$pf"; else rm -f "$pf"; fi
    rm -f "$FRESK_RUN/php-fpm-t.$$"
    die 6 "php-fpm -t falló con el pool de $d; restaurado"
  fi
  rm -f "$FRESK_RUN/php-fpm-t.$$" "$bak"
}

# Recarga PHP-FPM y espera al socket del dominio (máx. 20 s)
iso_reload_fpm() {
  local d="${1:-}" ver i
  ver="${2:-${PHP_VERSION:-8.3}}"
  [[ -n "$d" ]] && ver="$(iso_php_ver "$d")"
  reload_service "php${ver}-fpm"
  [[ -z "$d" ]] && return 0
  for i in $(seq 1 40); do [[ -S "$(iso_sock "$d")" ]] && return 0; sleep 0.5; done
  die 6 "El socket $(iso_sock "$d") no apareció tras recargar php${ver}-fpm"
}

# Alta completa (idempotente): usuario, permisos, pool, recarga
iso_setup_domain() {
  local d="$1" mode="${2:-}"
  iso_ensure_user "$d" >/dev/null
  iso_fix_perms "$d" "$mode"
  iso_write_pool "$d"
  iso_reload_fpm "$d"
}

# Baja: pool, procesos, usuario y grupo (no toca los datos). --keep-user conserva usuario/grupo (datos conservados)
iso_remove_domain() {
  local d="$1" keep="${2:-}" u ver pf
  u="$(iso_user_for "$d")"
  for ver in /etc/php/*/fpm/pool.d; do
    pf="$ver/flesk-$d.conf"
    [[ -f "$pf" ]] || continue
    backup_file "$pf"; rm -f "$pf"
    ver="$(basename "$(dirname "$(dirname "$ver")")")"
    if "php-fpm$ver" -t >"$FRESK_RUN/php-fpm-t.$$" 2>&1; then reload_service "php${ver}-fpm"; else log "WARN" "php-fpm$ver -t falla tras quitar el pool de $d"; fi
    rm -f "$FRESK_RUN/php-fpm-t.$$"
  done
  [[ "$keep" == "--keep-user" ]] && return 0
  if id "$u" >/dev/null 2>&1 && [[ "$(getent passwd "$u" | cut -d: -f6)" == "$(iso_vroot "$d")" ]]; then
    pkill -u "$u" 2>/dev/null || true; sleep 0.3
    userdel "$u" 2>/dev/null || userdel -f "$u" 2>/dev/null || log "WARN" "No se pudo borrar el usuario $u"
  fi
  getent group "$u" >/dev/null 2>&1 && { groupdel "$u" 2>/dev/null || log "WARN" "No se pudo borrar el grupo $u"; }
  return 0
}
