#!/usr/bin/env bash
# shellcheck shell=bash
# Main orchestrator for Debian 13 Server Bootstrap (with guided TUI wizard and CI/CD mode).
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR

# shellcheck source=scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"
# shellcheck source=scripts/tui.sh
source "${ROOT_DIR}/scripts/tui.sh"

usage() {
  cat <<'EOF'
Usage: sudo bash bootstrap.sh [options]

Options:
  -w, --wizard       Run the interactive TUI wizard to create/edit config.env.
  -c, --config FILE  Path to configuration file (default: ./config.env).
  -y, --yes          Non-interactive mode (automation / cloud-init; requires CONFIRM_SSH_HARDENING=YES
                     in config.env to run phase 02).
  -h, --help         Show this help.
EOF
}

FORCE_WIZARD=0
BOOTSTRAP_NONINTERACTIVE="${BOOTSTRAP_NONINTERACTIVE:-0}"
BOOTSTRAP_CONFIG="${BOOTSTRAP_CONFIG:-${ROOT_DIR}/config.env}"

while (( $# > 0 )); do
  case "$1" in
    -w|--wizard)
      FORCE_WIZARD=1
      shift
      ;;
    -c|--config)
      [[ $# -ge 2 ]] || die "Missing argument for $1"
      BOOTSTRAP_CONFIG="$2"
      shift 2
      ;;
    -y|--yes|--non-interactive)
      BOOTSTRAP_NONINTERACTIVE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)"
      ;;
  esac
done

export BOOTSTRAP_NONINTERACTIVE BOOTSTRAP_CONFIG

require_root
require_debian

# Log all execution output to /var/log/server-bootstrap.log without losing screen output.
if [[ -z "${__SB_LOGGING_ACTIVE:-}" ]]; then
  export __SB_LOGGING_ACTIVE=1
  mkdir -p "$(dirname "$SB_LOG_FILE")"
  touch "$SB_LOG_FILE"
  chmod 600 "$SB_LOG_FILE"
  exec > >(tee -a "$SB_LOG_FILE") 2>&1
fi

# If config.env does not exist (or --wizard was requested), launch the guided TUI wizard.
if (( FORCE_WIZARD == 1 )) || [[ ! -f "$BOOTSTRAP_CONFIG" ]]; then
  if is_interactive; then
    run_config_wizard "$BOOTSTRAP_CONFIG"
  else
    die "${BOOTSTRAP_CONFIG} does not exist. In non-interactive mode you must provide it beforehand."
  fi
elif is_interactive; then
  # If config.env still has the example placeholder key, offer to open the wizard.
  if grep -q 'AAAA_REEMPLAZAR\|AAAA_REPLACE' "$BOOTSTRAP_CONFIG" 2>/dev/null; then
    warn "${BOOTSTRAP_CONFIG} still contains template placeholder values."
    run_config_wizard "$BOOTSTRAP_CONFIG"
  else
    tui_banner "Debian 13 Server Bootstrap" "Detected file: ${BOOTSTRAP_CONFIG}"
    tui_select "How would you like to continue?" "run" \
      "run|Use the current config.env configuration and continue" \
      "wizard|Open the guided TUI wizard to review/modify options" \
      "cancel|Exit without making changes"
    case "$TUI_REPLY" in
      wizard) run_config_wizard "$BOOTSTRAP_CONFIG" ;;
      cancel) echo "Cancelled."; exit 0 ;;
    esac
  fi
fi

load_config
validate_config

banner_preview="${MOTD_TEXT:-$SERVER_HOSTNAME}"
render_ascii_banner "$banner_preview" "$MOTD_COLOR" "$MOTD_ART_STYLE"

echo "=================================================================="
echo " Execution Summary (log: ${SB_LOG_FILE})"
echo "------------------------------------------------------------------"
echo " Hostname / IP:    ${SERVER_HOSTNAME} (${SERVER_IP:-$(detect_server_ip)}) [${TIMEZONE}]"
echo " Admin user:       ${ADMIN_USER} (sudo: ${SUDO_MODE}, keys: ${#SB_KEYS[@]})"
echo " Final SSH port:   ${SSH_PORT}/tcp"
echo " UFW Firewall:     ${ENABLE_UFW} ${EXTRA_UFW_PORTS:+(extra: ${EXTRA_UFW_PORTS})}"
echo " Fail2Ban:         ${ENABLE_FAIL2BAN} ${FAIL2BAN_IGNOREIP:+(ignoreip: ${FAIL2BAN_IGNOREIP})}"
echo " Auto-upgrades:    ${ENABLE_UNATTENDED_UPGRADES} (auto-reboot: ${AUTO_REBOOT})"
echo " Shell & MOTD:     .bashrc Roster.li (active), motd=${ENABLE_MOTD} (${MOTD_COLOR}/${MOTD_ART_STYLE})"
echo "=================================================================="

if is_interactive; then
  echo "Make sure you have access to your provider's web console for safety."
  confirm_yes "Start Phase 01 (system preparation)?" || { echo "Cancelled."; exit 0; }
fi

log "Running Phase 01: System preparation"
bash "${ROOT_DIR}/scripts/01-system.sh"

# Check which port sshd is currently listening on to give the exact instruction.
active_ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
active_ssh_port="${active_ssh_port:-22}"
srv_ip="$(primary_ip)"

if is_interactive; then
  echo
  echo "=================================================================="
  echo " MANDATORY TEST BEFORE HARDENING SSH (Phase 02)"
  echo "------------------------------------------------------------------"
  echo " 1. Open ANOTHER terminal without closing this session."
  echo " 2. Verify that you can log in with your SSH key and that sudo works:"
  echo "      ssh -p ${active_ssh_port} ${ADMIN_USER}@${srv_ip}"
  echo "      sudo -v"
  if [[ "$SSH_PORT" != "$active_ssh_port" ]]; then
    echo " 3. Note: switching to port ${SSH_PORT} will be done safely"
    echo "    during the next step (both ports open until confirmed)."
  fi
  echo "=================================================================="
  if ! confirm_yes "Do you confirm that key login and sudo worked in another terminal?"; then
    warn "SSH was left unhardened. Once verified, run:"
    echo "  sudo bash scripts/02-security.sh"
    echo "  sudo bash scripts/03-verify.sh"
    exit 0
  fi
  CONFIRM_SSH_HARDENING="YES"
  export CONFIRM_SSH_HARDENING
  write_config_file "$BOOTSTRAP_CONFIG"
elif [[ "$CONFIRM_SSH_HARDENING" != "YES" ]]; then
  warn "Non-interactive mode with CONFIRM_SSH_HARDENING=${CONFIRM_SSH_HARDENING}: skipping Phase 02."
  exit 0
fi

log "Running Phase 02: SSH hardening, UFW, and Fail2Ban"
bash "${ROOT_DIR}/scripts/02-security.sh"

log "Running Phase 03: Final verification"
bash "${ROOT_DIR}/scripts/03-verify.sh"

echo
echo "Bootstrap completed successfully. Keep your current session open until you test a new connection."
