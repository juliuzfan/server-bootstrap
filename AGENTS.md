# Guía para Agentes IA

Este repositorio incluye soporte nativo para aprovisionar servidores **Debian 13** de forma autónoma y remota sin usar el asistente TUI interactivo.

- **Skill principal**: [.agents/skills/server-bootstrap/SKILL.md](.agents/skills/server-bootstrap/SKILL.md) — Léelo y sigue su flujo completo antes de ejecutar comandos.
- **Orquestador remoto**: `scripts/remote-bootstrap.sh` — Ejecuta desde tu máquina local las fases `01-system.sh`, `02-security.sh` (con transición segura de puerto) y `03-verify.sh` realizando pruebas de conexión SSH + `sudo` entre fases.
- **Captura modal de contraseñas (macOS / Linux / Windows / WSL)**: `scripts/prompt-secret.sh` (o las banderas `--prompt-init-pass` y `--prompt-admin-pass` de `remote-bootstrap.sh`) — Muestra un diálogo nativo del SO con entrada oculta y guarda el secreto en un archivo temporal `chmod 600` sin exponerlo en stdout/stderr ni en el contexto del agente.
- **Instalación global del skill**: `bash scripts/install-skill.sh` — Permite invocar el skill desde cualquier otro workspace.

## Reglas clave
1. No ejecutes `bootstrap.sh` en modo interactivo ni pidas contraseñas por el chat ni las pases por argumentos de línea de comandos.
2. Usa `--prompt-init-pass` / `--prompt-admin-pass` (o `scripts/prompt-secret.sh` hacia archivos temporales `chmod 600` con `--init-pass-file` / `--admin-pass-file`) para capturar contraseñas directamente del usuario mediante un modal nativo del SO.
3. Ejecuta `remote-bootstrap.sh` y `prompt-secret.sh` **fuera del sandbox del harness** (`BypassSandbox: true` en Antigravity, `with_escalated_permissions: true` en Codex) para permitir tanto la conexión SSH como el acceso al servidor gráfico del SO (`WindowServer` / X11 / WinForms).
4. Nunca ejecutes `02-security.sh` sin pasar por la comprobación externa de SSH + `sudo` de `remote-bootstrap.sh`.
