#!/usr/bin/env bash
# Flesk — comprobaciones de seguridad de paquetes descargados (sourceado por app-install.sh y pkg-install.sh)
#   sec_source_check <url> [sitio_oficial]   https, puerto 443, sin credenciales, host no acortador/compartición;
#                                            si se da sitio oficial: el host debe ser ese dominio (o subdominio)
#                                            o una forja/CDN de releases conocida (github, gitlab, codeberg, sourceforge…)
#   sec_av_scan <ruta>                       antivirus ClamAV (clamd si está activo; si no clamscan). Rechaza si hay positivos.
#   sec_pkg_check <archivo>                  zip/tar sin rutas absolutas, "..", enlaces ni especiales; límites (lib/pkg-check.php)
# shellcheck disable=SC2034

SEC_BLOCKED_HOSTS='(^|\.)(bit\.ly|tinyurl\.com|t\.co|goo\.gl|is\.gd|cutt\.ly|rb\.gy|shorturl\.at|mega\.nz|mega\.io|mediafire\.com|dropbox\.com|dropboxusercontent\.com|drive\.google\.com|docs\.google\.com|1drv\.ms|onedrive\.live\.com|wetransfer\.com|we\.tl|transfer\.sh|file\.io|anonfiles\.com|gofile\.io|pastebin\.com|paste\.ee|hastebin\.com|ghostbin\.com|sendspace\.com|zippyshare\.com|4shared\.com|rapidgator\.net|uploaded\.net|ngrok\.io|ngrok-free\.app|trycloudflare\.com|duckdns\.org|no-ip\.org|ddns\.net)$'
# Forjas y CDN de releases oficiales admitidas además del dominio del proyecto
SEC_FORGE_HOSTS='^(github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com|codeload\.github\.com|gitlab\.com|codeberg\.org|bitbucket\.org|downloads\.sourceforge\.net|sourceforge\.net|master\.dl\.sourceforge\.net|[a-z0-9-]+\.dl\.sourceforge\.net|registry\.npmjs\.org|files\.pythonhosted\.org|repo\.packagist\.org|getcomposer\.org|ftp\.drupal\.org|downloads\.wordpress\.org|wordpress\.org)$'

sec_url_host() { printf '%s' "$1" | sed -E 's#^https://([^/:?\#]+).*#\1#' | tr 'A-Z' 'a-z'; }

sec_source_check() {
  local url="$1" official="${2:-}" host ohost
  [[ "$url" =~ ^https://[A-Za-z0-9.-]+(/[^[:space:]]*)?$ ]] || { echo "RECHAZADO: la URL debe ser https:// sin puerto ni credenciales"; return 5; }
  host="$(sec_url_host "$url")"
  [[ "$host" =~ \. && ! "$host" =~ ^[0-9.]+$ ]] || { echo "RECHAZADO: host inválido o IP literal ($host)"; return 5; }
  if [[ "$host" =~ $SEC_BLOCKED_HOSTS ]]; then echo "RECHAZADO: $host es un acortador o servicio de compartición de archivos, no una fuente oficial"; return 5; fi
  if [[ -n "$official" ]]; then
    ohost="$(sec_url_host "https://${official#https://}")"; ohost="${ohost#www.}"
    [[ "$ohost" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || { echo "RECHAZADO: sitio oficial inválido"; return 5; }
    if [[ "$host" == "$ohost" || "$host" == *".$ohost" ]]; then echo "OK fuente=https host=$host oficial=$ohost (mismo dominio)"; return 0; fi
    if [[ "$host" =~ $SEC_FORGE_HOSTS ]]; then echo "OK fuente=https host=$host oficial=$ohost (forja/CDN de releases conocida)"; return 0; fi
    echo "RECHAZADO: el host de descarga ($host) no pertenece al sitio oficial ($ohost) ni a una forja de releases conocida"; return 5
  fi
  echo "OK fuente=https host=$host"; return 0
}

sec_av_scan() {
  local path="$1" out rc
  if ! command -v clamscan >/dev/null 2>&1; then
    if [[ "${FLESK_AV_AUTOINSTALL:-1}" == "1" ]] && command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -q clamav clamav-daemon clamav-freshclam >/dev/null 2>&1 || true
      systemctl enable --now clamav-freshclam >/dev/null 2>&1 || true
    fi
  fi
  command -v clamscan >/dev/null 2>&1 || { echo "RECHAZADO: ClamAV no está instalado (apt install clamav clamav-daemon)"; return 5; }
  ls /var/lib/clamav/*.c[vl]d >/dev/null 2>&1 || { freshclam --quiet >/dev/null 2>&1 || true; }
  ls /var/lib/clamav/*.c[vl]d >/dev/null 2>&1 || { echo "RECHAZADO: ClamAV sin firmas (freshclam)"; return 5; }
  set +e
  if command -v clamdscan >/dev/null 2>&1 && systemctl is-active --quiet clamav-daemon && [[ -S /run/clamav/clamd.ctl || -S /var/run/clamav/clamd.ctl ]]; then
    out="$(timeout 1800 clamdscan --fdpass --multiscan --infected --no-summary "$path" 2>&1)"; rc=$?
    ENGINE="clamd $(clamdscan --version 2>/dev/null | cut -d/ -f1-2)"
  else
    out="$(timeout 1800 nice clamscan -r --infected --no-summary --max-filesize=200M --max-scansize=800M --max-files=200000 --max-recursion=30 "$path" 2>&1)"; rc=$?
    ENGINE="$(clamscan --version 2>/dev/null | cut -d/ -f1-2)"
  fi
  set -e
  case "$rc" in
    0) echo "OK antivirus=limpio motor=${ENGINE}"; return 0 ;;
    1) echo "RECHAZADO: ClamAV detectó malware:"; printf '%s\n' "$out" | grep -E 'FOUND$' | sed "s#$path/##" | head -20; return 6 ;;
    *) echo "RECHAZADO: error del antivirus (rc=$rc): $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; return 5 ;;
  esac
}

sec_pkg_check() {
  php "$FRESK_ROOT/lib/pkg-check.php" "$1" "${2:-200000}" "${3:-4294967296}"
}

# Extrae un paquete ya comprobado en <destino>; formato por firma (zip/tar gz|xz|bz2)
sec_extract() {
  local f="$1" dest="$2" info
  info="$(sec_pkg_check "$f")" || return 5
  if [[ "$info" == *"format=zip"* ]]; then
    unzip -q -o "$f" -d "$dest" || return 5
  else
    local fl; fl="$(printf '%s' "$info" | sed -n 's/.*tarflag=\([zjJ]\).*/\1/p')"
    tar -x"${fl:-z}"f "$f" -C "$dest" --no-same-owner --no-same-permissions || return 5
  fi
  # Nada de enlaces ni especiales tras extraer (defensa en profundidad)
  if find "$dest" \( -type l -o -type p -o -type s -o -type b -o -type c \) -print -quit | grep -q .; then return 5; fi
  printf '%s' "$info"
}
