#!/usr/bin/env bash
# Flesk — helpers DNS/BIND (fase 5). Sourcear después de common.sh
# shellcheck disable=SC2034

BIND_ZONES="${BIND_ZONES:-/etc/bind/fresk}"
BIND_NAMED_FRESK="${BIND_NAMED_FRESK:-/etc/bind/named.conf.fresk}"
DNS_TTL_DEFAULT="${DNS_TTL_DEFAULT:-3600}"

dns_valid_type() {
  local t="${1^^}"
  case "$t" in
    A|AAAA|CNAME|MX|TXT|NS) printf '%s' "$t"; return 0 ;;
    *) return 1 ;;
  esac
}

# Host relativo: @ o etiqueta(s) sin punto final ni caracteres peligrosos
dns_valid_host() {
  local h="${1:-@}"
  h="${h,,}"
  h="${h%.}"
  if [[ -z "$h" || "$h" == "@" ]]; then
    printf '@'
    return 0
  fi
  if [[ "$h" =~ [\;\{\}] || "$h" =~ $'\n' || "$h" =~ $'\r' ]]; then
    return 1
  fi
  # wildcard * o etiquetas DNS / _
  if [[ ! "$h" =~ ^(\*|([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?))(\.([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?))*$ ]]; then
    return 1
  fi
  if [[ ${#h} -gt 253 ]]; then return 1; fi
  printf '%s' "$h"
  return 0
}

dns_sanitize_value() {
  local v="$1" typ="${2:-}"
  # En TXT el valor va entrecomillado y escapado: ';' es legítimo (SPF/DKIM/DMARC)
  if [[ "$typ" == "TXT" ]]; then
    if [[ "$v" =~ [\{\}] || "$v" =~ $'\n' || "$v" =~ $'\r' ]]; then return 1; fi
  elif [[ "$v" =~ [\;\{\}] || "$v" =~ $'\n' || "$v" =~ $'\r' ]]; then
    return 1
  fi
  if [[ ${#v} -gt 1024 ]]; then return 1; fi
  printf '%s' "$v"
  return 0
}

dns_valid_value_for_type() {
  local typ="$1" val="$2"
  case "$typ" in
    A)
      [[ "$val" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
      ;;
    AAAA)
      [[ "$val" =~ ^[0-9a-fA-F:]+$ && "$val" == *:* ]] || return 1
      ;;
    MX)
      if [[ "$val" =~ ^[0-9]+[[:space:]]+[^[:space:]].* ]]; then
        local pri="${val%% *}"
        (( pri >= 0 && pri <= 65535 )) || return 1
      else
        [[ -n "$val" ]] || return 1
      fi
      ;;
    NS|CNAME)
      [[ -n "$val" ]] || return 1
      ;;
    TXT) : ;;
  esac
  return 0
}

dns_sql_escape() {
  printf '%s' "$1" | sed "s/'/\\\\'/g"
}

dns_ensure_fqdn() {
  local t="$1"
  [[ "$t" == *. ]] && { printf '%s' "$t"; return; }
  printf '%s.' "$t"
}

# Escribe zona BIND desde dns_records (+ SOA). No recarga.
dns_write_zone_file() {
  local domain="$1"
  local zone_file="${2:-$BIND_ZONES/db.$domain}"
  local ttl="${DNS_TTL_DEFAULT}"
  # Serial YYYYMMDDNN estrictamente creciente respecto a la zona publicada
  local serial old_serial
  serial="$(date '+%Y%m%d')00"
  old_serial="$(awk '/; serial/{print $1; exit}' "$zone_file" 2>/dev/null || true)"
  if [[ "$old_serial" =~ ^[0-9]{10}$ ]] && (( old_serial >= serial )); then
    serial=$((old_serial + 1))
  fi

  # Buzón SOA: hostmaster.<dominio> salvo ADMIN_EMAIL real
  local admin_email="${ADMIN_EMAIL:-}"
  local soa_mbox
  if [[ -z "$admin_email" || "$admin_email" =~ @(localhost|local)$ ]]; then
    soa_mbox="hostmaster.${domain}."
  else
    soa_mbox="$(printf '%s' "${admin_email%%@*}" | sed 's/\./\\./g').${admin_email#*@}."
  fi

  mkdir -p "$BIND_ZONES" "$FRESK_RUN"
  local tmp records_tmp txt_out rest chunk esc name ttl_use pri mxhost typ host value rttl
  tmp="$(mktemp "$FRESK_RUN/zone.XXXXXX")"
  records_tmp="$(mktemp "$FRESK_RUN/zrec.XXXXXX")"

  # Separador 0x1f: evita que value vacío colapse columnas en mysql -B
  mysql_q -e "
    SELECT CONCAT(type, 0x1f, host, 0x1f, value, 0x1f, ttl) FROM dns_records
    WHERE domain_id = (SELECT id FROM domains WHERE name='$(dns_sql_escape "$domain")' LIMIT 1)
    ORDER BY FIELD(type,'NS','A','AAAA','MX','CNAME','TXT'), host, value;
  " > "$records_tmp"

  {
    echo "; Zona generada por Flesk — no editar a mano"
    echo "; Dominio: $domain"
    echo "\$TTL $ttl"
    printf '@\tIN\tSOA\tns1.%s. %s (\n' "$domain" "$soa_mbox"
    printf '\t\t\t%s\t; serial\n' "$serial"
    echo -e '\t\t\t3600\t\t; refresh'
    echo -e '\t\t\t900\t\t; retry'
    echo -e '\t\t\t604800\t\t; expire'
    echo -e '\t\t\t3600\t\t; minimum'
    echo -e '\t\t\t)\n'

    while IFS=$'\x1f' read -r typ host value rttl; do
      [[ -n "${typ:-}" ]] || continue
      name="$host"
      ttl_use="${rttl:-$ttl}"
      case "$typ" in
        A|AAAA)
          printf '%s\t%s\tIN\t%s\t%s\n' "$name" "$ttl_use" "$typ" "$value"
          ;;
        NS|CNAME)
          printf '%s\t%s\tIN\t%s\t%s\n' "$name" "$ttl_use" "$typ" "$(dns_ensure_fqdn "$value")"
          ;;
        MX)
          pri=10
          mxhost="$value"
          if [[ "$value" =~ ^[0-9]+[[:space:]] ]]; then
            pri="${value%% *}"
            mxhost="${value#* }"
            mxhost="$(printf '%s' "$mxhost" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          fi
          printf '%s\t%s\tIN\tMX\t%s %s\n' "$name" "$ttl_use" "$pri" "$(dns_ensure_fqdn "$mxhost")"
          ;;
        TXT)
          # Cadenas de <=250 caracteres (límite 255 por cadena; DKIM 2048 bits las supera)
          txt_out="" rest="$value"
          while :; do
            chunk="${rest:0:250}"; rest="${rest:250}"
            esc="$(printf '%s' "$chunk" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            txt_out+="\"$esc\" "
            [[ -n "$rest" ]] || break
          done
          printf '%s\t%s\tIN\tTXT\t( %s)\n' "$name" "$ttl_use" "$txt_out"
          ;;
      esac
    done < "$records_tmp"
  } > "$tmp"

  rm -f "$records_tmp"
  chmod 644 "$tmp"
  chown root:bind "$tmp" 2>/dev/null || chown root:root "$tmp"
  mv -f "$tmp" "$zone_file"
  chmod 644 "$zone_file"
  chown root:bind "$zone_file" 2>/dev/null || true
}

# Regenera named.conf.fresk desde domains activos
dns_regen_named_conf() {
  mkdir -p "$BIND_ZONES" "$FRESK_RUN"
  local tmp
  tmp="$(mktemp "$FRESK_RUN/named.XXXXXX")"
  {
    echo '# Zonas generadas por Flesk — regenerado desde MariaDB (fase 5)'
    echo '# No editar a mano; se sobrescribe en cada cambio DNS.'
    echo
    local d
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      # Solo zonas con fichero presente
      if [[ ! -f "$BIND_ZONES/db.$d" ]]; then
        continue
      fi
      printf 'zone "%s" {\n' "$d"
      echo '    type master;'
      printf '    file "%s/db.%s";\n' "$BIND_ZONES" "$d"
      echo '    allow-transfer { none; };'
      echo '};'
      echo
    done < <(mysql_q -e "SELECT name FROM domains WHERE status='active' ORDER BY name;")
  } > "$tmp"
  chmod 644 "$tmp"
  chown root:bind "$tmp" 2>/dev/null || chown root:root "$tmp"
  backup_file "$BIND_NAMED_FRESK"
  mv -f "$tmp" "$BIND_NAMED_FRESK"
  chmod 644 "$BIND_NAMED_FRESK"
  chown root:bind "$BIND_NAMED_FRESK" 2>/dev/null || true
}

# Comprueba zona (si se pasa dominio) + named-checkconf y recarga.
# Devuelve 1 si check falla (caller debe restaurar backup).
dns_check_and_reload() {
  local domain="${1:-}"
  if [[ -n "$domain" ]]; then
    local zone_file="$BIND_ZONES/db.$domain"
    if [[ -f "$zone_file" ]]; then
      if ! named-checkzone "$domain" "$zone_file" >/tmp/fresk-checkzone.out 2>&1; then
        cat /tmp/fresk-checkzone.out >&2 || true
        return 1
      fi
    fi
  fi
  if ! named-checkconf >/tmp/fresk-checkconf.out 2>&1; then
    cat /tmp/fresk-checkconf.out >&2 || true
    return 1
  fi
  if command -v rndc >/dev/null 2>&1 && rndc status >/dev/null 2>&1; then
    rndc reload >/dev/null 2>&1 || true
  fi
  # Asegurar servicio arriba
  if systemctl list-unit-files 2>/dev/null | grep -q '^bind9'; then
    reload_service bind9 || true
  elif systemctl list-unit-files 2>/dev/null | grep -q '^named'; then
    reload_service named || true
  fi
  return 0
}

dns_apply_ufw_public() {
  local mode="${DNS_PUBLIC:-no}"
  mode="${mode,,}"
  if [[ "$mode" == "yes" || "$mode" == "true" || "$mode" == "1" ]]; then
    ufw allow 53/tcp >/dev/null 2>&1 || true
    ufw allow 53/udp >/dev/null 2>&1 || true
    log "INFO" "UFW: abiertos 53/tcp y 53/udp (DNS_PUBLIC=$mode)"
    if [[ -f /etc/bind/named.conf.options ]] && grep -q 'fresk-listen-begin' /etc/bind/named.conf.options 2>/dev/null; then
      awk '
        /fresk-listen-begin/ {print; print "\tlisten-on port 53 { any; };"; print "\tlisten-on-v6 port 53 { any; };"; skip=1; next}
        /fresk-listen-end/ {skip=0}
        skip {next}
        {print}
      ' /etc/bind/named.conf.options > /etc/bind/named.conf.options.tmp \
        && mv /etc/bind/named.conf.options.tmp /etc/bind/named.conf.options
      named-checkconf >/dev/null 2>&1 && (rndc reconfig >/dev/null 2>&1 || true) || true
    fi
  else
    ufw delete allow 53/tcp >/dev/null 2>&1 || true
    ufw delete allow 53/udp >/dev/null 2>&1 || true
    log "INFO" "UFW: 53 cerrado a internet (DNS_PUBLIC=$mode); prueba con dig @127.0.0.1"
    if [[ -f /etc/bind/named.conf.options ]] && grep -q 'fresk-listen-begin' /etc/bind/named.conf.options 2>/dev/null; then
      awk '
        /fresk-listen-begin/ {print; print "\tlisten-on port 53 { 127.0.0.1; };"; print "\tlisten-on-v6 port 53 { ::1; };"; skip=1; next}
        /fresk-listen-end/ {skip=0}
        skip {next}
        {print}
      ' /etc/bind/named.conf.options > /etc/bind/named.conf.options.tmp \
        && mv /etc/bind/named.conf.options.tmp /etc/bind/named.conf.options
      named-checkconf >/dev/null 2>&1 && (rndc reconfig >/dev/null 2>&1 || true) || true
    fi
  fi
}

# Publica zona: escribe fichero, regenera named.conf, check+reload con restore
dns_publish_domain() {
  local domain="$1"
  local zone_file="$BIND_ZONES/db.$domain"
  mkdir -p "$BIND_ZONES" "$FRESK_BACKUPS"
  local bak=""
  if [[ -f "$zone_file" ]]; then
    bak="$FRESK_BACKUPS/db.${domain}.$(date '+%Y%m%d%H%M%S')"
    cp -a "$zone_file" "$bak"
  fi
  local named_bak=""
  if [[ -f "$BIND_NAMED_FRESK" ]]; then
    named_bak="$FRESK_BACKUPS/named.conf.fresk.$(date '+%Y%m%d%H%M%S')"
    cp -a "$BIND_NAMED_FRESK" "$named_bak"
  fi

  dns_write_zone_file "$domain" "$zone_file"
  dns_regen_named_conf

  if ! dns_check_and_reload "$domain"; then
    log "ERROR" "named-checkzone/conf falló para $domain — restaurando"
    if [[ -n "$bak" && -f "$bak" ]]; then
      cp -a "$bak" "$zone_file"
    else
      rm -f "$zone_file"
    fi
    if [[ -n "$named_bak" && -f "$named_bak" ]]; then
      cp -a "$named_bak" "$BIND_NAMED_FRESK"
    fi
    # Intentar dejar BIND sano con la config restaurada
    named-checkconf >/dev/null 2>&1 && {
      rndc reload >/dev/null 2>&1 || reload_service bind9 2>/dev/null || true
    }
    return 1
  fi
  return 0
}

dns_remove_domain_zone() {
  local domain="$1"
  local zone_file="$BIND_ZONES/db.$domain"
  if [[ -f "$zone_file" ]]; then
    backup_file "$zone_file"
    rm -f "$zone_file"
  fi
  dns_regen_named_conf
  dns_check_and_reload || true
}
