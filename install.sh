#!/usr/bin/env bash
# Flesk Mini install.sh — edición de prueba (1 dominio). Idempotente. Ubuntu 24.04 LTS.
# Más dominios: Flesk gratuito (3 dominios, registro) o de pago (ilimitado + IA) en https://serverflesk.es
set -euo pipefail

FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# Dominio del panel (opcional): PANEL_DOMAIN=panel.midominio.com ./install.sh
PANEL_DOMAIN_IN="${PANEL_DOMAIN:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

logi() { printf '[fresk-install] %s\n' "$*"; }
diei() { printf '[fresk-install] ERROR: %s\n' "$*" >&2; exit "${1:-1}"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || diei 3 "Ejecuta como root: sudo ./install.sh"

# --- 1. Preflight ---
OS_ID=""; OS_VER=""
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_VER="${VERSION_ID:-}"
fi
logi "Sistema: ${OS_ID:-?} ${OS_VER:-?}"

ADAPT=0
if [[ "$OS_ID" != "ubuntu" ]]; then
  diei 3 "Solo Ubuntu soportado (detectado: $OS_ID)"
fi
if [[ "$OS_VER" != "24.04" ]]; then
  logi "AVISO: planning exige 24.04; detectado $OS_VER — adaptando con cuidado"
  ADAPT=1
fi

# Disco
avail_root="$(df -BG / | awk 'NR==2{gsub(/G/,"",$4); print $4}')"
avail_var="$(df -BG /var 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}')"
avail_var="${avail_var:-$avail_root}"
if [[ "${avail_root:-0}" -lt 2 ]] || [[ "${avail_var:-0}" -lt 2 ]]; then
  diei 3 "Se necesitan ≥2GB libres en / y /var (root=${avail_root}G var=${avail_var}G)"
fi

# No Plesk / otro panel
if [[ -d /usr/local/psa ]] || command -v plesk >/dev/null 2>&1; then
  diei 3 "Plesk detectado — abortando (servidor debe estar limpio)"
fi
if [[ -d /usr/local/cpanel ]] || [[ -d /etc/webmin ]]; then
  diei 3 "Otro panel (cPanel/Webmin) detectado — abortando"
fi

# --- 2. Desplegar árbol a /opt/flesk ---
if [[ "$SCRIPT_DIR" != "$FRESK_ROOT" ]]; then
  logi "Copiando árbol → $FRESK_ROOT"
  command -v rsync >/dev/null 2>&1 || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync; } || diei 5 "No se pudo instalar rsync"
  mkdir -p "$FRESK_ROOT"
  # --no-owner/--no-group: nunca heredar el UID del empaquetador (p. ej. 1000 inexistente) en lo que ejecuta root
  rsync -a --no-owner --no-group --exclude 'var/log/*' --exclude 'var/run/*' --exclude 'var/backups/*' \
    --exclude 'config.conf' --exclude 'planning' \
    --exclude '.git' \
    "$SCRIPT_DIR"/ "$FRESK_ROOT"/
fi
mkdir -p "$FRESK_ROOT"/{var/{log,run,backups},web/{public,assets},sql,templates,scripts,bin,lib}
# web/public/assets → ../assets (enlace simbólico; no viaja en todos los métodos de descarga)
[[ -e "$FRESK_ROOT/web/public/assets" ]] || ln -s ../assets "$FRESK_ROOT/web/public/assets"
# Recursos binarios (fuentes de iconos y favicons PNG/ICO) se distribuyen en base64 dentro del repositorio
if [[ -f "$FRESK_ROOT/web/assets/binary-assets.tgz.b64" ]]; then
  base64 -d "$FRESK_ROOT/web/assets/binary-assets.tgz.b64" | tar xzf - --no-same-owner -C "$FRESK_ROOT/web/assets" || diei 5 "No se pudieron extraer los recursos binarios"
  ( cd "$FRESK_ROOT/web/assets" && sha256sum -c --quiet binary-assets.SHA256SUMS ) || diei 5 "Checksum de recursos binarios incorrecto"
