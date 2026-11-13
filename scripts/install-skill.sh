#!/usr/bin/env bash
# Instala el skill 'server-bootstrap' de forma global para que agentes de IA puedan usarlo
# desde cualquier directorio o proyecto (Antigravity, Claude Code, Codex, Gemini CLI, etc.).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SKILL_SRC="${ROOT_DIR}/.agents/skills/server-bootstrap/SKILL.md"

usage() {
  cat <<'EOF'
Uso: bash scripts/install-skill.sh [opciones]

Instala el skill 'server-bootstrap' junto con el paquete mínimo de scripts
(bootstrap.sh, config.env.example, scripts/) para uso global desde cualquier workspace.

Opciones:
  --target DIR   Instala en un directorio específico de skills (ej. ~/.claude/skills/server-bootstrap)
  --all          Instala en ~/.gemini/config/skills/server-bootstrap y ~/.agents/skills/server-bootstrap (por defecto)
  -h, --help     Muestra esta ayuda
EOF
}

TARGETS=()
while (( $# > 0 )); do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || { echo "Falta argumento para --target" >&2; exit 1; }
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
      echo "Opción desconocida: $1" >&2
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

[[ -f "$SKILL_SRC" ]] || { echo "No se encontró ${SKILL_SRC}" >&2; exit 1; }

install_one() {
  local dest="$1"
  mkdir -p "${dest}/scripts"
  cp -f "$SKILL_SRC" "${dest}/SKILL.md"
  cp -f "${ROOT_DIR}/bootstrap.sh" "${dest}/bootstrap.sh"
  cp -f "${ROOT_DIR}/config.env.example" "${dest}/config.env.example"
  cp -f "${ROOT_DIR}/scripts/"*.sh "${dest}/scripts/"
  chmod +x "${dest}/bootstrap.sh" "${dest}/scripts/"*.sh
  printf '[OK] Skill instalado en: %s\n' "$dest"
}

for t in "${TARGETS[@]}"; do
  install_one "$t"
done

