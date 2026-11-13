#!/usr/bin/env bash
# shellcheck shell=bash
# Fase 01: paquetes base, zona horaria, hostname, /etc/hosts, usuario admin, sudo,
# llaves SSH, chrony, unattended-upgrades, prompt Bash moderno y MOTD ASCII Art.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"
# shellcheck source=scripts/tui.sh
source "${ROOT_DIR}/scripts/tui.sh"

require_root
load_config
validate_config
require_debian

export DEBIAN_FRONTEND=noninteractive

# Registra los puertos en los que SSH escuchaba antes del bootstrap (para transición segura).
if [[ -z "$(state_get initial_ssh_ports)" ]]; then
  init_ports="$(current_ssh_ports)"
  state_set initial_ssh_ports "${init_ports:-22}"
fi

log "Actualizando índices y paquetes del sistema"
apt-get update
apt-get -y upgrade \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold

# Paquetes base + dependencias requeridas por las opciones activadas.
PKGS=(
  sudo openssh-server ca-certificates curl wget git vim nano
  chrony dnsutils iproute2 lsof procps
)
if [[ "$ENABLE_UFW" == "yes" ]]; then
  PKGS+=(ufw)
fi
if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
  # python3-systemd y nftables son Recommends en Debian; requeridos con --no-install-recommends.
  PKGS+=(fail2ban python3-systemd nftables)
fi
if [[ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]]; then
  PKGS+=(unattended-upgrades apt-listchanges)
fi
ensure_packages "${PKGS[@]}"

log "Configurando zona horaria (${TIMEZONE}) y hostname (${SERVER_HOSTNAME})"
if [[ "$(timedatectl show -p Timezone --value 2>/dev/null || true)" != "$TIMEZONE" ]]; then
  timedatectl set-timezone "$TIMEZONE"
fi
if [[ "$(hostnamectl --static 2>/dev/null || hostname)" != "$SERVER_HOSTNAME" ]]; then
  hostnamectl set-hostname "$SERVER_HOSTNAME"
fi

# Asegura que 127.0.1.1 resuelva el nuevo hostname para evitar avisos de sudo.
short_host="${SERVER_HOSTNAME%%.*}"
hosts_entry="127.0.1.1	${SERVER_HOSTNAME}"
if [[ "$short_host" != "$SERVER_HOSTNAME" ]]; then
  hosts_entry="127.0.1.1	${SERVER_HOSTNAME} ${short_host}"
fi
tmp_hosts="$(mktemp)"
if grep -Eq '^[[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts; then
  awk -v line="$hosts_entry" '
    /^[[:space:]]*127\.0\.1\.1[[:space:]]/ && !done { print line; done = 1; next }
    { print }
  ' /etc/hosts >"$tmp_hosts"
else
  cat /etc/hosts >"$tmp_hosts"
  printf '%s\n' "$hosts_entry" >>"$tmp_hosts"
fi
install_if_changed "$tmp_hosts" /etc/hosts 644 || true

log "Configurando usuario administrativo (${ADMIN_USER}) y acceso sudo (${SUDO_MODE})"
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$ADMIN_USER"
fi
usermod --append --groups sudo "$ADMIN_USER"

if [[ "$SUDO_MODE" == "nopasswd" ]]; then
  tmp_sudo="$(mktemp)"
  printf '# Administrado por server-bootstrap\n%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$ADMIN_USER" >"$tmp_sudo"
  chmod 440 "$tmp_sudo"
  visudo -cf "$tmp_sudo" >/dev/null
  install_if_changed "$tmp_sudo" "$SB_SUDOERS_FILE" 440 || true
else
  rm -f "$SB_SUDOERS_FILE"
  if [[ -n "$ADMIN_PASSWORD_HASH" ]]; then
    printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD_HASH" | chpasswd -e
  elif ! user_has_password "$ADMIN_USER"; then
    if is_interactive; then
      echo
      echo "Establece la contraseña de sudo para '${ADMIN_USER}':"
      until passwd "$ADMIN_USER"; do
        warn "No se pudo establecer la contraseña; inténtalo de nuevo."
      done
    else
      die "${ADMIN_USER} no tiene contraseña y SUDO_MODE=password en modo no interactivo. Define ADMIN_PASSWORD_HASH o SUDO_MODE=nopasswd."
    fi
  fi
