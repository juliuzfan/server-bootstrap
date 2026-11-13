#!/usr/bin/env bash
# shellcheck shell=bash
# Fase 03: verificación integral e informe de estado del servidor.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"

require_root
load_config
validate_config
require_debian

PASS=0
WARN_CNT=0
FAIL=0

check_ok()   { PASS=$((PASS + 1));     printf '  %s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
check_warn() { WARN_CNT=$((WARN_CNT + 1)); printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
check_fail() { FAIL=$((FAIL + 1));     printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; }

echo "===== SISTEMA ====="
printf '  Debian: %s\n' "$(cat /etc/debian_version 2>/dev/null || echo desconocido)"
cur_host="$(hostnamectl --static 2>/dev/null || hostname)"
cur_tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo desconocido)"
[[ "$cur_host" == "$SERVER_HOSTNAME" ]] && check_ok "Hostname: ${cur_host}" || check_fail "Hostname actual '${cur_host}' != '${SERVER_HOSTNAME}'"
[[ "$cur_tz" == "$TIMEZONE" ]] && check_ok "Timezone: ${cur_tz}" || check_fail "Timezone actual '${cur_tz}' != '${TIMEZONE}'"
systemctl is-active --quiet chrony && check_ok "chrony activo" || check_warn "chrony no está activo"

echo
echo "===== USUARIO ADMINISTRATIVO (${ADMIN_USER}) ====="
if id "$ADMIN_USER" >/dev/null 2>&1; then
  check_ok "Usuario ${ADMIN_USER} existe ($(id "$ADMIN_USER"))"
else
  check_fail "Usuario ${ADMIN_USER} no existe"
fi

if sudo_ready "$ADMIN_USER"; then
  check_ok "Acceso sudo operativo para ${ADMIN_USER} (modo: ${SUDO_MODE})"
else
  check_fail "El usuario ${ADMIN_USER} NO tiene sudo funcional"
fi

ADMIN_HOME="$(user_home "$ADMIN_USER")"
if [[ -s "${ADMIN_HOME}/.ssh/authorized_keys" ]]; then
  perms="$(stat -c '%a' "${ADMIN_HOME}/.ssh/authorized_keys")"
  check_ok "authorized_keys presente (permisos ${perms})"
else
  check_fail "Falta ${ADMIN_HOME}/.ssh/authorized_keys"
fi

echo
echo "===== SSH ====="
if sshd -t 2>/dev/null; then
  check_ok "Sintaxis sshd -t válida"
else
  check_fail "sshd -t reporta errores"
fi

sshd_dump="$(sshd -T 2>/dev/null || true)"
printf '%s\n' "$sshd_dump" | grep -E '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) ' | sed 's/^/  /' || true

if [[ "$CONFIRM_SSH_HARDENING" == "YES" ]]; then
  grep -qx "permitrootlogin no" <<<"$sshd_dump" && check_ok "PermitRootLogin no" || check_fail "PermitRootLogin no está deshabilitado"
  grep -qx "passwordauthentication no" <<<"$sshd_dump" && check_ok "PasswordAuthentication no" || check_fail "PasswordAuthentication sigue habilitado"
  grep -qx "port ${SSH_PORT}" <<<"$sshd_dump" && check_ok "Puerto SSH configurado: ${SSH_PORT}" || check_warn "Puerto ${SSH_PORT} aún no figura en sshd -T"
else
  check_warn "Endurecimiento SSH pendiente (CONFIRM_SSH_HARDENING=${CONFIRM_SSH_HARDENING})"
fi

echo
echo "===== FIREWALL (UFW) ====="
if [[ "$ENABLE_UFW" == "yes" ]]; then
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    check_ok "UFW activo"
    ufw status verbose | sed 's/^/  /'
  else
    check_warn "UFW habilitado en config.env pero aún no está activo"
  fi
else
  check_ok "UFW deshabilitado por configuración"
fi

echo
echo "===== FAIL2BAN ====="
if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
  if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    check_ok "Fail2Ban activo con jail sshd"
    fail2ban-client status sshd | sed 's/^/  /'
  else
    check_warn "Fail2Ban habilitado en config.env pero jail sshd aún no está activa"
  fi
else
  check_ok "Fail2Ban deshabilitado por configuración"
fi

echo
echo "===== PERSONALIZACIÓN (.bashrc, NEOVIM & MOTD) ====="
if command -v nvim >/dev/null 2>&1; then
  check_ok "Neovim instalado ($(nvim --version | head -n1))"
else
  check_fail "Neovim no está instalado"
fi
if grep -q "Roster.li" /root/.bashrc 2>/dev/null && grep -q "Roster.li" "${ADMIN_HOME}/.bashrc" 2>/dev/null; then
  check_ok ".bashrc y prompt configurados en /root/.bashrc y ${ADMIN_HOME}/.bashrc"
else
  check_fail "Falta configuración de .bashrc en root o ${ADMIN_USER}"
fi
if [[ "$ENABLE_MOTD" == "yes" ]]; then
  [[ -f "$SB_MOTD_FILE" && -f "$SB_INFO_SCRIPT" ]] && check_ok "MOTD ASCII Art instalado (color: ${MOTD_COLOR}, estilo: ${MOTD_ART_STYLE})" || check_fail "Falta MOTD o script de estado"
fi

echo
echo "===== PUERTOS EN ESCUCHA ====="
ss -tulpen | sed 's/^/  /'

echo
echo "===== RESUMEN ====="
printf '  OK: %d | WARN: %d | FAIL: %d\n' "$PASS" "$WARN_CNT" "$FAIL"
if (( FAIL > 0 )); then
  die "La verificación detectó ${FAIL} fallo(s)."
fi