fi
chmod 755 "$FRESK_ROOT"
chmod 750 "$FRESK_ROOT/var"
touch "$FRESK_ROOT/var/log/fresk.log"
chmod +x "$FRESK_ROOT/bin/flesk" "$FRESK_ROOT/install.sh" "$FRESK_ROOT"/scripts/*.sh 2>/dev/null || true

# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

# --- 3. Paquetes ---
export DEBIAN_FRONTEND=noninteractive
logi "apt-get update..."
apt-get update -qq

PHP_VER="8.3"
if [[ "$ADAPT" -eq 1 ]]; then
  # Detectar PHP disponible
  if ! apt-cache show php8.3-fpm >/dev/null 2>&1; then
    if apt-cache show php8.2-fpm >/dev/null 2>&1; then
      PHP_VER="8.2"
    elif apt-cache show php8.1-fpm >/dev/null 2>&1; then
      PHP_VER="8.1"
    else
      PHP_VER="$(apt-cache search '^php[0-9]\.[0-9]-fpm$' | head -1 | grep -oE 'php[0-9]+\.[0-9]+' | head -1 | sed 's/php//' || echo 8.3)"
    fi
    logi "PHP adaptado a $PHP_VER"
  fi
fi

PKGS=(
  nginx
  "php${PHP_VER}-fpm" "php${PHP_VER}-mysql" "php${PHP_VER}-cli"
  "php${PHP_VER}-mbstring" "php${PHP_VER}-xml" "php${PHP_VER}-curl" "php${PHP_VER}-zip"
  postfix dovecot-imapd dovecot-pop3d dovecot-mysql dovecot-lmtpd dovecot-sieve
  postfix-mysql
  bind9 mariadb-server
  certbot
  fail2ban ufw dnsutils pwgen curl rsync unzip zstd
  openssl ca-certificates
  opendkim opendkim-tools
  # Roundcube y el instalador de aplicaciones (WordPress, Drupal, PrestaShop, Dolibarr, SuiteCRM, EspoCRM)
  "php${PHP_VER}-intl" "php${PHP_VER}-gd" "php${PHP_VER}-soap" "php${PHP_VER}-bcmath" "php${PHP_VER}-ldap"
)
# python3-certbot-nginx opcional (usamos webroot, no plugin nginx)
logi "Instalando paquetes base..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${PKGS[@]}" || diei 5 "Fallo apt-get install"
# Opcional (miniaturas de WordPress de más calidad); no bloquea la instalación
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "php${PHP_VER}-imagick" >/dev/null 2>&1 \
  || logi "php${PHP_VER}-imagick no disponible (opcional)"

# Preseed postfix si es primera vez
if [[ ! -f /etc/postfix/main.cf ]]; then
  echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
  echo "postfix postfix/mailname string $(hostname -f 2>/dev/null || hostname)" | debconf-set-selections
fi

# --- 4. Usuarios de sistema ---
if ! getent group fresk >/dev/null; then
  groupadd --system fresk
  logi "Grupo fresk creado"
fi
if ! id fresk >/dev/null 2>&1; then
  useradd --system --gid fresk --home "$FRESK_ROOT" --shell /usr/sbin/nologin fresk
  logi "Usuario fresk creado"
fi
if ! getent group vmail >/dev/null; then
  groupadd --system --gid 5000 vmail
fi
# Usuario dedicado del panel (pool PHP-FPM flesk-panel): el único con sudo hacia bin/flesk y lector de los secretos
if ! getent group flesk >/dev/null; then
  groupadd --system flesk
fi
if ! id flesk >/dev/null 2>&1; then
  useradd --system --gid flesk --home "$FRESK_ROOT" --no-create-home --shell /usr/sbin/nologin flesk
  logi "Usuario flesk (panel) creado"
fi
usermod -L flesk >/dev/null 2>&1 || true
if ! id vmail >/dev/null 2>&1; then
  useradd --system --uid 5000 --gid 5000 --home /var/vmail --shell /usr/sbin/nologin vmail
  logi "Usuario vmail (5000) creado"
fi
mkdir -p /var/vmail
chown vmail:vmail /var/vmail
chmod 755 /var/vmail
if ! getent group sftponly >/dev/null; then
  groupadd --system sftponly
  logi "Grupo sftponly creado"
fi
mkdir -p /var/www/vhosts /var/www/vhosts/system /var/www/letsencrypt/.well-known/acme-challenge
chown root:root /var/www/vhosts
chmod 755 /var/www/vhosts

# --- 5. config.conf ---
PUBLIC_IP_DET="$(detect_public_ip || true)"
PUBLIC_IP6_DET="$(detect_public_ip6 || true)"
DB_PASS_FILE="$FRESK_ROOT/var/.dbpass"
DB_ADMIN_PASS_FILE="$FRESK_ROOT/var/.dbadminpass"

if [[ ! -f "$FRESK_ROOT/config.conf" ]]; then
  logi "Generando config.conf (primera instalación)"
  DB_PASS="$(gen_password)"
  DB_ADMIN_PASS="$(gen_password)"
  umask 077
  printf '%s\n' "$DB_PASS" > "$DB_PASS_FILE"
  printf '%s\n' "$DB_ADMIN_PASS" > "$DB_ADMIN_PASS_FILE"
  chown root:flesk "$DB_PASS_FILE"; chmod 640 "$DB_PASS_FILE"
  chown root:root "$DB_ADMIN_PASS_FILE"; chmod 600 "$DB_ADMIN_PASS_FILE"
  umask 022

  cat > "$FRESK_ROOT/config.conf" << CFGEOF
# Generado por install.sh — $(date -Iseconds)
PANEL_DOMAIN=${PANEL_DOMAIN_IN}
PANEL_BASE_PATH=/flesk
PANEL_LANG=es
# Descarga ZIP del gestor de archivos: límites
FILES_ZIP_MAX_MB=1024
FILES_ZIP_MAX_FILES=20000
ADMIN_EMAIL=admin@localhost
PUBLIC_IP=${PUBLIC_IP_DET}
PUBLIC_IP6=${PUBLIC_IP6_DET}
LE_EMAIL=
DB_HOST=127.0.0.1
DB_NAME=fresk
DB_USER=fresk_panel
DB_PASS_FILE=$DB_PASS_FILE
DB_ADMIN_USER=fresk_admin
DB_ADMIN_PASS_FILE=$DB_ADMIN_PASS_FILE
WEB_USER=www-data
FRESK_USER=fresk
PANEL_USER=flesk
PANEL_FPM_SOCK=/run/php/flesk-panel.sock
VMAIL_UID=5000
VMAIL_GID=5000
VMAIL_HOME=/var/vmail
PHP_VERSION=${PHP_VER}
PHP_FPM_SOCK=/run/php/flesk-panel.sock
FRESK_ROOT=$FRESK_ROOT
VHOSTS_ROOT=/var/www/vhosts
NGINX_ENABLED=/etc/nginx/fresk-enabled
BIND_ZONES=/etc/bind/fresk
DNS_PUBLIC=no
PANEL_PORT=8443
CFGEOF
  chown root:flesk "$FRESK_ROOT/config.conf"
  chmod 640 "$FRESK_ROOT/config.conf"
else
  logi "config.conf ya existe — no se pisa"
  # rc3: claves nuevas del aislamiento (se añaden si faltan)
  grep -q '^PANEL_USER=' "$FRESK_ROOT/config.conf" || echo 'PANEL_USER=flesk' >> "$FRESK_ROOT/config.conf"
  grep -q '^PANEL_FPM_SOCK=' "$FRESK_ROOT/config.conf" || echo 'PANEL_FPM_SOCK=/run/php/flesk-panel.sock' >> "$FRESK_ROOT/config.conf"
  chown root:flesk "$FRESK_ROOT/config.conf"; chmod 640 "$FRESK_ROOT/config.conf"
  [[ -f "$DB_PASS_FILE" ]] && { chown root:flesk "$DB_PASS_FILE"; chmod 640 "$DB_PASS_FILE"; }
  [[ -f "$DB_ADMIN_PASS_FILE" ]] && { chown root:root "$DB_ADMIN_PASS_FILE"; chmod 600 "$DB_ADMIN_PASS_FILE"; }
  # Asegurar pass files
  if [[ ! -f "$DB_PASS_FILE" ]]; then
    diei 5 "Existe config.conf pero falta $DB_PASS_FILE"
  fi
  # Actualizar PUBLIC_IP si vacío
  # shellcheck disable=SC1090,SC1091
  source "$FRESK_ROOT/config.conf"
  if [[ -z "${PUBLIC_IP:-}" && -n "$PUBLIC_IP_DET" ]]; then
    sed -i "s/^PUBLIC_IP=.*/PUBLIC_IP=${PUBLIC_IP_DET}/" "$FRESK_ROOT/config.conf"
  fi
  grep -q '^PUBLIC_IP6=' "$FRESK_ROOT/config.conf" || echo "PUBLIC_IP6=${PUBLIC_IP6_DET}" >> "$FRESK_ROOT/config.conf"
  if [[ -z "${PANEL_BASE_PATH:-}" ]]; then
    echo "PANEL_BASE_PATH=/flesk" >> "$FRESK_ROOT/config.conf"
  fi
  # Idioma por defecto del panel (paquetes es + en incluidos en web/lang)
  if ! grep -q '^PANEL_LANG=' "$FRESK_ROOT/config.conf"; then
    echo "PANEL_LANG=es" >> "$FRESK_ROOT/config.conf"
  fi
  # Límites de la descarga ZIP del gestor de archivos
  grep -q '^FILES_ZIP_MAX_MB=' "$FRESK_ROOT/config.conf" || echo "FILES_ZIP_MAX_MB=1024" >> "$FRESK_ROOT/config.conf"
  grep -q '^FILES_ZIP_MAX_FILES=' "$FRESK_ROOT/config.conf" || echo "FILES_ZIP_MAX_FILES=20000" >> "$FRESK_ROOT/config.conf"
  # PANEL_DOMAIN por variable de entorno si config lo tiene vacío
  if [[ -n "$PANEL_DOMAIN_IN" && -z "${PANEL_DOMAIN:-}" ]]; then
    if grep -q '^PANEL_DOMAIN=' "$FRESK_ROOT/config.conf"; then
      sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=${PANEL_DOMAIN_IN}|" "$FRESK_ROOT/config.conf"
    else
      echo "PANEL_DOMAIN=${PANEL_DOMAIN_IN}" >> "$FRESK_ROOT/config.conf"
    fi
  fi
