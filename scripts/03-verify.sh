#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/config.env"
source "${ROOT_DIR}/scripts/common.sh"
validate_config
require_debian

echo "===== SISTEMA ====="
cat /etc/debian_version
hostnamectl
timedatectl status | sed -n '1,8p'

echo
echo "===== USUARIO ADMINISTRATIVO ====="
id "$ADMIN_USER"
sudo -l -U "$ADMIN_USER" || true
stat -c '%A %U:%G %n' "/home/${ADMIN_USER}/.ssh" "/home/${ADMIN_USER}/.ssh/authorized_keys"

echo
echo "===== SSH ====="
sshd -t && echo "sshd -t: OK"
systemctl --no-pager --full status ssh | sed -n '1,8p'
sshd -T | grep -E '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) '

echo
echo "===== FIREWALL ====="
if command -v ufw >/dev/null 2>&1; then ufw status verbose; fi

echo
echo "===== FAIL2BAN ====="
if systemctl is-active --quiet fail2ban; then fail2ban-client status sshd || fail2ban-client status; else echo "Fail2Ban no activo."; fi

echo
echo "===== PUERTOS EN ESCUCHA ====="
ss -tulpen

echo
echo "===== ACTUALIZACIONES PENDIENTES ====="
apt-get -s upgrade | awk '/^Inst / {print}'
echo
echo "Verificación terminada. Revisa los puertos y servicios que realmente necesitas."
