#!/usr/bin/env bash
# Flesk — librería común. Sourceada por bin/flesk y scripts/*.sh
# shellcheck disable=SC2034

set -euo pipefail

FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
FRESK_CONFIG="${FRESK_CONFIG:-$FRESK_ROOT/config.conf}"
FRESK_LOG="${FRESK_LOG:-$FRESK_ROOT/var/log/fresk.log}"
FRESK_RUN="${FRESK_RUN:-$FRESK_ROOT/var/run}"
FRESK_BACKUPS="${FRESK_BACKUPS:-$FRESK_ROOT/var/backups}"

# Cargar config si existe (sin fallar en fase 0 / pre-install)
if [[ -f "$FRESK_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$FRESK_CONFIG"
fi

# Redacta PASSWORD=... (y variantes) en cadenas de log/auditoría
scrub_secrets() {
  local s="$*"
  s="$(printf '%s' "$s" | sed -E 's/(PASSWORD|DB_PASSWORD|PASSWD|MYSQL_PWD)=[^[:space:]]+/\1=***/g')"
  printf '%s' "$s"
}

log() {
  local level="${1:-INFO}"; shift || true
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S %z')"
  mkdir -p "$(dirname "$FRESK_LOG")" 2>/dev/null || true
  msg="$(scrub_secrets "$msg")"
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$FRESK_LOG" >&2
}

die() {
  local code="${1:-1}"; shift || true
  log "ERROR" "$*"
  exit "$code"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die 3 "Se requiere root (o sudo). Ejecuta: sudo flesk ..."
  fi
}

# Lock por nombre de operación (flock)
lock() {
  local name="$1"
  local safe
  safe="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
  mkdir -p "$FRESK_RUN"
  exec 9>"$FRESK_RUN/${safe}.lock"
  if ! flock -n 9; then
    die 4 "Operación en curso: $name (lock $safe)"
  fi
  FRESK_LOCK_NAME="$safe"
}

unlock() {
  # flock se libera al cerrar el FD / salir del proceso
  if [[ -n "${FRESK_LOCK_NAME:-}" ]]; then
    flock -u 9 2>/dev/null || true
  fi
}

valid_domain() {
  local d="${1:-}"
  d="${d,,}"
  d="${d%.}"
  if [[ -z "$d" || ${#d} -gt 253 ]]; then return 1; fi
  if [[ "$d" =~ :// || "$d" =~ / || "$d" =~ [[:space:]] ]]; then return 1; fi
  # etiquetas DNS: a-z0-9 y guiones, no empezar/terminar en guion
  if [[ ! "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ && ! "$d" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    return 1
  fi
  printf '%s' "$d"
  return 0
}

valid_local() {
  local u="${1:-}"
  if [[ ! "$u" =~ ^[a-z0-9]([a-z0-9._-]{0,63})$ ]]; then
    return 1
  fi
  if [[ "$u" == .* ]]; then return 1; fi
  printf '%s' "$u"
  return 0
}

mysql_q() {
  local pass_file="${DB_PASS_FILE:-$FRESK_ROOT/var/.dbpass}"
  local user="${DB_USER:-fresk_panel}"
  local host="${DB_HOST:-127.0.0.1}"
  local db="${DB_NAME:-fresk}"
  if [[ ! -f "$pass_file" ]]; then
    die 3 "Falta contraseña DB: $pass_file (¿install.sh ejecutado?)"
  fi
  local pass
  pass="$(<"$pass_file")"
  MYSQL_PWD="$pass" mysql -N -B -h "$host" -u "$user" "$db" "$@"
}

mysql_admin_q() {
  local pass_file="${DB_ADMIN_PASS_FILE:-$FRESK_ROOT/var/.dbadminpass}"
  local user="${DB_ADMIN_USER:-fresk_admin}"
  local host="${DB_HOST:-127.0.0.1}"
  if [[ ! -f "$pass_file" ]]; then
    die 3 "Falta contraseña DB admin: $pass_file"
  fi
  local pass
  pass="$(<"$pass_file")"
  MYSQL_PWD="$pass" mysql -N -B -h "$host" -u "$user" "$@"
}

# Sustituye {{CLAVE}} en plantilla. Falla si queda {{ sin cerrar o token sin valor.
render_template() {
  local template="$1"
  local dest="$2"
  shift 2
  # resto: KEY=value pares
  if [[ ! -f "$template" ]]; then
    die 3 "Plantilla no encontrada: $template"
  fi
  mkdir -p "$FRESK_RUN" "$(dirname "$dest")"
  local tmp
  tmp="$(mktemp "$FRESK_RUN/tpl.XXXXXX")"
  cp "$template" "$tmp"
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    # Escape sed specials in val minimally
    val_esc="$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')"
    sed -i "s/{{${key}}}/${val_esc}/g" "$tmp"
  done
  if grep -qE '\{\{[A-Z0-9_]+\}\}' "$tmp"; then
    local leftover
    leftover="$(grep -oE '\{\{[A-Z0-9_]+\}\}' "$tmp" | sort -u | tr '\n' ' ')"
    rm -f "$tmp"
    die 2 "Tokens sin valor en plantilla: $leftover"
  fi
  if grep -qE '\{\{' "$tmp"; then
    rm -f "$tmp"
    die 2 "Quedan {{ sin cerrar en plantilla $template"
  fi
  mv -f "$tmp" "$dest"
}

backup_file() {
  local f="$1"
  if [[ ! -e "$f" ]]; then return 0; fi
  local stamp
  stamp="$(date '+%Y%m%d%H%M%S')"
  mkdir -p "$FRESK_BACKUPS"
  local base
  base="$(printf '%s' "$f" | tr '/' '_')"
  cp -a "$f" "$FRESK_BACKUPS/${base}.${stamp}"
}

atomic_install() {
  local src="$1"
  local dest="$2"
  local mode="${3:-644}"
  local owner="${4:-root:root}"
  mkdir -p "$(dirname "$dest")"
  local tmp
  tmp="$(mktemp "$(dirname "$dest")/.fresk.XXXXXX")"
  cp "$src" "$tmp"
  chmod "$mode" "$tmp"
  chown "$owner" "$tmp"
  mv -f "$tmp" "$dest"
}

reload_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    systemctl reload "$svc" || systemctl restart "$svc"
  else
    systemctl start "$svc"
  fi
}

ensure_installed() {
  if [[ ! -f "$FRESK_CONFIG" ]]; then
    die 3 "Flesk no está instalado (falta $FRESK_CONFIG). Ejecuta: sudo ./install.sh"
  fi
}

gen_password() {
  if command -v pwgen >/dev/null 2>&1; then
    pwgen -s 24 1
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  fi
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  printf '%s' "$ip"
}

# IPv6 pública global (config PUBLIC_IP6 o detección); vacío si no hay
detect_public_ip6() {
  local ip=""
  ip="$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  case "$ip" in fe80*|::1|"") ip="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)" ;; esac
  [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]] && printf '%s' "$ip"
  return 0
}

fresk_ipv4() { local v="${PUBLIC_IP:-}"; [[ -n "$v" ]] || v="$(detect_public_ip || true)"; printf '%s' "$v"; }
fresk_ipv6() { local v="${PUBLIC_IP6:-}"; [[ -n "$v" ]] || v="$(detect_public_ip6 || true)"; printf '%s' "$v"; }

# Nombres DNS del certificado (SAN), uno por línea
cert_names() {
  [[ -f "$1" ]] || return 0
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS:\([^ ]*\).*/\1/p'
}
# ¿El certificado cubre el nombre? (exacto o comodín *.padre)
cert_covers() {
  local cert="$1" name="$2" n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    [[ "$n" == "$name" ]] && return 0
    [[ "$n" == \*.* && "${name#*.}" == "${n#\*.}" ]] && return 0
  done < <(cert_names "$cert")
  return 1
}

audit() {
  local actor="${1:-cli}" action="$2" target="${3:-}" result="$4" detail="${5:-}"
  # Nunca persistir contraseñas en audit_log
  actor="$(scrub_secrets "$actor")"
  action="$(scrub_secrets "$action")"
  target="$(scrub_secrets "$target")"
  detail="$(scrub_secrets "$detail")"
  if [[ -f "${DB_PASS_FILE:-$FRESK_ROOT/var/.dbpass}" ]]; then
    mysql_q -e "INSERT INTO audit_log (actor,action,target,result,detail) VALUES (
      '$(printf '%s' "$actor" | sed "s/'/\\'/g")',
      '$(printf '%s' "$action" | sed "s/'/\\'/g")',
      '$(printf '%s' "$target" | sed "s/'/\\'/g")',
      '$(printf '%s' "$result" | sed "s/'/\\'/g")',
      '$(printf '%s' "$detail" | sed "s/'/\\'/g")'
    );" 2>/dev/null || true
  fi
}

# Parsea user@dominio → imprime "local domain" o falla
parse_email() {
  local raw="${1:-}"
  raw="${raw,,}"
  raw="${raw// /}"
  if [[ ! "$raw" =~ ^[^@]+@[^@]+$ ]]; then
    return 1
  fi
  local local_part="${raw%%@*}"
  local domain_part="${raw#*@}"
  local_part="$(valid_local "$local_part")" || return 1
  domain_part="$(valid_domain "$domain_part")" || return 1
  printf '%s %s' "$local_part" "$domain_part"
  return 0
}

valid_email() {
  local raw="${1:-}"
  local parsed local_part domain_part
  parsed="$(parse_email "$raw")" || return 1
  local_part="${parsed%% *}"
  domain_part="${parsed#* }"
  printf '%s@%s' "$local_part" "$domain_part"
  return 0
}

# Destino de alias/forward: email o lista simple local@dom
valid_destination() {
  local d="${1:-}"
  d="${d,,}"
  d="${d// /}"
  if [[ -z "$d" || ${#d} -gt 255 ]]; then return 1; fi
  if [[ "$d" =~ [\;\{\}\$\`\|\&\<\>] ]]; then return 1; fi
  # un solo email
  if [[ "$d" =~ ^[a-z0-9._+-]+@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
    printf '%s' "$d"
    return 0
  fi
  return 1
}

hash_mailbox_password() {
  local plain="$1"
  if command -v doveadm >/dev/null 2>&1; then
    doveadm pw -s SHA512-CRYPT -p "$plain"
  else
    # Fallback openssl-based (menos ideal; doveadm es el camino)
    python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.METHOD_SHA512))' "$plain"
  fi
}

ensure_maildir() {
  local path="$1"
  local uid="${VMAIL_UID:-5000}"
  local gid="${VMAIL_GID:-5000}"
  mkdir -p "$path"/{cur,new,tmp}
  chown -R "${uid}:${gid}" "$path"
  chmod 700 "$path"
  chmod 700 "$path"/cur "$path"/new "$path"/tmp
}
