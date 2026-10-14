#!/usr/bin/env bash
# Flesk — aplicación y versión que usa cada BD de sitio (JSON a stdout). Solo lectura.
# Uso: flesk db appinfo [<nombre_bd>]
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
require_root
ensure_installed
if [[ $# -gt 1 ]]; then die 2 "Uso: flesk db appinfo [<nombre_bd>]"; fi
if [[ $# -eq 1 && ! "$1" =~ ^db_[a-z0-9_]{1,61}$ ]]; then die 2 "Nombre de BD inválido: $1"; fi
exec timeout 120 php -d display_errors=stderr -d memory_limit=256M "$FRESK_ROOT/lib/db-appinfo.php" "$@"
