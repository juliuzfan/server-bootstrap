#!/usr/bin/env bash
# shellcheck shell=bash
# Fase 02: endurecimiento de OpenSSH (con transición segura de puerto), UFW y Fail2Ban.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"

TRANSITION_ONLY="${SB_PORT_TRANSITION_ONLY:-0}"
while (( $# > 0 )); do
  case "$1" in
    --transition-only)
      TRANSITION_ONLY=1
      shift
      ;;
    *)
      die "Unknown option in 02-security.sh: $1"
      ;;
  esac
done

require_root
load_config
validate_config
require_debian

[[ "$CONFIRM_SSH_HARDENING" == "YES" ]] \
  || die "CONFIRM_SSH_HARDENING debe ser YES (en config.env o tras confirmar en bootstrap.sh)."

id "$ADMIN_USER" >/dev/null 2>&1 \
  || die "No existe el usuario ${ADMIN_USER}; ejecuta primero scripts/01-system.sh."

ADMIN_HOME="$(user_home "$ADMIN_USER")"
[[ -s "${ADMIN_HOME}/.ssh/authorized_keys" ]] \
  || die "No hay llaves en ${ADMIN_HOME}/.ssh/authorized_keys para ${ADMIN_USER}."

sudo_ready "$ADMIN_USER" \
  || die "El usuario ${ADMIN_USER} no tiene sudo operativo; ejecuta primero scripts/01-system.sh."

install -d -m 755 "$SB_STATE_DIR" "/etc/ssh/sshd_config.d"

# Limpia archivos con el nombre antiguo si quedaron de una versión previa.
if [[ -f "$SB_LEGACY_SSH_DROPIN" ]]; then
  backup_file "$SB_LEGACY_SSH_DROPIN"
  rm -f "$SB_LEGACY_SSH_DROPIN"
fi
if [[ -f "$SB_LEGACY_F2B_JAIL" ]]; then
  backup_file "$SB_LEGACY_F2B_JAIL"
  rm -f "$SB_LEGACY_F2B_JAIL"
fi

# Determina puertos previos para transición sin bloqueo cuando SSH_PORT cambia.
prev_ports="$(state_get initial_ssh_ports)"
if [[ -z "$prev_ports" ]]; then
  prev_ports="$(current_ssh_ports)"
fi
prev_ports="${prev_ports:-22}"

