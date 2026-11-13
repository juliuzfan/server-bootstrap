#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/config.env"
source "${ROOT_DIR}/scripts/common.sh"
validate_config
require_debian

[[ "${EUID}" -eq 0 ]] || die "Ejecuta con sudo."
[[ "$CONFIRM_SSH_HARDENING" == "YES" ]] || die "Configura CONFIRM_SSH_HARDENING=YES en config.env después de probar la llave."
id "$ADMIN_USER" >/dev/null 2>&1 || die "No existe ${ADMIN_USER}; ejecuta primero 01-system.sh."
[[ -s "/home/${ADMIN_USER}/.ssh/authorized_keys" ]] || die "No hay authorized_keys para ${ADMIN_USER}."

SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
install -d -m 755 "$SSH_DROPIN_DIR"
SSH_DROPIN="${SSH_DROPIN_DIR}/00-bootstrap-hardening.conf"
backup_file "$SSH_DROPIN"

cat > "$SSH_DROPIN" <<EOF
# Administrado por debian-server-bootstrap
Port ${SSH_PORT}
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
# Se conserva el port forwarding para permitir túneles SSH administrativos.
PermitTunnel no
MaxAuthTries 3
LoginGraceTime 30
EOF

log "Validando configuración SSH"
if ! sshd -t; then
  warn "Configuración SSH inválida. Restaurando el drop-in anterior."
  latest_backup="$(ls -1t "${SSH_DROPIN}".bootstrap-*.bak 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest_backup" ]]; then cp -a "$latest_backup" "$SSH_DROPIN"; else rm -f "$SSH_DROPIN"; fi
  die "sshd -t falló; no se recargó SSH."
fi

if [[ "$ENABLE_UFW" == "yes" ]]; then
  log "Configurando UFW (entrada DENY, salida ALLOW)"
  # Habilitar IPv6 en UFW para que las reglas cubran ambas familias.
  if grep -q '^IPV6=' /etc/default/ufw; then
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  else
    printf '\nIPV6=yes\n' >> /etc/default/ufw
  fi
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment 'SSH'
  ufw --force enable
fi

log "Recargando OpenSSH"
systemctl restart ssh
systemctl is-active --quiet ssh || die "El servicio SSH no está activo."

if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
  log "Configurando Fail2Ban para SSH"
  cat > /etc/fail2ban/jail.d/sshd-bootstrap.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
fi

log "Endurecimiento completado"
echo "IMPORTANTE: abre una NUEVA sesión SSH y verifica acceso antes de cerrar la sesión actual."
