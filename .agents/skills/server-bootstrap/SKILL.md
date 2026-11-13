---
name: server-bootstrap
description: >-
  Provisiona y endurece servidores Debian 13 remotos de forma autónoma y segura por SSH
  (con usuario root o no-root con sudo, autenticación por llave o contraseña).
  Úsalo cuando el usuario pida configurar, inicializar, asegurar o hacer bootstrap de un
  servidor Debian/VPS pasando su IP o DNS, credenciales iniciales y preferencias.
---

# Server Bootstrap (Agente Autónomo)

Este skill guía al agente para configurar un servidor **Debian 13** remoto de manera desatendida mediante [remote-bootstrap.sh](../../../scripts/remote-bootstrap.sh), evitando el TUI interactivo y garantizando que nunca se pierda el acceso SSH ni se expongan contraseñas en el contexto del LLM.

## Localización del orquestador y utilidades

Busca `remote-bootstrap.sh` y `prompt-secret.sh` en el primer path disponible:
1. `./scripts/remote-bootstrap.sh` y `./scripts/prompt-secret.sh` (cuando este skill está instalado globalmente con su bundle).
2. `../../../scripts/remote-bootstrap.sh` y `../../../scripts/prompt-secret.sh` relativo a este `SKILL.md` (dentro del repositorio `server-bootstrap`).
3. `./scripts/remote-bootstrap.sh` en el workspace actual si estás dentro del repo.

---

## Flujo de Trabajo Obligatorio

### Paso 1: Recopilar datos mínimos (preguntar solo lo que falte en el prompt)

No hagas preguntas redundantes sobre lo que el humano ya indicó, pero **sí confirma** cualquier punto faltante antes de ejecutar:

1. **Destino y acceso inicial**:
   - IP o DNS (`--host`).
   - Puerto SSH inicial (`--ssh-port`, defecto `22`).
   - Usuario inicial (`--ssh-user`, defecto `root`; usar `debian`, `admin`, etc. si el proveedor no habilita `root` directo).
   - Credencial inicial: ruta a llave privada (`--ssh-key`) o contraseña inicial (se solicitará mediante **modal nativo del SO** con `--prompt-init-pass`; **jamás pidas que la escriba en el chat**).
2. **Llave SSH pública para el nuevo `ADMIN_USER`**:
   - Si el humano ya dio una llave pública (o ruta `.pub`), úsala.
   - Si **no** la dio: revisa qué llaves públicas existen en `~/.ssh/*.pub` y pregunta al humano si prefiere:
     - **(a)** Usar una llave existente del sistema (mostrando la ruta detectada), o
     - **(b)** Generar un par de llaves `ed25519` dedicado para ese servidor (ej. `~/.ssh/id_ed25519_<hostname>` con `ssh-keygen -t ed25519 -N "" -f ... -C ...`).
3. **Usuario administrador y contraseña (`SUDO_MODE`)**:
   - Confirma `ADMIN_USER` (defecto `adminops`) y `SUDO_MODE` (`password` o `nopasswd`).
   - Si `SUDO_MODE="password"` y el humano no proporcionó hash:
     - Pregunta si **quiere ingresar su propia contraseña en una ventana modal segura del sistema operativo** (`--prompt-admin-pass`) **o** si **prefiere que el agente genere una contraseña aleatoria segura** y se la entregue únicamente al final.
4. **Opciones personalizables (aplicar defaults si el humano no pide cambios)**:
   - `SERVER_HOSTNAME` (defecto: `debian-server`), `SERVER_IP` (autodetecta), `TIMEZONE` (defecto: `UTC`).
   - `SSH_PORT` final (`--target-ssh-port`, defecto `22`).
   - `ENABLE_UFW` (`yes`), `EXTRA_UFW_PORTS` (ej. `"80/tcp 443/tcp"`).
   - `ENABLE_FAIL2BAN` (`yes`), `FAIL2BAN_IGNOREIP` (lista blanca opcional).
   - `ENABLE_UNATTENDED_UPGRADES` (`yes`), `AUTO_REBOOT` (`no`), `AUTO_REBOOT_TIME` (`04:00`).
   - `ENABLE_MOTD` (`yes`), `MOTD_TEXT` (vacío = `SERVER_HOSTNAME`), `MOTD_COLOR` (`lime`, `green`, `cyan`, `magenta`, `pink`, `orange`, `yellow`, `purple`, `blue`, `red`, `toxic`, `synthwave`, `rainbow`), `MOTD_ART_STYLE` (`claude`, `hermes`, `shadow`, `block`, `ascii`).

---

### Paso 2: Captura segura de contraseñas vía Modal Nativo (macOS / Linux / Windows / WSL)

