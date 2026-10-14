#!/usr/bin/env bash
# Flesk — pila de rollback. Sourcear después de common.sh
# Uso: rb_push "comando inverso"; rb_run al fallar

FRESK_RB_STACK=()

rb_reset() {
  FRESK_RB_STACK=()
}

rb_push() {
  FRESK_RB_STACK+=("$*")
}

rb_run() {
  local i
  log "WARN" "Ejecutando rollback (${#FRESK_RB_STACK[@]} pasos)..."
  for (( i=${#FRESK_RB_STACK[@]}-1; i>=0; i-- )); do
    log "WARN" "rollback: ${FRESK_RB_STACK[$i]}"
    # shellcheck disable=SC2086
    eval "${FRESK_RB_STACK[$i]}" || log "ERROR" "rollback falló: ${FRESK_RB_STACK[$i]}"
  done
  FRESK_RB_STACK=()
}
