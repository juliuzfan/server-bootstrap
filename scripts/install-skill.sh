#!/usr/bin/env bash
# Installs the 'server-bootstrap' skill globally so AI agents can use it
# from any directory or project (Antigravity, Claude Code, Codex, Gemini CLI, etc.).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SKILL_SRC="${ROOT_DIR}/.agents/skills/server-bootstrap/SKILL.md"

usage() {
  cat <<'EOF'
Usage: bash scripts/install-skill.sh [options]

Installs the 'server-bootstrap' skill along with the minimal script bundle
(bootstrap.sh, config.env.example, scripts/) for global use from any workspace.

Options:
  --target DIR   Install into a specific skills directory (e.g. ~/.claude/skills/server-bootstrap)
  --all          Install into ~/.gemini/config/skills/server-bootstrap and ~/.agents/skills/server-bootstrap (default)
  -h, --help     Show this help
EOF
}

TARGETS=()
while (( $# > 0 )); do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || { echo "Missing argument for --target" >&2; exit 1; }
      TARGETS+=("$2")
      shift 2
      ;;
    --all)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if (( ${#TARGETS[@]} == 0 )); then
  TARGETS=(
    "${HOME}/.gemini/config/skills/server-bootstrap"
    "${HOME}/.agents/skills/server-bootstrap"
  )
fi

[[ -f "$SKILL_SRC" ]] || { echo "Not found: ${SKILL_SRC}" >&2; exit 1; }

install_one() {
  local dest="$1"
  mkdir -p "${dest}/scripts"
  cp -f "$SKILL_SRC" "${dest}/SKILL.md"
  cp -f "${ROOT_DIR}/bootstrap.sh" "${dest}/bootstrap.sh"
  cp -f "${ROOT_DIR}/config.env.example" "${dest}/config.env.example"
  cp -f "${ROOT_DIR}/scripts/"*.sh "${dest}/scripts/"
  chmod +x "${dest}/bootstrap.sh" "${dest}/scripts/"*.sh
  printf '[OK] Skill installed at: %s\n' "$dest"
}

for t in "${TARGETS[@]}"; do
  install_one "$t"
done
