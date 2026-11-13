# Guía para Agentes IA

Este repositorio incluye soporte nativo para aprovisionar servidores **Debian 13** de forma autónoma y remota sin usar el asistente TUI interactivo.

- **Skill principal**: [.agents/skills/server-bootstrap/SKILL.md](.agents/skills/server-bootstrap/SKILL.md) — Léelo y sigue su flujo completo antes de ejecutar comandos.
- **Orquestador remoto**: `scripts/remote-bootstrap.sh` — Ejecuta desde tu máquina local las fases `01-system.sh`, `02-security.sh` (con transición segura de puerto) y `03-verify.sh` realizando pruebas de conexión SSH + `sudo` entre fases.
- **Instalación global del skill**: `bash scripts/install-skill.sh` — Permite invocar el skill desde cualquier otro workspace.

## Reglas clave
1. No ejecutes `bootstrap.sh` en modo interactivo ni pases contraseñas por argumentos de línea de comandos.
2. Usa archivos temporales `chmod 600` (`--init-pass-file` / `--admin-pass-file`) o variables de entorno (`SB_INIT_PASS` / `SB_ADMIN_PASS`) para secretos.
3. Nunca ejecutes `02-security.sh` sin pasar por la comprobación externa de SSH + `sudo` de `remote-bootstrap.sh`.

