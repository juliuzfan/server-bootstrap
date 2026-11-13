#!/usr/bin/env bash
# shellcheck shell=bash
# Funciones compartidas por bootstrap.sh y las fases. Se carga con `source`.

if [[ -n "${__SB_COMMON_LOADED:-}" ]]; then
  return 0
fi
__SB_COMMON_LOADED=1

set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# Rutas administradas por el bootstrap.
SB_STATE_DIR="/etc/server-bootstrap"
SB_STATE_FILE="${SB_STATE_DIR}/state"
SB_LOG_FILE="${SB_LOG_FILE:-/var/log/server-bootstrap.log}"
SB_SUDOERS_FILE="/etc/sudoers.d/90-server-bootstrap"
SB_SSH_DROPIN="/etc/ssh/sshd_config.d/00-server-bootstrap.conf"
SB_F2B_JAIL="/etc/fail2ban/jail.d/server-bootstrap.local"
SB_MOTD_FILE="/etc/motd"
SB_INFO_SCRIPT="/etc/profile.d/99-server-bootstrap-info.sh"
SB_PROMPT_FILE="${SB_STATE_DIR}/prompt.sh"
SB_RULE_COMMENT="server-bootstrap"
# Archivos de la versión anterior del repo (se migran/eliminan).
SB_LEGACY_SSH_DROPIN="/etc/ssh/sshd_config.d/00-bootstrap-hardening.conf"
SB_LEGACY_F2B_JAIL="/etc/fail2ban/jail.d/sshd-bootstrap.local"

SB_COLOR_NAMES="lime green cyan magenta pink orange yellow purple blue red rainbow synthwave toxic"
SB_ART_STYLES="claude hermes shadow block ascii"

