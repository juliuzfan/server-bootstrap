#!/usr/bin/env bash
# Orquestador remoto no interactivo para server-bootstrap (compatible con Bash 3.2+ en macOS/Linux).
# Ejecuta las fases 01, 02 (con transición segura de puerto) y 03 desde la máquina del agente/operador
# sin requerir git ni sshpass en el servidor destino y sin dejar contraseñas en logs o argumentos CLI.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------- salida ---
if [[ -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m' C_GREEN=$'\033[1;32m' C_YELLOW=$'\033[1;33m' C_RED=$'\033[1;31m' C_CYAN=$'\033[1;36m'
else
  C_RESET='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN=''
fi

log()  { printf '\n%s[+] %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\n%s[!] %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
die()  { printf '\n%s[ERROR] %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash scripts/remote-bootstrap.sh --host <IP_OR_DNS> [options]

Initial connection & secrets (passwords are NEVER passed as CLI flags):
  --host HOST                  Target Debian 13 server IP or DNS (required)
  --ssh-port PORT              Initial SSH port (default: 22)
  --ssh-user USER              Initial SSH user: root or sudo user (default: root)
  --ssh-key FILE               Private key for initial connection
  --admin-ssh-key FILE         Private key to verify the new ADMIN_USER (if different)
  --init-pass-file FILE        File (chmod 600) with initial SSH/sudo password (or env SB_INIT_PASS)
  --admin-pass-file FILE       File (chmod 600) with password for ADMIN_USER (or env SB_ADMIN_PASS)
  --prompt-init-pass           Open a native OS modal (macOS/Linux/Windows/WSL) to prompt for the initial password
  --prompt-admin-pass          Open a native OS modal to prompt and confirm the sudo password for ADMIN_USER

Server configuration (overrides --config if both are passed):
  --config FILE                Optional base config.env file
  --hostname NAME              SERVER_HOSTNAME (default: debian-server)
  --server-ip IP               SERVER_IP for /etc/hosts (default: auto-detect)
  --timezone TZ                IANA TIMEZONE (default: UTC)
  --admin-user USER            ADMIN_USER (default: adminops)
  --sudo-mode MODE             password | nopasswd (default: password)
  --admin-password-hash HASH   Pre-computed $6$... crypt hash (optional)
  --pubkey KEY_OR_FILE         OpenSSH public key or path to .pub (repeatable)
  --target-ssh-port PORT       Final SSH port (default: 22)
  --enable-ufw yes|no          Enable UFW (default: yes)
  --extra-ufw-ports PORTS      Extra UFW ports (e.g. "80/tcp 443/tcp")
  --enable-fail2ban yes|no     Enable Fail2Ban (default: yes)
  --fail2ban-ignoreip IPS      Fail2Ban whitelist
  --enable-unattended-upgrades yes|no (default: yes)
  --auto-reboot yes|no         Automatic reboot for kernel patches (default: no)
  --auto-reboot-time HH:MM     Automatic reboot time (default: 04:00)
  --enable-motd yes|no         Install ASCII Art MOTD (default: yes)
  --motd-text TEXT             Banner text (empty = SERVER_HOSTNAME)
  --motd-color COLOR           MOTD color (default: lime)
  --motd-style STYLE           MOTD design: claude|hermes|shadow|block|ascii (default: claude)

Other:
  --dry-run                    Validate initial connection, Debian OS, and show plan without applying changes
  --keep-remote-dir            Keep temporary directory on the target server
  -h, --help                   Show this help
EOF
}

shell_quote() {
  local s="${1//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

read_secret_file() {
  local f="$1"
  [[ -f "$f" ]] || die "No existe el archivo de secreto: ${f}"
  local val
  IFS= read -r val <"$f" || true
  printf '%s' "$val"
}

# --------------------------------------------------------------- defaults ---
HOST=""
INIT_SSH_PORT="22"
INIT_SSH_USER="root"
INIT_SSH_KEY=""
ADMIN_SSH_KEY=""
INIT_PASS_FILE="${SB_INIT_PASS_FILE:-}"
ADMIN_PASS_FILE="${SB_ADMIN_PASS_FILE:-}"
INIT_PASS="${SB_INIT_PASS:-}"
ADMIN_PASS="${SB_ADMIN_PASS:-}"
PROMPT_INIT_PASS=0
PROMPT_ADMIN_PASS=0
BASE_CONFIG=""

CFG_HOSTNAME=""
CFG_SERVER_IP=""
CFG_TIMEZONE=""
CFG_ADMIN_USER=""
CFG_SUDO_MODE=""
CFG_ADMIN_PASSWORD_HASH=""
CFG_TARGET_SSH_PORT=""
CFG_ENABLE_UFW=""
CFG_EXTRA_UFW_PORTS=""
CFG_ENABLE_FAIL2BAN=""
CFG_FAIL2BAN_IGNOREIP=""
CFG_ENABLE_UU=""
CFG_AUTO_REBOOT=""
CFG_AUTO_REBOOT_TIME=""
CFG_ENABLE_MOTD=""
CFG_MOTD_TEXT=""
CFG_MOTD_COLOR=""
CFG_MOTD_STYLE=""

PUBKEYS=()
DRY_RUN=0
KEEP_REMOTE_DIR=0

# Flags explícitos para saber qué sobreescribe a --config
SET_HOSTNAME=0 SET_SERVER_IP=0 SET_TIMEZONE=0 SET_ADMIN_USER=0
SET_SUDO_MODE=0 SET_ADMIN_HASH=0 SET_TARGET_PORT=0 SET_UFW=0
SET_EXTRA_UFW=0 SET_F2B=0 SET_F2B_IP=0 SET_UU=0 SET_REBOOT=0
SET_REBOOT_TIME=0 SET_MOTD=0 SET_MOTD_TEXT=0 SET_MOTD_COLOR=0 SET_MOTD_STYLE=0

while (( $# > 0 )); do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --ssh-port) INIT_SSH_PORT="$2"; shift 2 ;;
    --ssh-user) INIT_SSH_USER="$2"; shift 2 ;;
    --ssh-key) INIT_SSH_KEY="$2"; shift 2 ;;
    --admin-ssh-key) ADMIN_SSH_KEY="$2"; shift 2 ;;
    --init-pass-file) INIT_PASS_FILE="$2"; shift 2 ;;
    --admin-pass-file) ADMIN_PASS_FILE="$2"; shift 2 ;;
    --prompt-init-pass) PROMPT_INIT_PASS=1; shift ;;
    --prompt-admin-pass) PROMPT_ADMIN_PASS=1; shift ;;
    --config) BASE_CONFIG="$2"; shift 2 ;;
    --hostname) CFG_HOSTNAME="$2"; SET_HOSTNAME=1; shift 2 ;;
    --server-ip) CFG_SERVER_IP="$2"; SET_SERVER_IP=1; shift 2 ;;
    --timezone) CFG_TIMEZONE="$2"; SET_TIMEZONE=1; shift 2 ;;
    --admin-user) CFG_ADMIN_USER="$2"; SET_ADMIN_USER=1; shift 2 ;;
    --sudo-mode) CFG_SUDO_MODE="$2"; SET_SUDO_MODE=1; shift 2 ;;
    --admin-password-hash) CFG_ADMIN_PASSWORD_HASH="$2"; SET_ADMIN_HASH=1; shift 2 ;;
    --pubkey) PUBKEYS+=("$2"); shift 2 ;;
    --target-ssh-port) CFG_TARGET_SSH_PORT="$2"; SET_TARGET_PORT=1; shift 2 ;;
    --enable-ufw) CFG_ENABLE_UFW="$2"; SET_UFW=1; shift 2 ;;
    --extra-ufw-ports) CFG_EXTRA_UFW_PORTS="$2"; SET_EXTRA_UFW=1; shift 2 ;;
    --enable-fail2ban) CFG_ENABLE_FAIL2BAN="$2"; SET_F2B=1; shift 2 ;;
    --fail2ban-ignoreip) CFG_FAIL2BAN_IGNOREIP="$2"; SET_F2B_IP=1; shift 2 ;;
    --enable-unattended-upgrades) CFG_ENABLE_UU="$2"; SET_UU=1; shift 2 ;;
    --auto-reboot) CFG_AUTO_REBOOT="$2"; SET_REBOOT=1; shift 2 ;;
    --auto-reboot-time) CFG_AUTO_REBOOT_TIME="$2"; SET_REBOOT_TIME=1; shift 2 ;;
    --enable-motd) CFG_ENABLE_MOTD="$2"; SET_MOTD=1; shift 2 ;;
    --motd-text) CFG_MOTD_TEXT="$2"; SET_MOTD_TEXT=1; shift 2 ;;
    --motd-color) CFG_MOTD_COLOR="$2"; SET_MOTD_COLOR=1; shift 2 ;;
    --motd-style) CFG_MOTD_STYLE="$2"; SET_MOTD_STYLE=1; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --keep-remote-dir) KEEP_REMOTE_DIR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

