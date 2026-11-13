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
  sudo openssh-server ca-certificates curl wget git neovim nano htop
  locales sharutils chrony dnsutils iproute2 lsof procps
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

log "Reemplazando vim por Neovim a nivel de sistema"
if pkg_installed vim || pkg_installed vim-tiny; then
  apt-get purge -y vim vim-runtime vim-tiny >/dev/null 2>&1 || true
fi
if command -v nvim >/dev/null 2>&1; then
  nvim_bin="$(command -v nvim)"
  update-alternatives --install /usr/bin/vim vim "$nvim_bin" 110 >/dev/null 2>&1 || true
  update-alternatives --set vim "$nvim_bin" >/dev/null 2>&1 || true
  update-alternatives --install /usr/bin/editor editor "$nvim_bin" 110 >/dev/null 2>&1 || true
  update-alternatives --set editor "$nvim_bin" >/dev/null 2>&1 || true
  update-alternatives --install /usr/bin/vi vi "$nvim_bin" 110 >/dev/null 2>&1 || true
  update-alternatives --set vi "$nvim_bin" >/dev/null 2>&1 || true
fi

log "Asegurando locale en_US.UTF-8"
if [[ -f /etc/locale.gen ]]; then
  sed -i 's/^#[[:space:]]*\(en_US\.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen
  locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
fi

log "Configurando zona horaria (${TIMEZONE}) y hostname (${SERVER_HOSTNAME})"
if [[ "$(timedatectl show -p Timezone --value 2>/dev/null || true)" != "$TIMEZONE" ]]; then
  timedatectl set-timezone "$TIMEZONE"
fi
if [[ "$(hostnamectl --static 2>/dev/null || hostname)" != "$SERVER_HOSTNAME" ]]; then
  hostnamectl set-hostname "$SERVER_HOSTNAME"
fi

# Asegura que /etc/hosts tenga 127.0.1.1 y la IP pública del servidor apuntando al hostname elegido.
short_host="${SERVER_HOSTNAME%%.*}"
host_names="$SERVER_HOSTNAME"
if [[ "$short_host" != "$SERVER_HOSTNAME" ]]; then
  host_names="${SERVER_HOSTNAME} ${short_host}"
fi

effective_ip="${SERVER_IP:-$(detect_server_ip)}"
if ! valid_single_ip "$effective_ip"; then
  effective_ip=""
fi

tmp_hosts="$(mktemp)"
awk -v hnames="$host_names" -v pub_ip="$effective_ip" '
  BEGIN { done_local = 0; done_pub = 0 }
  /^[[:space:]]*127\.0\.1\.1[[:space:]]/ {
    if (!done_local) {
      printf "127.0.1.1\t%s\n", hnames
      done_local = 1
    }
    next
  }
  pub_ip != "" && $1 == pub_ip {
    if (!done_pub) {
      printf "%s\t%s\n", pub_ip, hnames
      done_pub = 1
    }
    next
  }
  /# server-bootstrap-host$/ { next }
  { print }
  END {
    if (!done_local) {
      printf "127.0.1.1\t%s\n", hnames
    }
    if (pub_ip != "" && !done_pub) {
      printf "%s\t%s # server-bootstrap-host\n", pub_ip, hnames
    }
  }
' /etc/hosts >"$tmp_hosts"
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

# ---------------------------------- .bashrc (root + admin) ---
install -d -m 755 "$SB_STATE_DIR"
accent_code="$(motd_accent "$MOTD_COLOR")"
rm -f "$SB_PROMPT_FILE"

install_user_bashrc() {
  local rc_file=$1 owner=$2
  local cur_year tmp_rc
  cur_year="$(date +%Y)"
  tmp_rc="$(mktemp)"

  printf '# Copyright (%s) - Roster.li\n# @website roster.li\n# Hostname: %s\n\n' \
    "$cur_year" "$SERVER_HOSTNAME" >"$tmp_rc"

  cat >>"$tmp_rc" <<'EOF'
# If not running interactively, don't do anything
case $- in
  *i*) ;;
  *) return ;;
esac

# Locales
export LANGUAGE=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Default editor
export EDITOR=nvim
export VISUAL=nvim

parse_git_branch() {
  #git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/(\1)/'
  git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ on \1/'
}

# Better Prompt
PS1='${debian_chroot:+($debian_chroot)}\[\e[1;31m\]\u\[\e[1;33m\]@\[\e[1;36m\]\H \[\e[1;33m\]\w \[\e[1;35m\]\$\[\033[32m\]$(parse_git_branch)\[\033[m\]\[\e[0m\] '

export LS_OPTIONS='--color=auto'
if command -v dircolors >/dev/null 2>&1; then
  eval "$(dircolors -b)"
fi

# Traversing Alias
alias ls='ls $LS_OPTIONS --group-directories-first'
alias ll='ls $LS_OPTIONS -l'
alias l='ls $LS_OPTIONS -lA'
alias c='clear'
alias ..='cd ..'
alias ...='cd ../../'

# Avoid making mistakes:
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Shortcuts
alias vim='nvim'
alias v='nvim'

# GIT
alias gst='git status'

# Password Generator
password_generator() {
  local pass len=${1:-20}
  if ! type uuencode >/dev/null 2>&1; then
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      apt-get update && apt-get install -y --no-install-recommends sharutils
    else
      sudo apt-get update && sudo apt-get install -y --no-install-recommends sharutils
    fi
  fi
  pass=$(dd if=/dev/urandom bs=256 count=1 2> /dev/null | uuencode -m - | sed -ne 2p | cut -c-"$len" | sed -e "s:/:%:g" -e "s/@/\$/g" -e "s/\"/#/g")
  echo "$pass"
}
EOF

  if [[ -f "$rc_file" ]] && ! cmp -s "$tmp_rc" "$rc_file"; then
    backup_file "$rc_file"
  fi
  install -m 644 -o "$owner" -g "$owner" "$tmp_rc" "$rc_file"
  rm -f "$tmp_rc"
}

log "Configurando .bashrc y prompt para root y ${ADMIN_USER}"
install_user_bashrc "/root/.bashrc" "root"
install_user_bashrc "${ADMIN_HOME}/.bashrc" "$ADMIN_USER"
install_user_bashrc "/etc/skel/.bashrc" "root"

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
