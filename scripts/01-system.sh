#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/config.env"
source "${ROOT_DIR}/scripts/common.sh"
validate_config
require_debian

export DEBIAN_FRONTEND=noninteractive
log "Actualizando índices y paquetes"
apt-get update
apt-get -y upgrade

log "Instalando herramientas base"
apt-get install -y --no-install-recommends \
  sudo openssh-server ca-certificates curl wget git vim nano \
  ufw fail2ban unattended-upgrades apt-listchanges \
  chrony curl dnsutils iproute2 lsof

log "Configurando zona horaria y hostname"
timedatectl set-timezone "$TIMEZONE"
hostnamectl set-hostname "$HOSTNAME"

if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$ADMIN_USER"
fi
usermod --append --groups sudo "$ADMIN_USER"

log "Instalando llave pública para ${ADMIN_USER}"
SSH_DIR="/home/${ADMIN_USER}/.ssh"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$SSH_DIR"
touch "${SSH_DIR}/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"
grep -qxF "$SSH_PUBLIC_KEY" "${SSH_DIR}/authorized_keys" || \
  printf '%s\n' "$SSH_PUBLIC_KEY" >> "${SSH_DIR}/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "${SSH_DIR}/authorized_keys"

log "Habilitando OpenSSH y sincronización horaria"
systemctl enable --now ssh
systemctl enable --now chrony

if [[ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]]; then
  log "Activando actualizaciones automáticas de seguridad"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
fi

log "Preparación del sistema completada"
echo "Comprueba el acceso SSH con llave antes de ejecutar 02-security.sh."