[[ -n "$HOST" ]] || die "Debes especificar --host <IP_O_DNS>."
[[ -f "${ROOT_DIR}/bootstrap.sh" && -f "${ROOT_DIR}/scripts/01-system.sh" ]] \
  || die "server-bootstrap bundle not found in ${ROOT_DIR}."

command -v ssh >/dev/null 2>&1 || die "Se requiere el cliente 'ssh' en el equipo local."
command -v tar >/dev/null 2>&1 || die "Se requiere 'tar' en el equipo local."

if [[ -n "$INIT_PASS_FILE" && -z "$INIT_PASS" ]]; then
  INIT_PASS="$(read_secret_file "$INIT_PASS_FILE")"
fi
if [[ -n "$ADMIN_PASS_FILE" && -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$(read_secret_file "$ADMIN_PASS_FILE")"
fi
if [[ -n "$INIT_SSH_KEY" ]]; then
  [[ -f "$INIT_SSH_KEY" ]] || die "No existe la llave inicial: ${INIT_SSH_KEY}"
fi
if [[ -n "$ADMIN_SSH_KEY" ]]; then
  [[ -f "$ADMIN_SSH_KEY" ]] || die "No existe la llave privada de admin: ${ADMIN_SSH_KEY}"
fi

# Carga --config si se proporcionó y aplica defaults + overrides explícitos.
SERVER_HOSTNAME="debian-server"
SERVER_IP=""
TIMEZONE="UTC"
ADMIN_USER="adminops"
SUDO_MODE="password"
ADMIN_PASSWORD_HASH=""
SSH_PORT="22"
ENABLE_UFW="yes"
EXTRA_UFW_PORTS=""
ENABLE_FAIL2BAN="yes"
FAIL2BAN_IGNOREIP=""
ENABLE_UNATTENDED_UPGRADES="yes"
AUTO_REBOOT="no"
AUTO_REBOOT_TIME="04:00"
ENABLE_MOTD="yes"
MOTD_TEXT=""
MOTD_COLOR="lime"
MOTD_ART_STYLE="claude"
SSH_PUBLIC_KEYS=()

if [[ -n "$BASE_CONFIG" ]]; then
  [[ -f "$BASE_CONFIG" ]] || die "No existe --config: ${BASE_CONFIG}"
  # shellcheck disable=SC1090
  source "$BASE_CONFIG"
fi

(( SET_HOSTNAME )) && SERVER_HOSTNAME="$CFG_HOSTNAME"
(( SET_SERVER_IP )) && SERVER_IP="$CFG_SERVER_IP"
(( SET_TIMEZONE )) && TIMEZONE="$CFG_TIMEZONE"
(( SET_ADMIN_USER )) && ADMIN_USER="$CFG_ADMIN_USER"
(( SET_SUDO_MODE )) && SUDO_MODE="$CFG_SUDO_MODE"
(( SET_ADMIN_HASH )) && ADMIN_PASSWORD_HASH="$CFG_ADMIN_PASSWORD_HASH"
(( SET_TARGET_PORT )) && SSH_PORT="$CFG_TARGET_SSH_PORT"
(( SET_UFW )) && ENABLE_UFW="$CFG_ENABLE_UFW"
(( SET_EXTRA_UFW )) && EXTRA_UFW_PORTS="$CFG_EXTRA_UFW_PORTS"
(( SET_F2B )) && ENABLE_FAIL2BAN="$CFG_ENABLE_FAIL2BAN"
(( SET_F2B_IP )) && FAIL2BAN_IGNOREIP="$CFG_FAIL2BAN_IGNOREIP"
(( SET_UU )) && ENABLE_UNATTENDED_UPGRADES="$CFG_ENABLE_UU"
(( SET_REBOOT )) && AUTO_REBOOT="$CFG_AUTO_REBOOT"
(( SET_REBOOT_TIME )) && AUTO_REBOOT_TIME="$CFG_AUTO_REBOOT_TIME"
(( SET_MOTD )) && ENABLE_MOTD="$CFG_ENABLE_MOTD"
(( SET_MOTD_TEXT )) && MOTD_TEXT="$CFG_MOTD_TEXT"
(( SET_MOTD_COLOR )) && MOTD_COLOR="$CFG_MOTD_COLOR"
(( SET_MOTD_STYLE )) && MOTD_ART_STYLE="$CFG_MOTD_STYLE"

# Normaliza --pubkey (acepta llave en línea o ruta a archivo .pub).
RESOLVED_KEYS=()
if (( ${#PUBKEYS[@]} > 0 )); then
  for item in "${PUBKEYS[@]}"; do
    if [[ -f "$item" ]]; then
      while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        RESOLVED_KEYS+=("$line")
      done <"$item"
    else
      RESOLVED_KEYS+=("$item")
    fi
  done
elif (( ${#SSH_PUBLIC_KEYS[@]} > 0 )); then
  for item in "${SSH_PUBLIC_KEYS[@]}"; do
    [[ "$item" == *AAAA_REEMPLAZAR* ]] && continue
    RESOLVED_KEYS+=("$item")
  done
fi

(( ${#RESOLVED_KEYS[@]} > 0 )) || die "You must provide at least one public key (--pubkey or in --config)."

if [[ "$SUDO_MODE" == "password" && -z "$ADMIN_PASSWORD_HASH" && -z "$ADMIN_PASS" && "$PROMPT_ADMIN_PASS" -eq 0 ]]; then
  die "SUDO_MODE=password requiere --prompt-admin-pass, --admin-pass-file / SB_ADMIN_PASS o --admin-password-hash."
fi

# ---------------------------------------------- entorno temporal y cleanup ---
WORK_DIR="$(mktemp -d)"
chmod 700 "$WORK_DIR"
CTRL_SOCK="${WORK_DIR}/ctrl.sock"
REMOTE_DIR=""
SSH_AUTH_MODE="key"

cleanup() {
  local rc=$?
  set +e
  if [[ -S "$CTRL_SOCK" ]]; then
    ssh -o ControlPath="$CTRL_SOCK" -O exit "${INIT_SSH_USER}@${HOST}" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
  exit "$rc"
}
trap cleanup EXIT

# Si se solicitó captura modal (--prompt-init-pass / --prompt-admin-pass), abre el diálogo nativo del SO.
if (( PROMPT_INIT_PASS == 1 )) && [[ -z "$INIT_PASS" ]]; then
  log "Requesting initial password (${INIT_SSH_USER}@${HOST}) via secure OS dialog..."
  bash "${SCRIPT_DIR}/prompt-secret.sh" \
    --title "Server Bootstrap — Initial Access (${HOST})" \
    --prompt "Current password for '${INIT_SSH_USER}' to connect to ${HOST}:${INIT_SSH_PORT}:" \
    --out "${WORK_DIR}/prompted_init_pass"
  INIT_PASS="$(read_secret_file "${WORK_DIR}/prompted_init_pass")"
  rm -f "${WORK_DIR}/prompted_init_pass"
fi

if (( PROMPT_ADMIN_PASS == 1 )) && [[ -z "$ADMIN_PASS" ]]; then
  log "Requesting new sudo password for '${ADMIN_USER}' on ${HOST} via secure OS dialog..."
  bash "${SCRIPT_DIR}/prompt-secret.sh" \
    --title "Server Bootstrap — Sudo for ${ADMIN_USER} (${HOST})" \
    --prompt "Set the sudo password for user '${ADMIN_USER}' on ${HOST}:" \
    --confirm \
    --out "${WORK_DIR}/prompted_admin_pass"
  ADMIN_PASS="$(read_secret_file "${WORK_DIR}/prompted_admin_pass")"
  rm -f "${WORK_DIR}/prompted_admin_pass"
fi

# Prepara SSH_ASKPASS si se dio contraseña inicial (sin usar sshpass ni exponer en ps).
ASKPASS_BIN=""
if [[ -n "$INIT_PASS" ]]; then
  SSH_AUTH_MODE="password"
  printf '%s' "$INIT_PASS" >"${WORK_DIR}/init_pass"
  chmod 600 "${WORK_DIR}/init_pass"
  ASKPASS_BIN="${WORK_DIR}/askpass.sh"
  cat >"$ASKPASS_BIN" <<EOF
#!/usr/bin/env sh
cat "${WORK_DIR}/init_pass"
EOF
  chmod 700 "$ASKPASS_BIN"
fi

# Construye opciones SSH base para la sesión inicial.
init_ssh_exec() {
  local -a opts=(
    -p "$INIT_SSH_PORT"
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15
    -o ControlMaster=auto
    -o ControlPath="$CTRL_SOCK"
    -o ControlPersist=120
  )
  if [[ -n "$INIT_SSH_KEY" ]]; then
    opts+=(-i "$INIT_SSH_KEY" -o IdentitiesOnly=yes)
  fi
  if [[ "$SSH_AUTH_MODE" == "password" ]]; then
    opts+=(-o BatchMode=no -o PreferredAuthentications=password,keyboard-interactive,publickey)
    SSH_ASKPASS="$ASKPASS_BIN" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-none}" \
      ssh "${opts[@]}" "${INIT_SSH_USER}@${HOST}" "$@"
  else
    opts+=(-o BatchMode=yes)
    ssh "${opts[@]}" "${INIT_SSH_USER}@${HOST}" "$@"
  fi
}

# Ejecuta comandos como root en el servidor remoto (directo o vía sudo).
NEED_SUDO_PASS=0
run_remote_root() {
  local cmd="$1"
  if [[ "$INIT_SSH_USER" == "root" ]]; then
    init_ssh_exec "bash -s" <<EOF
set -euo pipefail
$cmd
EOF
  elif (( NEED_SUDO_PASS == 0 )); then
    init_ssh_exec "sudo -n bash -s" <<EOF
set -euo pipefail
$cmd
EOF
  else
    {
      printf '%s\n' "$INIT_PASS"
      cat <<EOF
set -euo pipefail
$cmd
EOF
    } | init_ssh_exec "sudo -S -p '' bash -s"
  fi
}

# Prueba una conexión SSH completamente independiente (sin ControlMaster) como ADMIN_USER.
test_admin_ssh() {
  local port="$1" remote_cmd="$2"
  local -a opts=(
    -p "$port"
    -o ControlMaster=no
    -o ControlPath=none
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15
  )
  if [[ -n "$ADMIN_SSH_KEY" ]]; then
    opts+=(-i "$ADMIN_SSH_KEY" -o IdentitiesOnly=yes)
  fi
  ssh "${opts[@]}" "${ADMIN_USER}@${HOST}" "$remote_cmd"
}

# ----------------------------------------------------------- 1. Preflight ---
log "1/5 Verifying initial connection (${INIT_SSH_USER}@${HOST}:${INIT_SSH_PORT})"
if ! remote_os="$(init_ssh_exec ". /etc/os-release 2>/dev/null && printf '%s:%s' \"\${ID:-unknown}\" \"\${VERSION_ID:-unknown}\"")"; then
  die "Could not connect via SSH to ${INIT_SSH_USER}@${HOST}:${INIT_SSH_PORT}. Check IP/DNS, port, or initial credentials."
fi
info "Detected OS: ${remote_os}"
if [[ "${remote_os%%:*}" != "debian" ]]; then
  die "Target server is not Debian (${remote_os})."
fi

if [[ "$INIT_SSH_USER" != "root" ]]; then
  if init_ssh_exec "sudo -n true" >/dev/null 2>&1; then
    info "Passwordless sudo privileges verified for ${INIT_SSH_USER}."
  elif [[ -n "$INIT_PASS" ]] && printf '%s\n' "$INIT_PASS" | init_ssh_exec "sudo -S -p '' true" >/dev/null 2>&1; then
    NEED_SUDO_PASS=1
    info "Password-based sudo privileges verified for ${INIT_SSH_USER}."
  else
    die "Initial user '${INIT_SSH_USER}' does not have working sudo (neither passwordless nor with SB_INIT_PASS)."
  fi
fi

if (( DRY_RUN == 1 )); then
  log "[DRY-RUN] Preflight succeeded. Configuration plan:"
  info "Host: ${HOST} (initial: ${INIT_SSH_USER}@:${INIT_SSH_PORT})"
  info "Hostname: ${SERVER_HOSTNAME} | Timezone: ${TIMEZONE}"
  info "Admin user: ${ADMIN_USER} (sudo: ${SUDO_MODE}, keys: ${#RESOLVED_KEYS[@]})"
  info "Final SSH port: ${SSH_PORT} | UFW: ${ENABLE_UFW} (${EXTRA_UFW_PORTS:-SSH only}) | Fail2Ban: ${ENABLE_FAIL2BAN}"
  info "MOTD: ${ENABLE_MOTD} (${MOTD_COLOR}/${MOTD_ART_STYLE})"
  exit 0
fi

# --------------------------------------------- 2. Upload bundle + config ---
log "2/5 Preparing configuration and uploading scripts to server"

if [[ "$SUDO_MODE" == "password" && -z "$ADMIN_PASSWORD_HASH" ]]; then
  ADMIN_PASSWORD_HASH="$(printf '%s\n' "$ADMIN_PASS" | init_ssh_exec "openssl passwd -6 -stdin")"
  [[ "$ADMIN_PASSWORD_HASH" == \$6\$* ]] || die "Could not generate SHA-512 password hash on the remote server."
fi

LOCAL_CFG="${WORK_DIR}/config.env"
{
  printf '# Generado por remote-bootstrap.sh\n'
  printf 'SERVER_HOSTNAME=%s\n' "$(shell_quote "$SERVER_HOSTNAME")"
  printf 'SERVER_IP=%s\n' "$(shell_quote "$SERVER_IP")"
  printf 'TIMEZONE=%s\n' "$(shell_quote "$TIMEZONE")"
  printf 'ADMIN_USER=%s\n' "$(shell_quote "$ADMIN_USER")"
  printf 'SUDO_MODE=%s\n' "$(shell_quote "$SUDO_MODE")"
  printf 'ADMIN_PASSWORD_HASH=%s\n' "$(shell_quote "$ADMIN_PASSWORD_HASH")"
  printf 'SSH_PUBLIC_KEYS=(\n'
  for k in "${RESOLVED_KEYS[@]}"; do
    printf '  %s\n' "$(shell_quote "$k")"
  done
  printf ')\n'
  printf 'SSH_PORT=%s\n' "$(shell_quote "$SSH_PORT")"
  printf 'ENABLE_UFW=%s\n' "$(shell_quote "$ENABLE_UFW")"
  printf 'EXTRA_UFW_PORTS=%s\n' "$(shell_quote "$EXTRA_UFW_PORTS")"
  printf 'ENABLE_FAIL2BAN=%s\n' "$(shell_quote "$ENABLE_FAIL2BAN")"
  printf 'FAIL2BAN_IGNOREIP=%s\n' "$(shell_quote "$FAIL2BAN_IGNOREIP")"
  printf 'ENABLE_UNATTENDED_UPGRADES=%s\n' "$(shell_quote "$ENABLE_UNATTENDED_UPGRADES")"
  printf 'AUTO_REBOOT=%s\n' "$(shell_quote "$AUTO_REBOOT")"
  printf 'AUTO_REBOOT_TIME=%s\n' "$(shell_quote "$AUTO_REBOOT_TIME")"
  printf 'ENABLE_MOTD=%s\n' "$(shell_quote "$ENABLE_MOTD")"
  printf 'MOTD_TEXT=%s\n' "$(shell_quote "$MOTD_TEXT")"
  printf 'MOTD_COLOR=%s\n' "$(shell_quote "$MOTD_COLOR")"
  printf 'MOTD_ART_STYLE=%s\n' "$(shell_quote "$MOTD_ART_STYLE")"
  printf 'CONFIRM_SSH_HARDENING=%s\n' "'NO'"
} >"$LOCAL_CFG"
chmod 600 "$LOCAL_CFG"

REMOTE_DIR="$(init_ssh_exec "d=\$(mktemp -d /tmp/server-bootstrap.XXXXXX) && chmod 700 \"\$d\" && printf '%s' \"\$d\"")"
[[ -n "$REMOTE_DIR" ]] || die "Could not create remote temporary directory."

tar -C "$ROOT_DIR" -cf - bootstrap.sh config.env.example scripts | init_ssh_exec "tar -C '${REMOTE_DIR}' -xf -"
init_ssh_exec "umask 077 && cat >'${REMOTE_DIR}/config.env' && chmod 600 '${REMOTE_DIR}/config.env'" <"$LOCAL_CFG"

# ----------------------------------------------------------- 3. Fase 01 ---
log "3/5 Running Phase 01 (system, user ${ADMIN_USER}, SSH keys, and MOTD)"
run_remote_root "env BOOTSTRAP_NONINTERACTIVE=1 BOOTSTRAP_CONFIG='${REMOTE_DIR}/config.env' bash '${REMOTE_DIR}/scripts/01-system.sh'"

active_ssh_port="$(run_remote_root "sshd -T 2>/dev/null | awk '\$1==\"port\"{print \$2; exit}'" || true)"
active_ssh_port="${active_ssh_port:-$INIT_SSH_PORT}"

log "Checking independent external connection as ${ADMIN_USER}@${HOST}:${active_ssh_port}"
if ! test_admin_ssh "$active_ssh_port" "true"; then
  die "PHASE 01 CHECK FAILED: Could not log in via key-based SSH as ${ADMIN_USER}@${HOST}:${active_ssh_port}. SSH hardening was NOT applied (your initial access remains intact)."
fi
info "Key-based SSH login verified for ${ADMIN_USER}."

if [[ "$SUDO_MODE" == "nopasswd" ]]; then
  if ! test_admin_ssh "$active_ssh_port" "sudo -n true"; then
    die "SUDO CHECK FAILED: ${ADMIN_USER} logged in via SSH but 'sudo -n true' failed. SSH was NOT hardened."
  fi
  info "Passwordless sudo access (NOPASSWD) verified."
elif [[ -n "$ADMIN_PASS" ]]; then
  if ! printf '%s\n' "$ADMIN_PASS" | test_admin_ssh "$active_ssh_port" "sudo -S -p '' -v"; then
    die "SUDO CHECK FAILED: ${ADMIN_USER} logged in via SSH but the sudo password did not work. SSH was NOT hardened."
  fi
  info "Password-based sudo access verified."
else
  if ! test_admin_ssh "$active_ssh_port" "id -nG | grep -qw sudo"; then
    die "SUDO CHECK FAILED: ${ADMIN_USER} is not in the sudo group."
  fi
  info "sudo group verified (password set via external hash)."
fi

# ----------------------------------------------------------- 4. Phase 02 ---
log "4/5 Running Phase 02 (SSH hardening, UFW, and Fail2Ban)"
run_remote_root "sed -i \"s/^CONFIRM_SSH_HARDENING=.*/CONFIRM_SSH_HARDENING='YES'/\" '${REMOTE_DIR}/config.env'"

if [[ "$SSH_PORT" != "$active_ssh_port" ]]; then
  info "Port change detected (${active_ssh_port} -> ${SSH_PORT}): starting safe two-step transition."
  run_remote_root "env BOOTSTRAP_NONINTERACTIVE=1 BOOTSTRAP_CONFIG='${REMOTE_DIR}/config.env' bash '${REMOTE_DIR}/scripts/02-security.sh' --transition-only"

  log "Checking external connection on new SSH port ${SSH_PORT}/tcp"
  if ! test_admin_ssh "$SSH_PORT" "true"; then
    die "PORT ${SSH_PORT} CHECK FAILED: Server is not responding to SSH on ${HOST}:${SSH_PORT}. Both ports (${active_ssh_port} and ${SSH_PORT}) were kept open to prevent lockout. Check your cloud provider firewall (Security Group) and re-run."
  fi
  info "Connection on new port ${SSH_PORT}/tcp verified. Closing old port (${active_ssh_port})..."
fi

run_remote_root "env BOOTSTRAP_NONINTERACTIVE=1 BOOTSTRAP_CONFIG='${REMOTE_DIR}/config.env' bash '${REMOTE_DIR}/scripts/02-security.sh'"

# ----------------------------------------------------------- 5. Phase 03 ---
log "5/5 Running Phase 03 (final verification)"
run_remote_root "env BOOTSTRAP_NONINTERACTIVE=1 BOOTSTRAP_CONFIG='${REMOTE_DIR}/config.env' bash '${REMOTE_DIR}/scripts/03-verify.sh'"

if (( KEEP_REMOTE_DIR == 0 )); then
  run_remote_root "rm -rf '${REMOTE_DIR}'" || warn "Could not remove ${REMOTE_DIR} on the server."
fi

log "Remote bootstrap completed successfully."
if [[ -n "$ADMIN_SSH_KEY" ]]; then
  info "Access command: ssh -p ${SSH_PORT} -i ${ADMIN_SSH_KEY} ${ADMIN_USER}@${HOST}"
else
  info "Access command: ssh -p ${SSH_PORT} ${ADMIN_USER}@${HOST}"
fi
