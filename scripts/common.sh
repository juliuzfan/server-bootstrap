#!/usr/bin/env bash
set -Eeuo pipefail

log()  { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

run_step() {
  local description="$1" script="$2"
  log "$description"
  bash "$script"
}

require_debian() {
  [[ -r /etc/os-release ]] || die "No se encuentra /etc/os-release."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "Este bootstrap está diseñado para Debian. Detectado: ${ID:-desconocido}"
  [[ "${VERSION_ID:-}" == "13" ]] || warn "Probado/diseñado inicialmente para Debian 13; detectado Debian ${VERSION_ID:-desconocido}."
}

validate_config() {
  : "${HOSTNAME:?Define HOSTNAME en config.env}"
  : "${TIMEZONE:?Define TIMEZONE en config.env}"
  : "${ADMIN_USER:?Define ADMIN_USER en config.env}"
  : "${SSH_PUBLIC_KEY:?Define SSH_PUBLIC_KEY en config.env}"
  : "${SSH_PORT:=22}"
  : "${ENABLE_UFW:=yes}"
  : "${ENABLE_FAIL2BAN:=yes}"
  : "${ENABLE_UNATTENDED_UPGRADES:=yes}"
  : "${CONFIRM_SSH_HARDENING:=NO}"

  [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die "HOSTNAME no válido."
  [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "ADMIN_USER no válido."
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT debe estar entre 1 y 65535."
  [[ "$SSH_PUBLIC_KEY" == ssh-ed25519\ * || "$SSH_PUBLIC_KEY" == ssh-rsa\ * || "$SSH_PUBLIC_KEY" == ecdsa-sha2-nistp256\ * ]] || die "SSH_PUBLIC_KEY no parece una llave pública OpenSSH válida."
  [[ "$ENABLE_UFW" =~ ^(yes|no)$ ]] || die "ENABLE_UFW debe ser yes o no."
  [[ "$ENABLE_FAIL2BAN" =~ ^(yes|no)$ ]] || die "ENABLE_FAIL2BAN debe ser yes o no."
  [[ "$ENABLE_UNATTENDED_UPGRADES" =~ ^(yes|no)$ ]] || die "ENABLE_UNATTENDED_UPGRADES debe ser yes o no."
}

backup_file() {
  local file="$1"
  if [[ -e "$file" ]]; then
    cp -a "$file" "${file}.bootstrap-$(date +%Y%m%d-%H%M%S).bak"
  fi
}