fi

# shellcheck disable=SC1090,SC1091
source "$FRESK_ROOT/config.conf"
DB_PASS="$(<"$DB_PASS_FILE")"
DB_ADMIN_PASS="$(<"$DB_ADMIN_PASS_FILE")"
PHP_FPM_SOCK="${PHP_FPM_SOCK:-/run/php/php${PHP_VER}-fpm-fresk.sock}"

# --- 6. MariaDB ---
logi "Configurando MariaDB..."
systemctl enable --now mariadb
# bind-address
if grep -qE '^\s*bind-address' /etc/mysql/mariadb.conf.d/*.cnf 2>/dev/null || grep -qE '^\s*bind-address' /etc/mysql/my.cnf 2>/dev/null; then
  sed -i 's/^\s*bind-address.*/bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf 2>/dev/null || true
else
  mkdir -p /etc/mysql/mariadb.conf.d
  cat > /etc/mysql/mariadb.conf.d/60-fresk-bind.cnf << 'MYCNF'
[mysqld]
bind-address = 127.0.0.1
MYCNF
fi
systemctl restart mariadb

mysql -u root << SQLEOF
CREATE DATABASE IF NOT EXISTS fresk CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'fresk_panel'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER 'fresk_panel'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT, INSERT, UPDATE, DELETE ON fresk.* TO 'fresk_panel'@'127.0.0.1';
CREATE USER IF NOT EXISTS 'fresk_admin'@'127.0.0.1' IDENTIFIED BY '${DB_ADMIN_PASS}';
ALTER USER 'fresk_admin'@'127.0.0.1' IDENTIFIED BY '${DB_ADMIN_PASS}';
GRANT ALL PRIVILEGES ON fresk.* TO 'fresk_admin'@'127.0.0.1';
-- Privilegios de mantenimiento para BD de sitios (fase 6). Sin SUPER/FILE/SHUTDOWN.
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, REFERENCES, INDEX, ALTER,
  CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW,
  CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER, CREATE USER, RELOAD
  ON *.* TO 'fresk_admin'@'127.0.0.1' WITH GRANT OPTION;
