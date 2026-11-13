#!/usr/bin/env bash
# shellcheck shell=bash
# Orquestador principal de Debian 13 Server Bootstrap (con asistente TUI guiado y modo CI/CD).
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR

# shellcheck source=scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"
# shellcheck source=scripts/tui.sh
source "${ROOT_DIR}/scripts/tui.sh"

usage() {
  cat <<'EOF'
Uso: sudo bash bootstrap.sh [opciones]

Opciones:
  -w, --wizard       Ejecuta el asistente interactivo TUI para crear/editar config.env.
  -c, --config FILE  Ruta al archivo de configuración (por defecto: ./config.env).
  -y, --yes          Modo no interactivo (automatización / cloud-init; requiere CONFIRM_SSH_HARDENING=YES
                     en config.env para ejecutar la fase 02).
  -h, --help         Muestra esta ayuda.
EOF
}

FORCE_WIZARD=0
BOOTSTRAP_NONINTERACTIVE="${BOOTSTRAP_NONINTERACTIVE:-0}"
BOOTSTRAP_CONFIG="${BOOTSTRAP_CONFIG:-${ROOT_DIR}/config.env}"

while (( $# > 0 )); do
  case "$1" in
    -w|--wizard)
      FORCE_WIZARD=1
      shift
      ;;
    -c|--config)
      [[ $# -ge 2 ]] || die "Falta el argumento para $1"
      BOOTSTRAP_CONFIG="$2"
      shift 2
      ;;
    -y|--yes|--non-interactive)
      BOOTSTRAP_NONINTERACTIVE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Opción desconocida: $1 (usa --help)"
      ;;
  esac
done

export BOOTSTRAP_NONINTERACTIVE BOOTSTRAP_CONFIG

require_root
require_debian

# Registra toda la ejecución en /var/log/server-bootstrap.log sin perder la salida en pantalla.
if [[ -z "${__SB_LOGGING_ACTIVE:-}" ]]; then
  export __SB_LOGGING_ACTIVE=1
  mkdir -p "$(dirname "$SB_LOG_FILE")"
  touch "$SB_LOG_FILE"
  chmod 600 "$SB_LOG_FILE"
  exec > >(tee -a "$SB_LOG_FILE") 2>&1
fi

# Si no existe config.env (o se pidió --wizard), lanza el asistente guiado TUI.
if (( FORCE_WIZARD == 1 )) || [[ ! -f "$BOOTSTRAP_CONFIG" ]]; then
  if is_interactive; then
    run_config_wizard "$BOOTSTRAP_CONFIG"
  else
    die "No existe ${BOOTSTRAP_CONFIG}. En modo no interactivo debes proveerlo previamente."
  fi
elif is_interactive; then
  # Si config.env aún tiene la llave placeholder de ejemplo, ofrece abrir el asistente.
  if grep -q 'AAAA_REEMPLAZAR' "$BOOTSTRAP_CONFIG" 2>/dev/null; then
    warn "${BOOTSTRAP_CONFIG} todavía contiene valores de plantilla (AAAA_REEMPLAZAR)."
    run_config_wizard "$BOOTSTRAP_CONFIG"
  else
    tui_banner "Debian 13 Server Bootstrap" "Archivo detectado: ${BOOTSTRAP_CONFIG}"
    tui_select "¿Cómo deseas continuar?" "run" \
      "run|Usar la configuración actual de config.env y continuar" \
      "wizard|Abrir el asistente guiado TUI para revisar/modificar opciones" \
      "cancel|Salir sin hacer cambios"
    case "$TUI_REPLY" in
      wizard) run_config_wizard "$BOOTSTRAP_CONFIG" ;;
      cancel) echo "Cancelado."; exit 0 ;;
    esac
  fi
fi

load_config
validate_config

banner_preview="${MOTD_TEXT:-$SERVER_HOSTNAME}"
render_ascii_banner "$banner_preview" "$MOTD_COLOR" "$MOTD_ART_STYLE"

echo "=================================================================="
echo " Resumen de ejecución (log: ${SB_LOG_FILE})"
echo "------------------------------------------------------------------"
echo " Hostname:         ${SERVER_HOSTNAME} (${TIMEZONE})"
echo " Usuario admin:    ${ADMIN_USER} (sudo: ${SUDO_MODE}, llaves: ${#SB_KEYS[@]})"
echo " SSH puerto final: ${SSH_PORT}/tcp"
echo " Firewall UFW:     ${ENABLE_UFW} ${EXTRA_UFW_PORTS:+(extra: ${EXTRA_UFW_PORTS})}"
echo " Fail2Ban:         ${ENABLE_FAIL2BAN} ${FAIL2BAN_IGNOREIP:+(ignoreip: ${FAIL2BAN_IGNOREIP})}"
echo " Auto-upgrades:    ${ENABLE_UNATTENDED_UPGRADES} (auto-reboot: ${AUTO_REBOOT})"
echo " Prompt & MOTD:    prompt=${ENABLE_PROMPT}, motd=${ENABLE_MOTD} (${MOTD_COLOR}/${MOTD_ART_STYLE})"
echo "=================================================================="

if is_interactive; then
  echo "Asegúrate de contar con acceso a la consola de tu proveedor por seguridad."
  confirm_yes "¿Iniciar Fase 01 (preparación del sistema)?" || { echo "Cancelado."; exit 0; }
fi

log "Ejecutando Fase 01: Preparación del sistema"
bash "${ROOT_DIR}/scripts/01-system.sh"

# Comprueba en qué puerto está escuchando sshd ahora mismo para dar la instrucción exacta.
active_ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
active_ssh_port="${active_ssh_port:-22}"
srv_ip="$(primary_ip)"

if is_interactive; then
  echo
  echo "=================================================================="
  echo " PRUEBA OBLIGATORIA ANTES DE ENDURECER SSH (Fase 02)"
  echo "------------------------------------------------------------------"
  echo " 1. Abre OTRA terminal sin cerrar esta sesión."
  echo " 2. Verifica que entras con tu llave SSH y que sudo funciona:"
  echo "      ssh -p ${active_ssh_port} ${ADMIN_USER}@${srv_ip}"
  echo "      sudo -v"
  if [[ "$SSH_PORT" != "$active_ssh_port" ]]; then
    echo " 3. Nota: el cambio al puerto ${SSH_PORT} se hará en transición segura"
    echo "    durante el siguiente paso (ambos puertos abiertos hasta confirmar)."
  fi
  echo "=================================================================="
  if ! confirm_yes "¿Confirmas que el login con llave y sudo funcionaron en otra terminal?"; then
    warn "Se dejó SSH sin endurecer. Cuando lo verifiques, ejecuta:"
    echo "  sudo bash scripts/02-security.sh"
    echo "  sudo bash scripts/03-verify.sh"
    exit 0
  fi
  CONFIRM_SSH_HARDENING="YES"
  export CONFIRM_SSH_HARDENING
  write_config_file "$BOOTSTRAP_CONFIG"
elif [[ "$CONFIRM_SSH_HARDENING" != "YES" ]]; then
  warn "Modo no interactivo con CONFIRM_SSH_HARDENING=${CONFIRM_SSH_HARDENING}: se omite la Fase 02."
  exit 0
fi

log "Ejecutando Fase 02: Endurecimiento SSH, UFW y Fail2Ban"
bash "${ROOT_DIR}/scripts/02-security.sh"

log "Ejecutando Fase 03: Verificación final"
bash "${ROOT_DIR}/scripts/03-verify.sh"

echo
echo "Bootstrap finalizado con éxito. Conserva abierta tu sesión actual hasta probar una nueva conexión."