fi

sudo_ready "$ADMIN_USER" || die "El usuario ${ADMIN_USER} no tiene acceso sudo funcional."

log "Instalando llaves SSH públicas para ${ADMIN_USER}"
ADMIN_HOME="$(user_home "$ADMIN_USER")"
[[ -n "$ADMIN_HOME" && -d "$ADMIN_HOME" ]] || die "No se encontró el directorio home de ${ADMIN_USER}."

SSH_DIR="${ADMIN_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$SSH_DIR"
touch "$AUTH_KEYS"
chown "$ADMIN_USER:$ADMIN_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

for key in "${SB_KEYS[@]}"; do
  grep -qxF "$key" "$AUTH_KEYS" || printf '%s\n' "$key" >>"$AUTH_KEYS"
done

log "Habilitando servicios OpenSSH y sincronización horaria (chrony)"
systemctl enable --now ssh
systemctl enable --now chrony

if [[ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]]; then
  log "Configurando actualizaciones automáticas (unattended-upgrades)"
  tmp_auto="$(mktemp)"
  cat >"$tmp_auto" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  install_if_changed "$tmp_auto" /etc/apt/apt.conf.d/20auto-upgrades 644 || true

  tmp_uu="$(mktemp)"
  reboot_flag="false"
  [[ "$AUTO_REBOOT" == "yes" ]] && reboot_flag="true"
  cat >"$tmp_uu" <<EOF
// Administrado por server-bootstrap
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "${reboot_flag}";
Unattended-Upgrade::Automatic-Reboot-Time "${AUTO_REBOOT_TIME}";
EOF
  install_if_changed "$tmp_uu" /etc/apt/apt.conf.d/52server-bootstrap-unattended 644 || true
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
fi

# ---------------------------------- Prompt Bash moderno (root + admin) ---
install -d -m 755 "$SB_STATE_DIR"
accent_code="$(motd_accent "$MOTD_COLOR")"

configure_bashrc_hook() {
  local rc_file=$1 owner=$2
  local begin="# >>> server-bootstrap prompt >>>"
  local end="# <<< server-bootstrap prompt <<<"
  touch "$rc_file"
  chown "$owner:$owner" "$rc_file"
  chmod 644 "$rc_file"

  local tmp_rc
  tmp_rc="$(mktemp)"
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$rc_file" >"$tmp_rc"

  if [[ "$ENABLE_PROMPT" == "yes" ]]; then
    cat >>"$tmp_rc" <<EOF
${begin}
if [ -r "${SB_PROMPT_FILE}" ]; then
  . "${SB_PROMPT_FILE}"
fi
${end}
EOF
  fi
  cat "$tmp_rc" >"$rc_file"
  rm -f "$tmp_rc"
  chown "$owner:$owner" "$rc_file"
}

if [[ "$ENABLE_PROMPT" == "yes" ]]; then
  log "Configurando prompt Bash moderno en colores para root y ${ADMIN_USER}"
  tmp_prompt="$(mktemp)"
  printf '# Administrado por server-bootstrap — Prompt Bash interactivo moderno\n__sb_ACCENT="%s"\n' "$accent_code" >"$tmp_prompt"
  cat >>"$tmp_prompt" <<'EOF'
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

__sb_git_branch() {
  command -v git >/dev/null 2>&1 || return 0
  local b
  b="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)" || return 0
  [ -n "$b" ] && printf ' (\001\033[1;38;5;213m\002git:%s\001\033[0m\002)' "$b"
}

