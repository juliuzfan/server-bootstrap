#!/usr/bin/env bash
# shellcheck shell=bash
# Phase 03: comprehensive verification and server status report.
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

echo "===== SYSTEM ====="
printf '  Debian: %s\n' "$(cat /etc/debian_version 2>/dev/null || echo unknown)"
cur_host="$(hostnamectl --static 2>/dev/null || hostname)"
cur_tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
[[ "$cur_host" == "$SERVER_HOSTNAME" ]] && check_ok "Hostname: ${cur_host}" || check_fail "Current hostname '${cur_host}' != '${SERVER_HOSTNAME}'"
[[ "$cur_tz" == "$TIMEZONE" ]] && check_ok "Timezone: ${cur_tz}" || check_fail "Current timezone '${cur_tz}' != '${TIMEZONE}'"
srv_ip_check="${SERVER_IP:-$(detect_server_ip)}"
if [[ -n "$srv_ip_check" ]] && grep -Eq "^[[:space:]]*${srv_ip_check//./\\.}[[:space:]]+.*\\b${SERVER_HOSTNAME//./\\.}\\b" /etc/hosts; then
  check_ok "/etc/hosts: ${srv_ip_check} -> ${SERVER_HOSTNAME}"
else
  check_warn "/etc/hosts does not contain an entry for ${srv_ip_check:-PUBLIC_IP} -> ${SERVER_HOSTNAME}"
fi
systemctl is-active --quiet chrony && check_ok "chrony active" || check_warn "chrony is not active"

echo
echo "===== ADMIN USER (${ADMIN_USER}) ====="
if id "$ADMIN_USER" >/dev/null 2>&1; then
  check_ok "User ${ADMIN_USER} exists ($(id "$ADMIN_USER"))"
else
  check_fail "User ${ADMIN_USER} does not exist"
fi

if sudo_ready "$ADMIN_USER"; then
  check_ok "sudo access operational for ${ADMIN_USER} (mode: ${SUDO_MODE})"
else
  check_fail "User ${ADMIN_USER} does NOT have working sudo"
fi

ADMIN_HOME="$(user_home "$ADMIN_USER")"
if [[ -s "${ADMIN_HOME}/.ssh/authorized_keys" ]]; then
  perms="$(stat -c '%a' "${ADMIN_HOME}/.ssh/authorized_keys")"
  check_ok "authorized_keys present (permissions ${perms})"
else
  check_fail "Missing ${ADMIN_HOME}/.ssh/authorized_keys"
fi

echo
echo "===== SSH ====="
if sshd -t 2>/dev/null; then
  check_ok "sshd -t syntax valid"
else
  check_fail "sshd -t reports errors"
fi

sshd_dump="$(sshd -T 2>/dev/null || true)"
printf '%s\n' "$sshd_dump" | grep -E '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) ' | sed 's/^/  /' || true

if [[ "$CONFIRM_SSH_HARDENING" == "YES" ]]; then
  grep -qx "permitrootlogin no" <<<"$sshd_dump" && check_ok "PermitRootLogin no" || check_fail "PermitRootLogin is not disabled"
  grep -qx "passwordauthentication no" <<<"$sshd_dump" && check_ok "PasswordAuthentication no" || check_fail "PasswordAuthentication is still enabled"
  grep -qx "port ${SSH_PORT}" <<<"$sshd_dump" && check_ok "Configured SSH port: ${SSH_PORT}" || check_warn "Port ${SSH_PORT} not yet shown in sshd -T"
else
  check_warn "SSH hardening pending (CONFIRM_SSH_HARDENING=${CONFIRM_SSH_HARDENING})"
fi

echo
echo "===== FIREWALL (UFW) ====="
if [[ "$ENABLE_UFW" == "yes" ]]; then
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    check_ok "UFW active"
    ufw status verbose | sed 's/^/  /'
  else
    check_warn "UFW enabled in config.env but not active yet"
  fi
else
  check_ok "UFW disabled by configuration"
fi

echo
echo "===== FAIL2BAN ====="
if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
  if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    check_ok "Fail2Ban active with sshd jail"
    fail2ban-client status sshd | sed 's/^/  /'
  else
    check_warn "Fail2Ban enabled in config.env but sshd jail is not active yet"
  fi
else
  check_ok "Fail2Ban disabled by configuration"
fi

echo
echo "===== CUSTOMIZATION (.bashrc, NEOVIM & MOTD) ====="
if command -v nvim >/dev/null 2>&1; then
  check_ok "Neovim installed ($(nvim --version | head -n1))"
else
  check_fail "Neovim is not installed"
fi
if grep -q "Roster.li" /root/.bashrc 2>/dev/null && grep -q "Roster.li" "${ADMIN_HOME}/.bashrc" 2>/dev/null; then
  check_ok ".bashrc and prompt configured in /root/.bashrc and ${ADMIN_HOME}/.bashrc"
else
  check_fail "Missing .bashrc configuration for root or ${ADMIN_USER}"
fi
if [[ "$ENABLE_MOTD" == "yes" ]]; then
  [[ -f "$SB_MOTD_FILE" && -f "$SB_INFO_SCRIPT" ]] && check_ok "MOTD ASCII Art installed (color: ${MOTD_COLOR}, style: ${MOTD_ART_STYLE})" || check_fail "Missing MOTD or status script"
fi

echo
echo "===== LISTENING PORTS ====="
ss -tulpen | sed 's/^/  /'

echo
echo "===== SUMMARY ====="
printf '  OK: %d | WARN: %d | FAIL: %d\n' "$PASS" "$WARN_CNT" "$FAIL"
if (( FAIL > 0 )); then
  die "Verification detected ${FAIL} failure(s)."
fi