-- Patrón para BD de sitios (db_*); permite GRANT a usuarios de sitio
GRANT ALL PRIVILEGES ON \`db\\_%\`.* TO 'fresk_admin'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQLEOF
mysql -u root fresk < "$FRESK_ROOT/sql/schema.sql"
mysql -u root fresk < "$FRESK_ROOT/sql/seed.sql" || true
logi "Esquema fresk aplicado"

# Admin inicial del panel: solo si no hay ninguno (idempotente). La contraseña cumple la política
# (mayúscula, minúscula, número, símbolo, >= 8) y se guarda en var/.panel_admin_pass (600 root), nunca en logs.
ADMIN_COUNT="$(mysql -u root -N -B fresk -e 'SELECT COUNT(*) FROM admins;' 2>/dev/null || echo 1)"
if [[ "${ADMIN_COUNT//[^0-9]/}" == "0" ]]; then
  rnd() { tr -dc "$1" </dev/urandom | head -c "$2" || true; }
  PANEL_ADMIN_PASS="$(gen_password)$(rnd 'A-Z' 1)$(rnd 'a-z' 1)$(rnd '0-9' 1)$(rnd '!#%+=@' 1)"
  PANEL_ADMIN_HASH="$(printf '%s' "$PANEL_ADMIN_PASS" | "php${PHP_VER}" -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_DEFAULT);' 2>/dev/null \
    || printf '%s' "$PANEL_ADMIN_PASS" | php -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_DEFAULT);')"
  mysql -u root fresk -e "INSERT INTO admins (username, password_hash, active, language) VALUES ('admin', '${PANEL_ADMIN_HASH}', 1, 'es');"
  umask 077
  printf '%s\n' "$PANEL_ADMIN_PASS" > "$FRESK_ROOT/var/.panel_admin_pass"
  umask 022
  chown root:root "$FRESK_ROOT/var/.panel_admin_pass"; chmod 600 "$FRESK_ROOT/var/.panel_admin_pass"
  unset PANEL_ADMIN_PASS PANEL_ADMIN_HASH
  logi "Admin del panel creado: usuario 'admin'; contraseña en $FRESK_ROOT/var/.panel_admin_pass (cámbiala en Usuarios)"
fi

# --- 7. PHP-FPM: pool del panel (usuario flesk). Cada dominio tiene el suyo (flesk-<dominio>, usuario fk_<dominio>) ---
install -d -m 700 -o flesk -g flesk "$FRESK_ROOT/var/sessions" "$FRESK_ROOT/var/tmp"
POOL_DEST="/etc/php/${PHP_VER}/fpm/pool.d/flesk-panel.conf"
render_template "$FRESK_ROOT/templates/php-fpm-panel-pool.conf" "$POOL_DEST" \
  "PANEL_USER=flesk" "PANEL_FPM_SOCK=${PANEL_FPM_SOCK:-/run/php/flesk-panel.sock}" "WEB_USER=www-data" "FRESK_ROOT=$FRESK_ROOT"
chmod 644 "$POOL_DEST"
"php-fpm${PHP_VER}" -t || diei 5 "php-fpm -t falló con el pool del panel"
# El pool compartido antiguo (fresk, www-data) se retira al final, cuando ningún vhost lo usa (paso 16)
systemctl enable "php${PHP_VER}-fpm"
# Recarga elegante: los workers terminan la petición en curso (Configuración/IA recargan PHP-FPM desde el panel)
sed -i -E 's/^;?process_control_timeout = .*/process_control_timeout = 60s/' "/etc/php/${PHP_VER}/fpm/php-fpm.conf" || true
systemctl restart "php${PHP_VER}-fpm"

# --- 8. Nginx ---
mkdir -p /etc/nginx/fresk-enabled
# Quitar default site si existe y choca con default_server
if [[ -L /etc/nginx/sites-enabled/default ]]; then
  backup_file /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/sites-enabled/default
fi
# Include fresk-enabled
if ! grep -q 'fresk-enabled' /etc/nginx/nginx.conf 2>/dev/null; then
  # Mejor: fichero en conf.d
  :
fi
cat > /etc/nginx/conf.d/fresk.conf << 'NGX'
include /etc/nginx/fresk-enabled/*.conf;
NGX

mkdir -p /etc/nginx/fresk-panel/_default
# Solo se crea en la primera pasada; después lo gestiona "flesk panel ssl" (paso 14c)
if [[ ! -f /etc/nginx/fresk-enabled/00-panel.conf ]]; then
  render_template "$FRESK_ROOT/templates/nginx-panel-server.conf" \
    /etc/nginx/fresk-enabled/00-panel.conf \
    "PUBLIC_IP=${PUBLIC_IP:-0.0.0.0}" 'PANEL_HTTPS_ORIGIN=https://$host'
fi

# Web stub
mkdir -p "$FRESK_ROOT/web/public" "$FRESK_ROOT/web/assets"
if [[ ! -f "$FRESK_ROOT/web/public/index.php" ]]; then
  cat > "$FRESK_ROOT/web/public/index.php" << 'PHPEOF'
<?php
header('Content-Type: text/html; charset=utf-8');
?><!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Flesk</title>
  <style>
    body{font-family:system-ui,sans-serif;background:#F7F8FB;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center}
    .card{background:#fff;padding:2rem 2.5rem;border-radius:12px;box-shadow:0 4px 24px rgba(40,47,77,.08);max-width:420px}
    h1{color:#282F4D;margin:0 0 .5rem}
    p{color:#555;line-height:1.5}
    .badge{display:inline-block;background:#282F4D;color:#fff;padding:.2rem .6rem;border-radius:4px;font-size:.85rem}
  </style>
</head>
<body>
  <div class="card">
    <span class="badge">Flesk</span>
    <h1>Panel listo</h1>
    <p>Instalación base OK. La UI Bootstrap (fase 8) llegará aquí.
       Ahora opera con <code>flesk status</code> por SSH.</p>
    <p><small>Ruta: /flesk · LE del panel espera dominio real · ADMIN_EMAIL placeholder</small></p>
  </div>
</body>
</html>
PHPEOF
fi
chown -R root:flesk "$FRESK_ROOT/web"
chmod -R u=rwX,g=rX,o=rX "$FRESK_ROOT/web"
# rc3: www-data (nginx) ya no lee secretos del panel; solo el usuario flesk (pool del panel)
if id www-data >/dev/null 2>&1 && id -nG www-data | tr ' ' '\n' | grep -qx fresk; then
  gpasswd -d www-data fresk >/dev/null || true
fi

nginx -t || diei 5 "nginx -t falló"
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx

# --- 9. Postfix (sin open relay) ---
logi "Configurando Postfix (sin open relay)..."
mkdir -p /etc/postfix/fresk
render_template "$FRESK_ROOT/templates/postfix-mysql-domains.cf" \
  /etc/postfix/fresk/virtual-domains.cf \
  "DB_USER=fresk_panel" "DB_PASSWORD=$DB_PASS" "DB_NAME=fresk"
render_template "$FRESK_ROOT/templates/postfix-mysql-mailboxes.cf" \
  /etc/postfix/fresk/virtual-mailboxes.cf \
  "DB_USER=fresk_panel" "DB_PASSWORD=$DB_PASS" "DB_NAME=fresk"
render_template "$FRESK_ROOT/templates/postfix-mysql-aliases.cf" \
  /etc/postfix/fresk/virtual-aliases.cf \
  "DB_USER=fresk_panel" "DB_PASSWORD=$DB_PASS" "DB_NAME=fresk"
if [[ -f "$FRESK_ROOT/templates/postfix-mysql-sender-login.cf" ]]; then
  render_template "$FRESK_ROOT/templates/postfix-mysql-sender-login.cf" \
    /etc/postfix/fresk/sender-login.cf \
    "DB_USER=fresk_panel" "DB_PASSWORD=$DB_PASS" "DB_NAME=fresk"
fi
chmod 640 /etc/postfix/fresk/*.cf
chown root:postfix /etc/postfix/fresk/*.cf

postconf -e "inet_interfaces = all"
postconf -e "mydestination = localhost"
postconf -e "mynetworks = 127.0.0.0/8 [::1]/128"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination"
postconf -e "virtual_mailbox_domains = mysql:/etc/postfix/fresk/virtual-domains.cf"
postconf -e "virtual_mailbox_maps = mysql:/etc/postfix/fresk/virtual-mailboxes.cf"
postconf -e "virtual_alias_maps = mysql:/etc/postfix/fresk/virtual-aliases.cf"
postconf -e "virtual_mailbox_base = /var/vmail"
postconf -e "virtual_uid_maps = static:5000"
postconf -e "virtual_gid_maps = static:5000"
postconf -e "virtual_minimum_uid = 5000"
# SASL solo en submission (587); puerto 25 sin AUTH a internet
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = no"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_tls_security_level = may"
if [[ -f /etc/ssl/certs/ssl-cert-snakeoil.pem ]]; then
  postconf -e "smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem"
  postconf -e "smtpd_tls_key_file = /etc/ssl/private/ssl-cert-snakeoil.key"
fi
if [[ -f /etc/postfix/fresk/sender-login.cf ]]; then
  postconf -e "smtpd_sender_login_maps = mysql:/etc/postfix/fresk/sender-login.cf"
fi

# Submission 587 con SASL Dovecot (bloque marcado, idempotente)
MASTER_CF=/etc/postfix/master.cf
backup_file "$MASTER_CF"
if grep -q 'BEGIN FLESK SUBMISSION' "$MASTER_CF" 2>/dev/null; then
  # Quitar bloque anterior
  sed -i '/# BEGIN FLESK SUBMISSION/,/# END FLESK SUBMISSION/d' "$MASTER_CF"
fi
cat >> "$MASTER_CF" << 'MASTEREOF'

# BEGIN FLESK SUBMISSION
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=dovecot
  -o smtpd_sasl_path=private/auth
  -o smtpd_sasl_security_options=noanonymous
  -o smtpd_tls_auth_only=yes
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
# END FLESK SUBMISSION
MASTEREOF

postfix check || logi "AVISO: postfix check con avisos"
systemctl enable postfix
systemctl restart postfix

# --- 10. Dovecot ---
logi "Configurando Dovecot..."
mkdir -p /etc/dovecot/fresk
DOVECOT_VER="$(dovecot --version 2>/dev/null | awk '{print $1}')"
DOVECOT_MAJOR="$(printf '%s' "$DOVECOT_VER" | cut -d. -f1)"
DOVECOT_MINOR="$(printf '%s' "$DOVECOT_VER" | cut -d. -f2)"
logi "Dovecot $DOVECOT_VER"

# Escapar password para config (sin comillas rotas)
DB_PASS_ESC="${DB_PASS//'\\'/\\\\}"
DB_PASS_ESC="${DB_PASS_ESC//\"/\\\"}"

# Desactivar auth de sistema (PAM): solo SQL virtual
if [[ -f /etc/dovecot/conf.d/10-auth.conf ]]; then
  sed -i 's/^!include auth-system.conf.ext/# !include auth-system.conf.ext (disabled by flesk)/' \
    /etc/dovecot/conf.d/10-auth.conf || true
  if ! grep -qE '^auth_mechanisms\s*=' /etc/dovecot/conf.d/10-auth.conf; then
    echo 'auth_mechanisms = plain login' >> /etc/dovecot/conf.d/10-auth.conf
  else
    sed -i 's/^#*auth_mechanisms\s*=.*/auth_mechanisms = plain login/' /etc/dovecot/conf.d/10-auth.conf || true
  fi
fi

if [[ "${DOVECOT_MAJOR:-2}" -ge 2 && "${DOVECOT_MINOR:-0}" -ge 4 ]] || [[ "${DOVECOT_MAJOR:-0}" -ge 3 ]]; then
  # Dovecot 2.4+: maildir relativo en DB → home absoluto /var/vmail/...
  cat > /etc/dovecot/conf.d/99-fresk.conf << DOVEOF
protocols = imap pop3 lmtp
mail_driver = maildir
mail_path = ~/
# El 10-mail.conf de Ubuntu fija INBOX en /var/mail/%{user} (mbox): con maildir el INBOX es la raíz
mail_inbox_path = ~/
first_valid_uid = 5000
mail_uid = 5000
mail_gid = 5000

sql_driver = mysql
mysql 127.0.0.1 {
  user = fresk_panel
  password = ${DB_PASS_ESC}
  dbname = fresk
}

passdb sql {
  default_password_scheme = SHA512-CRYPT
  query = SELECT email AS user, password FROM v_virtual_mailboxes WHERE email='%{user}' AND active=1
}
userdb sql {
  query = SELECT CONCAT(IF(maildir LIKE '/%', TRIM(TRAILING '/' FROM maildir), CONCAT('/var/vmail/', TRIM(BOTH '/' FROM maildir))), '/flesk') AS home, 5000 AS uid, 5000 AS gid, concat('*:bytes=', quota) AS quota_rule, 'maildir' AS mail_driver, CONCAT(IF(maildir LIKE '/%', TRIM(TRAILING '/' FROM maildir), CONCAT('/var/vmail/', TRIM(BOTH '/' FROM maildir))), '/') AS mail_path, CONCAT(IF(maildir LIKE '/%', TRIM(TRAILING '/' FROM maildir), CONCAT('/var/vmail/', TRIM(BOTH '/' FROM maildir))), '/') AS mail_inbox_path FROM v_virtual_mailboxes WHERE email='%{user}' AND active=1
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
DOVEOF
  if [[ -f /etc/dovecot/conf.d/10-mail.conf ]]; then
    sed -i 's/^mail_driver = mbox/# mail_driver = mbox (overridden by 99-fresk)/' /etc/dovecot/conf.d/10-mail.conf || true
  fi
  # Entrega local por LMTP + Sieve/Pigeonhole (contestador automático "flesk mail vacation")
  cat > /etc/dovecot/conf.d/99-fresk-sieve.conf << 'SIEVEEOF'
# Flesk: entrega local por LMTP (Postfix virtual_transport) con Sieve/Pigeonhole para el contestador automático (vacation)
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
protocol lmtp {
  # Los buzones son direcciones completas (20-lmtp.conf de Ubuntu quita el dominio)
  auth_username_format = %{user | lower}
  mail_plugins {
    sieve = yes
  }
}
# Script personal de cada buzón: ~/sieve/*.sieve, activo en ~/.dovecot.sieve (lo gestiona "flesk mail vacation")
# El home de Dovecot es <maildir>/flesk (no la raíz del Maildir++, donde .dovecot.sieve o .dovecot.lda-dupes aparecerían como carpetas IMAP)
sieve_script personal {
  driver = file
  path = ~/sieve
  active_path = ~/.dovecot.sieve
}
# Contestador: como mucho una respuesta al día por remitente; vale también para correo recibido por alias
sieve_vacation_min_period = 1d
sieve_vacation_default_period = 1d
sieve_vacation_use_original_recipient = yes
sieve_vacation_send_from_recipient = yes
SIEVEEOF
  cat > /etc/dovecot/fresk/dovecot-sql.conf << SQLEOF
# Legacy 2.3 format — no usado en Dovecot ${DOVECOT_VER}. Ver 99-fresk.conf
driver = mysql
connect = host=127.0.0.1 dbname=fresk user=fresk_panel password=***
SQLEOF
else
  render_template "$FRESK_ROOT/templates/dovecot-sql.conf" \
    /etc/dovecot/fresk/dovecot-sql.conf \
    "DB_USER=fresk_panel" "DB_PASSWORD=$DB_PASS" "DB_NAME=fresk" \
    "VMAIL_UID=5000" "VMAIL_GID=5000"
  cat > /etc/dovecot/conf.d/99-fresk.conf << 'DOVEOF'
protocols = imap pop3
mail_location = maildir:~/
first_valid_uid = 5000
mail_uid = 5000
mail_gid = 5000

passdb {
  driver = sql
  args = /etc/dovecot/fresk/dovecot-sql.conf
}
userdb {
  driver = sql
  args = /etc/dovecot/fresk/dovecot-sql.conf
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
DOVEOF
  cat > /etc/dovecot/conf.d/99-fresk-sieve.conf << 'SIEVEEOF'
# Flesk: entrega local por LMTP (Postfix virtual_transport) con Sieve/Pigeonhole para el contestador automático (vacation)
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
protocol lmtp {
  postmaster_address = postmaster@%d
  auth_username_format = %Lu
  mail_plugins = $mail_plugins sieve
}
plugin {
  sieve = file:~/sieve;active=~/.dovecot.sieve
  sieve_vacation_min_period = 1d
  sieve_vacation_default_period = 1d
  sieve_vacation_use_original_recipient = yes
  sieve_vacation_send_from_recipient = yes
}
SIEVEEOF
fi
chmod 644 /etc/dovecot/conf.d/99-fresk-sieve.conf
chmod 640 /etc/dovecot/fresk/dovecot-sql.conf /etc/dovecot/conf.d/99-fresk.conf
chown root:dovecot /etc/dovecot/fresk/dovecot-sql.conf
chown root:root /etc/dovecot/conf.d/99-fresk.conf
doveconf -n >/dev/null || diei 5 "doveconf falló"
systemctl enable dovecot
systemctl restart dovecot
# Postfix entrega los buzones virtuales a Dovecot por LMTP (necesario para Sieve: contestador automático).
# Se hace tras arrancar Dovecot para que el socket private/dovecot-lmtp ya exista.
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
systemctl reload postfix || systemctl restart postfix
# Regenerar los scripts Sieve de los contestadores guardados en la BD (reinstalación/actualización)
php "$FRESK_ROOT/lib/mail-vacation.php" sync >/dev/null 2>&1 || logi "AVISO: flesk mail vacation sync falló"

# --- 11. BIND (includes; recursion off; listen según DNS_PUBLIC) ---
mkdir -p /etc/bind/fresk
chown root:bind /etc/bind/fresk 2>/dev/null || true
chmod 775 /etc/bind/fresk 2>/dev/null || true
if [[ ! -f /etc/bind/named.conf.fresk ]]; then
  cp "$FRESK_ROOT/templates/named.conf.fresk" /etc/bind/named.conf.fresk
  chown root:bind /etc/bind/named.conf.fresk 2>/dev/null || true
fi
if ! grep -q 'named.conf.fresk' /etc/bind/named.conf 2>/dev/null; then
  backup_file /etc/bind/named.conf
  echo 'include "/etc/bind/named.conf.fresk";' >> /etc/bind/named.conf
fi
# Opciones endurecidas (recursion no). Respeta DNS_PUBLIC para listen-on.
if [[ -f "$FRESK_ROOT/templates/named.conf.options.fresk" ]]; then
  if [[ ! -f /etc/bind/named.conf.options ]] || ! grep -q 'fresk-listen-begin' /etc/bind/named.conf.options 2>/dev/null; then
    backup_file /etc/bind/named.conf.options 2>/dev/null || true
  fi
  cp "$FRESK_ROOT/templates/named.conf.options.fresk" /etc/bind/named.conf.options
  chown root:bind /etc/bind/named.conf.options 2>/dev/null || true
fi
# Ajuste listen tras conocer DNS_PUBLIC (plantilla = localhost; ampliar si público)
DNS_PUBLIC_EARLY="${DNS_PUBLIC:-no}"
if [[ -f "$FRESK_ROOT/config.conf" ]]; then
  # shellcheck disable=SC1090
  source "$FRESK_ROOT/config.conf"
  DNS_PUBLIC_EARLY="${DNS_PUBLIC:-no}"
fi
DNS_PUBLIC_EARLY="${DNS_PUBLIC_EARLY,,}"
if [[ "$DNS_PUBLIC_EARLY" == "yes" || "$DNS_PUBLIC_EARLY" == "true" || "$DNS_PUBLIC_EARLY" == "1" ]]; then
  awk '
    /fresk-listen-begin/ {print; print "\tlisten-on port 53 { any; };"; print "\tlisten-on-v6 port 53 { any; };"; skip=1; next}
    /fresk-listen-end/ {skip=0}
    skip {next}
    {print}
  ' /etc/bind/named.conf.options > /etc/bind/named.conf.options.tmp \
    && mv /etc/bind/named.conf.options.tmp /etc/bind/named.conf.options
  logi "BIND: listen any (DNS_PUBLIC=$DNS_PUBLIC_EARLY)"
else
  logi "BIND: listen solo localhost (DNS_PUBLIC=$DNS_PUBLIC_EARLY)"
fi
named-checkconf || logi "AVISO: named-checkconf"
systemctl enable bind9 || systemctl enable named || true
systemctl restart bind9 2>/dev/null || systemctl restart named 2>/dev/null || true

# --- 12. UFW ---
logi "UFW..."
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 25/tcp
ufw allow 587/tcp
ufw allow 993/tcp
ufw allow 995/tcp
# 53 solo si DNS_PUBLIC=yes (fase 5)
DNS_PUBLIC_VAL="${DNS_PUBLIC:-no}"
# Preferir valor ya escrito en config.conf
if [[ -f "$FRESK_ROOT/config.conf" ]]; then
  # shellcheck disable=SC1090
  source "$FRESK_ROOT/config.conf"
  DNS_PUBLIC_VAL="${DNS_PUBLIC:-no}"
fi
DNS_PUBLIC_VAL="${DNS_PUBLIC_VAL,,}"
if [[ "$DNS_PUBLIC_VAL" == "yes" || "$DNS_PUBLIC_VAL" == "true" || "$DNS_PUBLIC_VAL" == "1" ]]; then
  ufw allow 53/tcp
  ufw allow 53/udp
  logi "UFW: 53/tcp+udp abiertos (DNS_PUBLIC=$DNS_PUBLIC_VAL)"
else
  logi "UFW: 53 cerrado (DNS_PUBLIC=$DNS_PUBLIC_VAL); dig @127.0.0.1"
fi
ufw --force enable
ufw status

# --- 12b. unattended-upgrades (no desactivar; verificar) ---
if dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
  systemctl enable unattended-upgrades >/dev/null 2>&1 || true
  systemctl start unattended-upgrades >/dev/null 2>&1 || true
  logi "unattended-upgrades: $(systemctl is-active unattended-upgrades 2>/dev/null || echo unknown)"
else
  logi "AVISO: paquete unattended-upgrades no instalado — recomiendo: apt-get install -y unattended-upgrades"
fi

# --- 13. Fail2ban ---
systemctl enable --now fail2ban
cat > /etc/fail2ban/jail.d/fresk.conf << 'F2B'
[sshd]
enabled = true

[postfix]
enabled = true

[dovecot]
enabled = true
F2B
systemctl restart fail2ban

# --- 14. Cron / logrotate ---
cp "$FRESK_ROOT/templates/logrotate-fresk" /etc/logrotate.d/fresk
# Renovación LE vía flesk ssl renew (certbot + actualiza ssl_certs + reload)
CRON_FRESK="/etc/cron.d/fresk"
cat > "$CRON_FRESK" << 'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Renovación diaria Let's Encrypt (fase 3)
0 3 * * * root /opt/flesk/bin/flesk ssl renew >/dev/null 2>&1
CRON
chmod 644 "$CRON_FRESK"
# SGBD: credenciales efímeras de Adminer ("Abrir" sin contraseña) — purga de las caducadas cada 10 min
install -m 644 "$FRESK_ROOT/templates/flesk-sgbd-purge.service" /etc/systemd/system/flesk-sgbd-purge.service
install -m 644 "$FRESK_ROOT/templates/flesk-sgbd-purge.timer" /etc/systemd/system/flesk-sgbd-purge.timer
systemctl daemon-reload
systemctl enable --now flesk-sgbd-purge.timer >/dev/null 2>&1 || logi "AVISO: no se pudo activar flesk-sgbd-purge.timer"


# --- 14b. OpenSSH SFTP chroot (fase 7) ---
if ! getent group sftponly >/dev/null; then
  groupadd --system sftponly
  logi "Grupo sftponly creado"
fi
SSHD_DROPIN_SRC="$FRESK_ROOT/templates/sshd-fresk.conf"
SSHD_DROPIN_DST="/etc/ssh/sshd_config.d/fresk.conf"
if [[ -f "$SSHD_DROPIN_SRC" ]]; then
  mkdir -p /etc/ssh/sshd_config.d
  TMP_SSHD="$(mktemp)"
  cp "$SSHD_DROPIN_SRC" "$TMP_SSHD"
  # Instalar provisionalmente para sshd -t
  if [[ -f "$SSHD_DROPIN_DST" ]]; then
    cp -a "$SSHD_DROPIN_DST" "${SSHD_DROPIN_DST}.bak.fresk" 2>/dev/null || true
  fi
  atomic_install "$TMP_SSHD" "$SSHD_DROPIN_DST" 644 root:root
  rm -f "$TMP_SSHD"
  if sshd -t 2>/tmp/fresk-sshd-t.err; then
    if systemctl is-active --quiet ssh 2>/dev/null; then
      systemctl reload ssh || systemctl reload sshd || true
    elif systemctl is-active --quiet sshd 2>/dev/null; then
      systemctl reload sshd || true
    fi
    logi "sshd drop-in SFTP instalado y recargado ($SSHD_DROPIN_DST)"
    rm -f "${SSHD_DROPIN_DST}.bak.fresk"
  else
    logi "ERROR: sshd -t falló; se revierte drop-in SFTP (NO se recarga SSH)"
    cat /tmp/fresk-sshd-t.err >&2 || true
    if [[ -f "${SSHD_DROPIN_DST}.bak.fresk" ]]; then
      mv -f "${SSHD_DROPIN_DST}.bak.fresk" "$SSHD_DROPIN_DST"
    else
      rm -f "$SSHD_DROPIN_DST"
    fi
    diei 5 "sshd -t rechazó el drop-in SFTP; SSH intacto"
  fi
else
  logi "WARN: falta $SSHD_DROPIN_SRC — SFTP chroot no configurado"
fi

# --- 14c. HTTPS del panel ---
# Con PANEL_DOMAIN que resuelve a la IP: Let's Encrypt (webroot) + redirección http→https.
# Sin dominio (o si LE falla): certificado autofirmado para la IP (https://IP/flesk/, aviso del navegador).
# Cambiar después a un dominio real: flesk panel ssl <dominio>
if [[ -n "${PANEL_DOMAIN:-}" ]]; then
  if ! bash "$FRESK_ROOT/scripts/panel-ssl.sh" "$PANEL_DOMAIN"; then
    logi "WARN: no se pudo activar Let's Encrypt para $PANEL_DOMAIN; se usa certificado autofirmado"
    bash "$FRESK_ROOT/scripts/panel-ssl.sh" --self-signed || logi "WARN: HTTPS del panel no configurado"
  fi
else
  bash "$FRESK_ROOT/scripts/panel-ssl.sh" --self-signed || logi "WARN: HTTPS del panel no configurado"
fi

# --- 15. sudoers ---
TMP_SUDO="$(mktemp)"
cp "$FRESK_ROOT/templates/sudoers-fresk" "$TMP_SUDO"
if visudo -cf "$TMP_SUDO"; then
  rm -f /etc/sudoers.d/fresk
  atomic_install "$TMP_SUDO" /etc/sudoers.d/flesk 440 root:root
else
  rm -f "$TMP_SUDO"
  diei 5 "visudo rechazó sudoers flesk"
fi
rm -f "$TMP_SUDO"

# Symlink CLI
ln -sfn "$FRESK_ROOT/bin/flesk" /usr/local/bin/flesk

# Permisos finales (rc3): código root:flesk (nunca un UID ajeno), secretos solo root/flesk, copias solo root
find "$FRESK_ROOT" -xdev -path "$FRESK_ROOT/var" -prune -o -exec chown -h root:flesk {} +
chown root:flesk "$FRESK_ROOT/config.conf"; chmod 640 "$FRESK_ROOT/config.conf"
chmod 750 "$FRESK_ROOT/var"
chown root:flesk "$FRESK_ROOT/var" "$FRESK_ROOT/var/log" "$FRESK_ROOT/var/run"
chmod 750 "$FRESK_ROOT/var/log" "$FRESK_ROOT/var/run"
chown root:root "$FRESK_ROOT/var/backups"; chmod 700 "$FRESK_ROOT/var/backups"
[[ -f "$FRESK_ROOT/var/.dbpass" ]] && { chown root:flesk "$FRESK_ROOT/var/.dbpass"; chmod 640 "$FRESK_ROOT/var/.dbpass"; }
[[ -f "$FRESK_ROOT/var/.dbadminpass" ]] && { chown root:root "$FRESK_ROOT/var/.dbadminpass"; chmod 600 "$FRESK_ROOT/var/.dbadminpass"; }
install -d -m 700 -o flesk -g flesk "$FRESK_ROOT/var/sessions" "$FRESK_ROOT/var/tmp"
[[ -d "$FRESK_ROOT/var/run/dl" ]] && chown -R flesk:flesk "$FRESK_ROOT/var/run/dl"
systemctl daemon-reload
# El pool del panel arranca con usuario flesk (sesiones en var/sessions 0700)
if "php-fpm${PHP_VER}" -t >/dev/null 2>"$FRESK_ROOT/var/run/php-fpm-t.err"; then systemctl reload "php${PHP_VER}-fpm" || systemctl restart "php${PHP_VER}-fpm"; else cat "$FRESK_ROOT/var/run/php-fpm-t.err" >&2; diei 5 "php-fpm -t falló"; fi

# Reglas nginx de aplicaciones instaladas (flesk app install) y copias previas a vaciados
install -d -m 755 /etc/nginx/fresk-apps
install -d -m 700 /var/backups/flesk
# Vhosts existentes: plantilla con reglas de servidor por aplicación y PHP con PATH_INFO
for vf in "${NGINX_ENABLED:-/etc/nginx/fresk-enabled}"/*.conf; do
  d="$(basename "$vf" .conf)"
  [[ "$d" == 0* || "$d" == *.webmail ]] && continue
  grep -q 'fresk-apps/.*/server/' "$vf" 2>/dev/null && continue
  # Dominios con vhost personalizado que no deben regenerarse (separados por espacios; p. ej. FLESK_RENDER_SKIP="panel.example.com"). Por defecto ninguno.
  [[ " ${FLESK_RENDER_SKIP:-} " == *" $d "* ]] && continue
  [[ "${FLESK_RENDER_VHOSTS:-1}" == "1" ]] && bash "$FRESK_ROOT/scripts/vhost-render.sh" "$d" >/dev/null 2>&1 || true
done

# OpenDKIM (milter de Postfix), Roundcube en webmail.<dominio> y certificados de correo
bash "$FRESK_ROOT/scripts/mail-stack-setup.sh" || logi "WARN: flesk mail setup falló (revisa el log)"

# --- 16. Aislamiento por dominio (rc3): usuario fk_<dominio> + pool propio para los dominios existentes ---
"$FRESK_ROOT/bin/flesk" domain isolate --all || logi "WARN: flesk domain isolate --all falló (revisa el log)"
# Retirar el pool compartido antiguo (www-data) y el pool www por defecto si ningún vhost los usa
for old in "/etc/php/${PHP_VER}/fpm/pool.d/fresk.conf:/run/php/php${PHP_VER}-fpm-fresk.sock" "/etc/php/${PHP_VER}/fpm/pool.d/www.conf:/run/php/php${PHP_VER}-fpm.sock"; do
  pf="${old%%:*}"; so="${old#*:}"
  [[ -f "$pf" ]] || continue
  if grep -rqs -- "$so" /etc/nginx/; then logi "AVISO: $so sigue en uso por nginx; se conserva $pf"; continue; fi
  mv -f "$pf" "${FRESK_ROOT}/var/backups/$(basename "$pf").disabled.$(date +%Y%m%d%H%M%S)"
done
if "php-fpm${PHP_VER}" -t >/dev/null 2>"$FRESK_ROOT/var/run/php-fpm-t.err"; then systemctl reload "php${PHP_VER}-fpm" || true; else cat "$FRESK_ROOT/var/run/php-fpm-t.err" >&2; logi "ERROR: php-fpm -t falla tras retirar pools antiguos"; fi

logi "==== Instalación completada ===="
if [[ -n "${PANEL_DOMAIN:-}" ]] && grep -q "PANEL_DOMAIN=${PANEL_DOMAIN}" "$FRESK_ROOT/config.conf" && [[ -f "/etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem" ]]; then
  logi "Panel: https://${PANEL_DOMAIN}/flesk/"
else
  logi "Panel: https://${PUBLIC_IP:-IP}/flesk/ (autofirmado; usa 'flesk panel ssl <dominio>' para un certificado válido)"
fi
logi "ADMIN_EMAIL=${ADMIN_EMAIL} (placeholder — LE del panel espera dominio real)"
logi "Prueba: flesk status"
"$FRESK_ROOT/bin/flesk" status || true
exit 0