__sb_set_prompt() {
  local ec=$?
  local c_rst='\001\033[0m\002'
  local c_dim='\001\033[2m\002'
  local c_acc='\001\033[1;38;5;'"${__sb_ACCENT}"'m\002'
  local c_host='\001\033[1;38;5;51m\002'
  local c_dir='\001\033[1;38;5;226m\002'
  local c_ok='\001\033[1;38;5;118m\002'
  local c_err='\001\033[1;38;5;196m\002'

  local c_user="$c_acc" sym='❯' tag=''
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    c_user='\001\033[1;38;5;196m\002'
    sym='#'
    tag=' \001\033[1;48;5;196;38;5;255m\002 ROOT \001\033[0m\002'
  fi

  local st="${c_ok}✔${c_rst}"
  if [ "$ec" -ne 0 ]; then
    st="${c_err}✘ ${ec}${c_rst}"
  fi

  PS1="\n${c_dim}┌─[${c_rst}${st}${c_dim}]─[${c_rst}\A${c_dim}]─[${c_rst}${c_user}\u${c_rst}${c_dim}@${c_rst}${c_host}\h${c_rst}${c_dim}]${tag}─[${c_rst}${c_dir}\w${c_rst}${c_dim}]${c_rst}$(__sb_git_branch)\n${c_dim}└─${c_rst}${c_user}${sym}${c_rst} "
}

export LS_OPTIONS='--color=auto'
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias grep='grep --color=auto'

PROMPT_COMMAND=__sb_set_prompt
EOF
  install_if_changed "$tmp_prompt" "$SB_PROMPT_FILE" 644 || true
else
  rm -f "$SB_PROMPT_FILE"
fi

configure_bashrc_hook "/root/.bashrc" "root"
configure_bashrc_hook "${ADMIN_HOME}/.bashrc" "$ADMIN_USER"

# ---------------------------------- MOTD con ASCII Art + estado en vivo ---
if [[ "$ENABLE_MOTD" == "yes" ]]; then
  banner_text="${MOTD_TEXT:-$SERVER_HOSTNAME}"
  log "Configurando MOTD de bienvenida ('${banner_text}', color: ${MOTD_COLOR}, estilo: ${MOTD_ART_STYLE})"
  tmp_motd="$(mktemp)"
  {
    render_ascii_banner "$banner_text" "$MOTD_COLOR" "$MOTD_ART_STYLE"
    printf '  \033[1;38;5;%sm%s\033[0m \033[2m• Debian GNU/Linux • Acceso autorizado únicamente\033[0m\n\n' \
      "$accent_code" "$SERVER_HOSTNAME"
  } >"$tmp_motd"
  install_if_changed "$tmp_motd" "$SB_MOTD_FILE" 644 || true

  tmp_info="$(mktemp)"
  printf '#!/usr/bin/env bash\n# Administrado por server-bootstrap — Resumen de estado al iniciar sesión interactiva\n__sb_ACCENT="%s"\n' "$accent_code" >"$tmp_info"
  cat >>"$tmp_info" <<'EOF'
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac
[ -n "${__SB_MOTD_SHOWN:-}" ] && return 0
export __SB_MOTD_SHOWN=1

__sb_show_sysinfo() {
  local acc="\033[1;38;5;${__sb_ACCENT}m" dim="\033[2m" rst="\033[0m"
  local os up load mem disk ip
  os="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-Debian}")"
  up="$(uptime -p 2>/dev/null | sed 's/^up //')"
  load="$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null)"
  mem="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3" / "$2}')"
  disk="$(df -h / 2>/dev/null | awk 'NR==2 {print $3" / "$2" ("$5")"}')"
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')"

  printf "  ${dim}──────────────────────────────────────────────────────────────${rst}\n"
  printf "  ${acc}OS:${rst} %-26s ${acc}IP:${rst}     %s\n" "${os}" "${ip:-n/a}"
  printf "  ${acc}Uptime:${rst} %-22s ${acc}Carga:${rst}  %s\n" "${up:-n/a}" "${load:-n/a}"
  printf "  ${acc}RAM:${rst} %-25s ${acc}Disco /:${rst} %s\n" "${mem:-n/a}" "${disk:-n/a}"
  printf "  ${dim}──────────────────────────────────────────────────────────────${rst}\n"
}
__sb_show_sysinfo
unset -f __sb_show_sysinfo
EOF
  install_if_changed "$tmp_info" "$SB_INFO_SCRIPT" 644 || true
else
  rm -f "$SB_INFO_SCRIPT"
fi

log "Fase 01 (preparación del sistema) completada."