declare -a transition_ports=()
for p in $prev_ports "$SSH_PORT"; do
  [[ "$p" =~ ^[0-9]+$ ]] || continue
  already=0
  if (( ${#transition_ports[@]} > 0 )); then
    for existing in "${transition_ports[@]}"; do
      [[ "$existing" == "$p" ]] && already=1
    done
  fi
  (( already == 0 )) && transition_ports+=("$p")
done

# Función auxiliar: aplica un drop-in de SSH, valida con sshd -t y reinicia verificando puerto.
apply_sshd_dropin() {
  local -a ports=("$@")
  local tmp_cfg p
  tmp_cfg="$(mktemp)"

  {
    printf '# Administrado por server-bootstrap\n'
    for p in "${ports[@]}"; do
      printf 'Port %s\n' "$p"
    done
    cat <<'EOF'
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
# Se conserva el port forwarding TCP para permitir túneles SSH administrativos (ssh -L / -R).
PermitTunnel no
MaxAuthTries 3
LoginGraceTime 30
EOF
  } >"$tmp_cfg"

  install_if_changed "$tmp_cfg" "$SB_SSH_DROPIN" 644 || true

  if ! sshd -t; then
    warn "sshd -t failed. Restoring previous SSH configuration."
    if [[ -n "${SB_LAST_BACKUP:-}" && -f "$SB_LAST_BACKUP" ]]; then
      cp -a "$SB_LAST_BACKUP" "$SB_SSH_DROPIN"
    else
      rm -f "$SB_SSH_DROPIN"
    fi
    die "Invalid SSH configuration; ssh service was not restarted."
  fi

  systemctl restart ssh
  systemctl is-active --quiet ssh || die "ssh service is not active after restart."
  for p in "${ports[@]}"; do
    wait_port_listen "$p" || die "sshd is not listening on port ${p}/tcp."
  done
}

# Reconcilia reglas administradas por server-bootstrap en UFW (elimina obsoletas).
sync_ufw_rules() {
  local -a ssh_ports=("$@")
  local -a desired=()
  local p tok num

  for p in "${ssh_ports[@]}"; do
    desired+=("${p}/tcp")
  done
  if [[ -n "$EXTRA_UFW_PORTS" ]]; then
    for tok in $EXTRA_UFW_PORTS; do
      desired+=("$tok")
    done
  fi

  for tok in "${desired[@]}"; do
    ufw allow "$tok" comment "$SB_RULE_COMMENT" >/dev/null
  done

  # Elimina reglas con comentario server-bootstrap que ya no estén en desired.
  local -a to_delete=()
  while IFS= read -r num; do
    [[ -n "$num" ]] && to_delete+=("$num")
  done < <(
    ufw status numbered 2>/dev/null | awk -v tag="# ${SB_RULE_COMMENT}" -v keep="${desired[*]}" '
      BEGIN {
        n = split(keep, a, " ")
        for (i = 1; i <= n; i++) wanted[a[i]] = 1
      }
      index($0, tag) > 0 {
        line = $0
        sub(/^[[:space:]]*\[[[:space:]]*/, "", line)
        num = line
        sub(/\].*$/, "", num)
        rest = line
        sub(/^[0-9]+\][[:space:]]*/, "", rest)
        split(rest, f, /[[:space:]]+/)
        port = f[1]
        sub(/\(v6\)$/, "", port)
        if (!(port in wanted)) print num
      }
    ' | sort -rn
  )

  if (( ${#to_delete[@]} > 0 )); then
    for num in "${to_delete[@]}"; do
      [[ "$num" =~ ^[0-9]+$ ]] || continue
      ufw --force delete "$num" >/dev/null || true
    done
  fi
}

# 1) Si queremos activar UFW, primero abrimos los puertos de transición ANTES de reiniciar sshd.
if [[ "$ENABLE_UFW" == "yes" ]]; then
  ensure_packages ufw
  log "Configuring UFW firewall (incoming DENY, outgoing ALLOW)"
  if grep -q '^IPV6=' /etc/default/ufw; then
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  else
    printf '\nIPV6=yes\n' >>/etc/default/ufw
  fi
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  sync_ufw_rules "${transition_ports[@]}"
  ufw --force enable >/dev/null
fi

# 2) Aplicamos endurecimiento SSH. Si hay cambio de puerto:
#    - Con --transition-only (modo autónomo): abre ambos puertos y sale para permitir verificación externa.
#    - En modo interactivo: abre ambos puertos, pide confirmar y luego cierra el anterior.
if (( ${#transition_ports[@]} > 1 )) && (( TRANSITION_ONLY == 1 )); then
  log "Safe SSH port transition (keeping active: ${transition_ports[*]})"
  apply_sshd_dropin "${transition_ports[@]}"
  if [[ "$ENABLE_UFW" == "yes" ]]; then
    sync_ufw_rules "${transition_ports[@]}"
  fi
  log "Transition ports active (${transition_ports[*]}). Verify connectivity to port ${SSH_PORT} and re-run 02-security.sh to finalize."
  exit 0
elif (( ${#transition_ports[@]} > 1 )) && is_interactive; then
  log "Safe SSH port transition (${transition_ports[*]})"
  apply_sshd_dropin "${transition_ports[@]}"
  srv_ip="$(primary_ip)"
  echo
  echo "SSH is temporarily listening on: ${transition_ports[*]}"
  echo "Prueba AHORA en otra terminal el nuevo puerto ${SSH_PORT}:"
  echo "  ssh -p ${SSH_PORT} ${ADMIN_USER}@${srv_ip}"
  echo
  if confirm_yes "Do you confirm that you were able to connect on port ${SSH_PORT}?"; then
    log "Closing previous SSH port(s) and leaving only ${SSH_PORT}/tcp"
    apply_sshd_dropin "$SSH_PORT"
    if [[ "$ENABLE_UFW" == "yes" ]]; then
      sync_ufw_rules "$SSH_PORT"
    fi
    state_set initial_ssh_ports "$SSH_PORT"
  else
    warn "Se conservaron ambos puertos activos (${transition_ports[*]}) para evitar bloqueo. Vuelve a ejecutar 02-security.sh cuando el puerto ${SSH_PORT} sea accesible."
  fi
else
  log "Aplicando endurecimiento de OpenSSH en puerto ${SSH_PORT}/tcp"
  apply_sshd_dropin "$SSH_PORT"
  if [[ "$ENABLE_UFW" == "yes" ]]; then
    sync_ufw_rules "$SSH_PORT"
  fi
  state_set initial_ssh_ports "$SSH_PORT"
fi

# 3) Fail2Ban con dependencias systemd + nftables y lista blanca opcional.
if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
  ensure_packages fail2ban python3-systemd nftables
  log "Configuring Fail2Ban for SSH (port ${SSH_PORT})"
  ignore_line="127.0.0.1/8 ::1"
  if [[ -n "$FAIL2BAN_IGNOREIP" ]]; then
    ignore_line="${ignore_line} ${FAIL2BAN_IGNOREIP}"
  fi

  install -d -m 755 /etc/fail2ban/jail.d
  tmp_f2b="$(mktemp)"
  cat >"$tmp_f2b" <<EOF
# Administrado por server-bootstrap
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
ignoreip = ${ignore_line}
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  if install_if_changed "$tmp_f2b" "$SB_F2B_JAIL" 644; then
    systemctl enable fail2ban >/dev/null
    systemctl restart fail2ban
  else
    systemctl enable --now fail2ban >/dev/null
  fi
  systemctl is-active --quiet fail2ban || die "Fail2Ban is not active."
fi

log "Fase 02 (endurecimiento y firewall) completada."
echo "IMPORTANT: keep your current session open until you verify a new SSH connection."