# ---------------------------------------------------------------- salida ---
if [[ -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
  C_RED=$'\e[1;31m' C_GREEN=$'\e[1;32m' C_YELLOW=$'\e[1;33m' C_CYAN=$'\e[1;36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
fi

log()  { printf '\n%s[+] %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\n%s[!] %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
die()  { printf '\n%s[ERROR] %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

on_err() {
  local code=$1 line=$2 src=$3 cmd=$4
  printf '\n%s[ERROR] %s:%s: "%s" exited with code %s%s\n' \
    "$C_RED" "${src##*/}" "$line" "$cmd" "$code" "$C_RESET" >&2
}
trap 'on_err "$?" "$LINENO" "${BASH_SOURCE[0]:-$0}" "$BASH_COMMAND"' ERR

# Interactivo = hay terminal en stdin y no se pidió modo --yes.
is_interactive() {
  [[ -t 0 && "${BOOTSTRAP_NONINTERACTIVE:-0}" != "1" ]]
}

# Pide escribir YES literalmente. Úsala siempre dentro de `if`.
confirm_yes() {
  local answer
  if ! IFS= read -r -p "$1 Escribe YES: " answer; then
    return 1
  fi
  [[ "$answer" == "YES" ]]
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run with root privileges: sudo bash ${0##*/}"
  fi
}

require_debian() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  local id version
  id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  [[ "$id" == "debian" ]] || die "This bootstrap is designed for Debian. Detected: ${id:-unknown}"
  if [[ "$version" != "13" ]]; then
    warn "Designed for Debian 13; detected Debian ${version:-unknown}."
  fi
}

# ------------------------------------------------------------ utilidades ---
trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Comillas simples seguras para escribir valores en config.env.
shell_quote() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# Respaldo con fecha. Deja la ruta en SB_LAST_BACKUP (vacía si no había archivo).
backup_file() {
  local file=$1
  SB_LAST_BACKUP=""
  if [[ -e "$file" || -L "$file" ]]; then
    SB_LAST_BACKUP="${file}.bootstrap-$(date +%Y%m%d-%H%M%S).bak"
    cp -a "$file" "$SB_LAST_BACKUP"
  fi
}

# Instala $1 (temporal) en $2 solo si cambió; respalda el destino anterior.
# Devuelve 0 si instaló, 1 si no había cambios. Úsala dentro de `if`.
install_if_changed() {
  local src=$1 dest=$2 mode=$3
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    rm -f "$src"
    SB_LAST_BACKUP=""
    return 1
  fi
  backup_file "$dest"
  install -m "$mode" -o root -g root "$src" "$dest"
  rm -f "$src"
  return 0
}

pkg_installed() {
  [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]
}

# Instala solo los paquetes que falten.
ensure_packages() {
  local pkg
  local -a missing=()
  for pkg in "$@"; do
    if ! pkg_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log "Instalando paquetes: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${missing[@]}"
  fi
}

user_home() {
  getent passwd "$1" | cut -d: -f6
}

user_has_password() {
  local out status
  out="$(passwd -S "$1" 2>/dev/null)" || return 1
  read -r _ status _ <<<"$out"
  [[ "$status" == "P" ]]
}

# El usuario podrá usar sudo: grupo sudo + (NOPASSWD del bootstrap o contraseña usable).
sudo_ready() {
  local user=$1
  [[ " $(id -nG "$user" 2>/dev/null || true) " == *" sudo "* ]] || return 1
  if [[ -f "$SB_SUDOERS_FILE" ]] && grep -q "^${user}[[:space:]]" "$SB_SUDOERS_FILE"; then
    return 0
  fi
  user_has_password "$user"
}

# Puertos SSH según la configuración (sshd -T) y según lo que realmente escucha.
current_ssh_ports() {
  local cfg="" listening=""
  cfg="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true)"
  listening="$(ss -Hltnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}' || true)"
  printf '%s\n%s\n' "$cfg" "$listening" | awk 'NF' | sort -un | paste -sd' ' - || true
}

primary_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "${ip:-IP_DEL_SERVIDOR}"
}

# Detecta la IP pública/primaria del servidor (sin sufijo /CIDR).
detect_server_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "$ip"
}

# IP del cliente SSH que ejecuta sudo (se conserva en utmp aunque sudo limpie el entorno).
client_ip() {
  local line ip="" re='[(]([0-9A-Fa-f:.]+)[)][[:space:]]*$'
  line="$(who -m 2>/dev/null || true)"
  if [[ "$line" =~ $re ]]; then
    ip="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$ip"
}

wait_port_listen() {
  local port=$1 i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -n "$(ss -Hltn sport = ":${port}" 2>/dev/null || true)" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# ----------------------------------------------------------------- state ---
state_get() {
  local key=$1 line
  [[ -r "$SB_STATE_FILE" ]] || return 0
  while IFS= read -r line; do
    if [[ "$line" == "${key}="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"$SB_STATE_FILE"
  return 0
}

state_set() {
  local key=$1 value=$2 tmp
  install -d -m 755 "$SB_STATE_DIR"
  tmp="$(mktemp "${SB_STATE_DIR}/.state.XXXXXX")"
  if [[ -f "$SB_STATE_FILE" ]]; then
    grep -v "^${key}=" "$SB_STATE_FILE" >"$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$SB_STATE_FILE"
}

# ------------------------------------------------------------ validación ---
valid_hostname() {
  local h=$1 label
  local -a labels
  (( ${#h} >= 1 && ${#h} <= 253 )) || return 1
  [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$h" != .* && "$h" != *. && "$h" != *..* ]] || return 1
  IFS=. read -ra labels <<<"$h"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
  return 0
}

valid_timezone() {
  local tz=$1
  [[ "$tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  if [[ -d /usr/share/zoneinfo ]]; then
    [[ -f "/usr/share/zoneinfo/${tz}" ]] || return 1
  fi
  return 0
}

valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != "root" ]]
}

valid_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

valid_pubkey() {
  local key=$1 tmp rc=0
  local re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$'
  [[ "$key" != *$'\n'* && "$key" != *$'\r'* ]] || return 1
  [[ "$key" =~ $re ]] || return 1
  if command -v ssh-keygen >/dev/null 2>&1; then
    tmp="$(mktemp)"
    printf '%s\n' "$key" >"$tmp"
    ssh-keygen -l -f "$tmp" >/dev/null 2>&1 || rc=1
    rm -f "$tmp"
  fi
  return "$rc"
}

valid_yesno() {
  [[ "$1" == "yes" || "$1" == "no" ]]
}

valid_sudo_mode() {
  [[ "$1" == "password" || "$1" == "nopasswd" ]]
}

# Lista de reglas extra para UFW: "80/tcp 443/tcp 60000:61000/udp".
valid_ufw_ports() {
  local token a b
  local -a tokens
  read -ra tokens <<<"$1"
  for token in "${tokens[@]}"; do
    [[ "$token" =~ ^([1-9][0-9]{0,4})(:([1-9][0-9]{0,4}))?/(tcp|udp)$ ]] || return 1
    a=${BASH_REMATCH[1]}
    b=${BASH_REMATCH[3]:-$a}
    (( a <= 65535 && b <= 65535 && a <= b )) || return 1
  done
  return 0
}

# Lista de IPs o redes separadas por espacios.
valid_ip_list() {
  local token
  local -a tokens
  read -ra tokens <<<"$1"
  for token in "${tokens[@]}"; do
    [[ "$token" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ && "$token" == *[.:]* ]] || return 1
  done
  return 0
}

valid_single_ip() {
  local ip=$1
  [[ -z "$ip" ]] && return 0
  [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ && "$ip" == *[.:]* && "$ip" != 127.* && "$ip" != "::1" ]]
}

valid_time() {
  [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# Caracteres disponibles en la fuente ASCII art del MOTD.
valid_motd_text() {
  local re='^[A-Za-z0-9 ._!-]{0,40}$'
  [[ "$1" =~ $re ]]
}

valid_color() {
  [[ " $SB_COLOR_NAMES " == *" $1 "* ]]
}

valid_art_style() {
  [[ " $SB_ART_STYLES " == *" $1 "* ]]
}

valid_password_hash() {
  local re='^[$][0-9a-z]+[$][./A-Za-z0-9$=,]+$'
  [[ -z "$1" || "$1" =~ $re ]]
}

# ---------------------------------------------------------- configuración ---
load_config() {
  local file="${BOOTSTRAP_CONFIG:-${ROOT_DIR}/config.env}" mode
  [[ -f "$file" ]] || die "${file} does not exist. Create it with: sudo bash bootstrap.sh --wizard"
  mode="$(stat -c '%a' "$file")"
  if (( (8#$mode & 8#002) != 0 )); then
    die "${file} es escribible por cualquier usuario y se ejecuta como root. Corrige con: chmod 600 ${file}"
  fi
  # Compatibilidad: la versión anterior usaba HOSTNAME (variable reservada de bash).
  unset SERVER_HOSTNAME SSH_PUBLIC_KEY SSH_PUBLIC_KEYS
  # config.env es código shell: solo cargues un archivo que tú hayas creado/revisado.
  # shellcheck disable=SC1090
  source "$file"
  if [[ -z "${SERVER_HOSTNAME:-}" ]] && grep -Eq '^[[:space:]]*HOSTNAME=' "$file"; then
    warn "config.env uses HOSTNAME (deprecated); rename it to SERVER_HOSTNAME."
    SERVER_HOSTNAME="$HOSTNAME"
  fi
  CONFIG_FILE="$file"
}

# Aplica valores por defecto, normaliza y valida. Deja las llaves en SB_KEYS.
validate_config() {
  SERVER_HOSTNAME="${SERVER_HOSTNAME:-}"
  SERVER_IP="${SERVER_IP:-}"
  TIMEZONE="${TIMEZONE:-UTC}"
  ADMIN_USER="${ADMIN_USER:-}"
  SUDO_MODE="${SUDO_MODE:-password}"
  ADMIN_PASSWORD_HASH="${ADMIN_PASSWORD_HASH:-}"
  SSH_PORT="${SSH_PORT:-22}"
  ENABLE_UFW="${ENABLE_UFW:-yes}"
  EXTRA_UFW_PORTS="${EXTRA_UFW_PORTS:-}"
  ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-yes}"
  FAIL2BAN_IGNOREIP="${FAIL2BAN_IGNOREIP:-}"
  ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES:-yes}"
  AUTO_REBOOT="${AUTO_REBOOT:-no}"
  AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:00}"
  ENABLE_PROMPT="${ENABLE_PROMPT:-yes}"
  ENABLE_MOTD="${ENABLE_MOTD:-yes}"
  MOTD_TEXT="${MOTD_TEXT:-}"
  MOTD_COLOR="${MOTD_COLOR:-lime}"
  MOTD_ART_STYLE="${MOTD_ART_STYLE:-claude}"
  CONFIRM_SSH_HARDENING="${CONFIRM_SSH_HARDENING:-NO}"

  valid_hostname "$SERVER_HOSTNAME" || die "Invalid SERVER_HOSTNAME: '${SERVER_HOSTNAME}'."
  valid_single_ip "$SERVER_IP" || die "Invalid SERVER_IP: '${SERVER_IP}' (specify the server's public/primary IP or leave empty for auto-detection)."
  valid_timezone "$TIMEZONE" || die "Invalid TIMEZONE: '${TIMEZONE}' (e.g. America/Mexico_City)."
  valid_username "$ADMIN_USER" || die "Invalid ADMIN_USER: '${ADMIN_USER}' (lowercase, digits, _ or -; not root)."
  valid_sudo_mode "$SUDO_MODE" || die "SUDO_MODE must be password or nopasswd."
  valid_password_hash "$ADMIN_PASSWORD_HASH" || die "ADMIN_PASSWORD_HASH does not look like a crypt hash (e.g. output of 'openssl passwd -6')."
  valid_port "$SSH_PORT" || die "SSH_PORT must be between 1 and 65535."
  valid_ufw_ports "$EXTRA_UFW_PORTS" || die "Invalid EXTRA_UFW_PORTS. Format: '80/tcp 443/tcp 60000:61000/udp'."
  valid_ip_list "$FAIL2BAN_IGNOREIP" || die "FAIL2BAN_IGNOREIP must be a space-separated list of IPs/networks."
  valid_time "$AUTO_REBOOT_TIME" || die "AUTO_REBOOT_TIME must have HH:MM format."
  valid_motd_text "$MOTD_TEXT" || die "MOTD_TEXT allows up to 40 characters: letters, digits, space, and . _ ! -"
  valid_color "$MOTD_COLOR" || die "MOTD_COLOR must be one of: ${SB_COLOR_NAMES}."
  valid_art_style "$MOTD_ART_STYLE" || die "MOTD_ART_STYLE must be one of: ${SB_ART_STYLES}."
  [[ "$CONFIRM_SSH_HARDENING" == "YES" || "$CONFIRM_SSH_HARDENING" == "NO" ]] \
    || die "CONFIRM_SSH_HARDENING must be YES or NO."

  local var
  for var in ENABLE_UFW ENABLE_FAIL2BAN ENABLE_UNATTENDED_UPGRADES AUTO_REBOOT ENABLE_PROMPT ENABLE_MOTD; do
    valid_yesno "${!var}" || die "${var} must be yes or no."
  done

  # Llaves: SSH_PUBLIC_KEYS (array) + SSH_PUBLIC_KEY (formato anterior).
  local key
  SB_KEYS=()
  if declare -p SSH_PUBLIC_KEYS >/dev/null 2>&1; then
    for key in "${SSH_PUBLIC_KEYS[@]}"; do
      key="$(trim "$key")"
      if [[ -n "$key" ]]; then
        SB_KEYS+=("$key")
      fi
    done
  fi
  if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    SB_KEYS+=("$(trim "$SSH_PUBLIC_KEY")")
  fi
  (( ${#SB_KEYS[@]} > 0 )) || die "Define at least one key in SSH_PUBLIC_KEYS."
  for key in "${SB_KEYS[@]}"; do
    if [[ "$key" == *AAAA_REEMPLAZAR* || "$key" == *AAAA_REPLACE* ]]; then
      die "Replace the example key in SSH_PUBLIC_KEYS with your real public key."
    fi
    valid_pubkey "$key" || die "Invalid public key: '${key:0:40}...'"
  done
  return 0
}

# Paleta: un color 256 por cada fila del banner (hasta 6 filas).
motd_palette() {
  case "$1" in
    lime)      echo "118 118 118 118 118 118" ;;
    green)     echo "46 46 46 46 46 46" ;;
    cyan)      echo "51 51 51 51 51 51" ;;
    magenta)   echo "201 201 201 201 201 201" ;;
    pink)      echo "213 213 213 213 213 213" ;;
    orange)    echo "208 208 208 208 208 208" ;;
    yellow)    echo "226 226 226 226 226 226" ;;
    purple)    echo "141 141 141 141 141 141" ;;
    blue)      echo "39 39 39 39 39 39" ;;
    red)       echo "196 196 196 196 196 196" ;;
    rainbow)   echo "196 208 226 46 51 201" ;;
    synthwave) echo "201 171 135 99 51 45" ;;
    toxic)     echo "46 82 118 154 190 226" ;;
    *)         echo "118 118 118 118 118 118" ;;
  esac
}

# Color de acento (prompt e información del MOTD).
motd_accent() {
  case "$1" in
    rainbow)   echo 51 ;;
    synthwave) echo 201 ;;
    toxic)     echo 118 ;;
    *)         local -a p; read -ra p <<<"$(motd_palette "$1")"; echo "${p[0]}" ;;
  esac
}