- **NUNCA** pidas contraseñas en el chat ni las pases como argumentos en claro en la línea de comandos ni las imprimas en `stdout`/`stderr`.
- **Usa las banderas modales integradas en `remote-bootstrap.sh`** (o invoca `scripts/prompt-secret.sh` directamente):
  - `--prompt-init-pass`: abre un cuadro de diálogo nativo del SO con campo oculto (`•••••`) para capturar la contraseña inicial SSH/sudo.
  - `--prompt-admin-pass`: abre un cuadro de diálogo nativo del SO (con doble confirmación) para capturar la contraseña de `sudo` del nuevo `ADMIN_USER`.
  - Si necesitas capturar un secreto por separado antes de ejecutar un comando:
    ```bash
    bash scripts/prompt-secret.sh \
      --title "Server Bootstrap — Credencial segura" \
      --prompt "Contraseña actual de root para conectar al servidor:" \
      --out /tmp/sb-secret.XXXXXX
    ```
- **Compatibilidad multiplataforma automática de `prompt-secret.sh`**:
  - **macOS (`Darwin`)**: usa `osascript` sobre `SystemUIServer` con `with hidden answer` y `activate` (trae el diálogo al frente sin requerir permisos de Accesibilidad).
  - **Linux (X11 / Wayland)**: usa `zenity --password`, `kdialog --password`, `ssh-askpass` o `python3` (`tkinter.simpledialog`).
  - **Windows (Git Bash / MSYS2) y WSL2**: invoca `powershell.exe -NoProfile -NonInteractive -STA` con un diálogo `System.Windows.Forms` (`UseSystemPasswordChar = $true`, `TopMost = $true`).
  - **Fallback sin GUI**: lee desde `/dev/tty` con `read -rs`.

#### ⚠️ Permisos del Harness (Obligatorio para que el SO muestre el modal y permita red SSH)

Los sandboxes de agentes IA (Seatbelt en macOS para Codex/Antigravity, Landlock/Bubblewrap en Linux) bloquean por defecto tanto la conexión de red SSH como el acceso al servidor gráfico (`WindowServer` / `mach-lookup` en macOS, X11/D-Bus en Linux, interoperabilidad `powershell.exe` en WSL).

Por lo tanto, al invocar `remote-bootstrap.sh` o `prompt-secret.sh`:
- **En Antigravity**: ejecuta `run_command` con `BypassSandbox: true`.
- **En OpenAI Codex CLI / Desktop**: ejecuta la herramienta de shell con permisos escalados (`with_escalated_permissions: true` / `sandbox_permissions: "require_escalated"`).
- **En Claude Code / Cursor**: ejecuta el comando permitiendo salida del sandbox si el entorno lo solicita.

---

### Paso 3: Ejecución autónoma y comprobaciones por fase

1. **(Opcional recomendado)** Ejecuta primero `--dry-run` (con `--prompt-init-pass` si usa contraseña inicial) para validar conectividad SSH inicial, comprobar que el sistema remoto sea Debian y verificar privilegios (`root` o `sudo`).
2. Ejecuta `remote-bootstrap.sh` con todas las banderas acordadas:
   - **Fase 01**: instala paquetes (`neovim`, `htop`, `wget`, `locales`, `sharutils`, etc.), crea `ADMIN_USER`, instala llaves SSH, configura `sudo`, `.bashrc` y MOTD.
   - **Comprobación externa 1**: el script abre una sesión SSH **nueva e independiente** como `ADMIN_USER` y valida `sudo`. Si falla, **aborta sin endurecer SSH** para conservar el acceso inicial intacto.
   - **Fase 02 (y transición de puerto)**: si `--target-ssh-port` difiere del puerto inicial, abre ambos puertos (`--transition-only`), comprueba conectividad externa al puerto nuevo y solo entonces cierra el puerto anterior y activa Fail2Ban. Si el puerto nuevo no responde, deja ambos puertos abiertos y aborta.
   - **Fase 03**: ejecuta `03-verify.sh` y limpia el directorio temporal remoto y cualquier archivo temporal local de contraseñas.

---

### Paso 4: Reporte final al humano

Al terminar (o si alguna comprobación falla), reporta de forma clara y concisa:
1. **Estado de cada fase y resumen de `03-verify.sh`** (`OK / WARN / FAIL` o el diagnóstico exacto si falló una comprobación de conexión, indicando qué puertos siguen abiertos).
2. **Comando exacto para conectarse**:
   `ssh -p <SSH_PORT> [-i <ruta_llave>] <ADMIN_USER>@<HOST>`
3. **Credenciales generadas** (solo si el agente generó una llave SSH dedicada o una contraseña aleatoria para `sudo`), indicando la ruta de la llave o la contraseña para que el humano la resguarde.
