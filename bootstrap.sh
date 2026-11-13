#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: ejecuta con sudo: sudo bash bootstrap.sh" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: falta config.env. Copia config.env.example a config.env y edítalo." >&2
  exit 1
fi

# config.env es código shell: solo cargues un archivo que tú hayas creado/revisado.
# shellcheck disable=SC1090
source "$CONFIG_FILE"

export ROOT_DIR HOSTNAME TIMEZONE ADMIN_USER SSH_PUBLIC_KEY SSH_PORT
export ENABLE_UFW ENABLE_FAIL2BAN ENABLE_UNATTENDED_UPGRADES CONFIRM_SSH_HARDENING

source "${ROOT_DIR}/scripts/common.sh"
validate_config
require_debian

echo
echo "=================================================="
echo " Debian Server Bootstrap"
echo " Hostname: ${HOSTNAME}"
echo " Usuario:  ${ADMIN_USER}"
echo " SSH port: ${SSH_PORT}"
echo "=================================================="
echo "Este proceso actualizará paquetes y modificará SSH/firewall."
echo "Asegúrate de tener acceso a consola del proveedor."
read -r -p "¿Continuar? Escribe YES: " answer
[[ "$answer" == "YES" ]] || { echo "Cancelado."; exit 0; }

run_step "Preparación del sistema" "${ROOT_DIR}/scripts/01-system.sh"

echo
echo "PRUEBA OBLIGATORIA ANTES DE ENDURECER SSH:"
echo "1. Abre OTRA terminal."
echo "2. Comprueba que puedes entrar con la llave al usuario ${ADMIN_USER}:"
echo "   ssh -p ${SSH_PORT} ${ADMIN_USER}@IP_DEL_SERVIDOR"
echo "3. No cierres tu sesión root actual hasta confirmar el acceso."
echo
read -r -p "¿Probaste y confirmaste el acceso SSH con llave en otra sesión? Escribe YES: " key_ok
if [[ "$key_ok" != "YES" ]]; then
  echo "Se dejó SSH sin endurecimiento de autenticación. Ejecuta después:"
  echo "  sudo bash scripts/02-security.sh"
  exit 0
fi

run_step "Endurecimiento y firewall" "${ROOT_DIR}/scripts/02-security.sh"
run_step "Verificación final" "${ROOT_DIR}/scripts/03-verify.sh"

echo
echo "Bootstrap terminado. Conserva abierta tu sesión actual hasta probar una nueva conexión."
