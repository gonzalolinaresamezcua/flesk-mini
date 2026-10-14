#!/usr/bin/env bash
# Flesk — listar dominios
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

ensure_installed

FORMAT="${1:-table}"

rows="$(mysql_q -e "SELECT id, name, status, php_version, ipv4, docroot, created_at FROM domains ORDER BY name;" 2>/dev/null)" || die 5 "No se pudo listar dominios"

if [[ -z "${rows}" ]]; then
  echo "(sin dominios)"
  exit 0
fi

if [[ "$FORMAT" == "raw" || "$FORMAT" == "-N" ]]; then
  printf '%s\n' "$rows"
  exit 0
fi

printf '%-4s %-40s %-8s %-6s %-15s %s\n' "ID" "NAME" "STATUS" "PHP" "IPV4" "DOCROOT"
printf '%-4s %-40s %-8s %-6s %-15s %s\n' "----" "----------------------------------------" "--------" "------" "---------------" "-------"
while IFS=$'\t' read -r id name status php ipv4 docroot _created; do
  printf '%-4s %-40s %-8s %-6s %-15s %s\n' "$id" "$name" "$status" "$php" "${ipv4:--}" "$docroot"
done <<< "$rows"
exit 0
