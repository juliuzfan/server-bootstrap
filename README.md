# Debian 13 Server Bootstrap

Deja listo un servidor **Debian 13 (Trixie)** recién instalado en pocos minutos.

A través de un asistente interactivo en terminal (TUI en Bash puro, sin dependencias externas), configura el sistema base, crea tu usuario administrador con `sudo`, asegura OpenSSH sin riesgo de quedarte fuera, activa el firewall y personaliza la terminal con un prompt moderno y un banner ASCII Art en colores neón.

> **Consejo de oro:** mantén abierta tu sesión `root` actual y ten a mano la consola web de tu proveedor hasta comprobar que puedes entrar en una ventana nueva.

---

## Inicio rápido

En una imagen mínima de Debian `git` no suele venir instalado. Entra como `root` (o con un usuario con `sudo`) y ejecuta:

```bash
# 1. Instalar git y certificados base
apt-get update && apt-get install -y git ca-certificates

# 2. Clonar el repositorio
git clone https://github.com/juliuzfan/server-bootstrap.git
cd server-bootstrap

# 3. Iniciar el asistente interactivo
sudo bash bootstrap.sh
```

El asistente te guiará paso a paso con menús navegables (`↑`/`↓` y `Enter`), detectará datos actuales del servidor, te mostrará una vista previa del banner en color y guardará tu `config.env` con permisos seguros (`600`).

---

## ¿Cómo evita que pierdas el acceso SSH?

El proceso se divide en fases con pausas de confirmación para que nunca cierres `root` a ciegas:

1. **Fase 01 — Sistema y usuario**: instala paquetes, configura `sudo` y agrega tu llave SSH pública al nuevo usuario sin tocar todavía las restricciones de `sshd`.
2. **Pausa de verificación**: el script se detiene y te muestra el comando exacto para abrir **otra terminal** y comprobar que entras con tu llave y que `sudo -v` responde bien.
3. **Fase 02 — Endurecimiento**: solo cuando confirmas escribiendo `YES`, deshabilita el login de `root` y las contraseñas por SSH.
   - *Si decidiste cambiar el puerto SSH (ej. del `22` al `2222`)*: abre temporalmente **ambos puertos** en el firewall y en `sshd`, te pide probar el puerto nuevo y únicamente entonces cierra el anterior.
4. **Fase 03 — Verificación**: imprime un resumen final `[OK] / [WARN] / [FAIL]` del estado del servidor.

---

## Qué incluye

### Sistema y mantenimiento
- **Actualización y herramientas**: actualiza paquetes de forma no interactiva e instala utilidades esenciales (`htop`, `neovim` como reemplazo del sistema para `vim`/`vi`/`editor`, `wget`, `curl`, `git`, `lsof`, `dnsutils`, `sharutils`).
- **Identidad, `/etc/hosts`, locales y hora**: configura el `hostname`, registra en `/etc/hosts` la IP pública del servidor (`SERVER_IP` elegida o autodetectada) junto con `127.0.1.1`, habilita el locale `en_US.UTF-8`, define la zona horaria (`UTC` por defecto) y activa `chrony` para sincronización NTP.
- **Parches automáticos**: activa `unattended-upgrades` con opción de reinicio automático en horario programado si el kernel lo requiere.

### Acceso y seguridad
- **Usuario administrador con `sudo` real**: crea el usuario y configura `sudo` con contraseña (solicitada en el paso 01 o mediante hash) o sin contraseña (`NOPASSWD` validado con `visudo`).
- **Llaves SSH**: acepta una o varias llaves públicas (`ed25519`, `rsa`, `ecdsa` y llaves de hardware `sk-*` FIDO2), validadas con `ssh-keygen`.
- **OpenSSH endurecido**: aplica configuración en `/etc/ssh/sshd_config.d/`, la valida con `sshd -t` antes de recargar y hace rollback automático si algo falla.
- **Firewall (UFW)**: bloquea todo el tráfico entrante salvo SSH y los puertos extra que indiques (ej. `80/tcp 443/tcp`), con soporte IPv6 y limpieza automática de reglas antiguas.
- **Fail2Ban**: protege el puerto SSH usando el backend `systemd` + `nftables` y permite declarar IPs o redes de confianza en lista blanca.

### Experiencia en terminal (`.bashrc` + Prompt + MOTD)
- **`.bashrc` y Prompt listos sin preguntar**: instala automáticamente en `root`, el usuario administrador y `/etc/skel` tu `.bashrc` estándar (encabezado Roster.li con año y hostname dinámicos, prompt en colores con rama Git `on <branch>`, aliases de navegación/seguridad/`nvim`/`gst` y la función `password_generator`).
- **MOTD de bienvenida con ASCII Art**: genera un banner en Bash puro seleccionable por nombre (`claude` estilo Claude Code, `hermes` estilo Hermes Agent, `shadow` 3D ANSI, `block` o `ascii`), con el nombre del servidor o el texto que elijas, colores neón o gradientes (`lime`, `cyan`, `magenta`, `toxic`, `synthwave`, `rainbow`, etc.) y un resumen de recursos al iniciar sesión (OS, IP, uptime, carga, RAM y disco).

---

## Uso avanzado y automatización

Si prefieres preparar la configuración sin pasar por el asistente interactivo:

```bash
cp config.env.example config.env
chmod 600 config.env
nano config.env
sudo bash bootstrap.sh
```

### Opciones de línea de comandos

```bash
sudo bash bootstrap.sh --wizard                  # Abrir el asistente TUI para editar config.env
sudo bash bootstrap.sh --config /ruta/config.env # Usar un archivo de configuración específico
sudo bash bootstrap.sh --yes                     # Modo desatendido (CI/CD o cloud-init)
```

> En modo `--yes`, asegúrate de definir en `config.env` `CONFIRM_SSH_HARDENING="YES"` y `SUDO_MODE="nopasswd"` (o `ADMIN_PASSWORD_HASH`).

También puedes ejecutar cada etapa de forma independiente en cualquier momento:

```bash
sudo bash scripts/01-system.sh
sudo bash scripts/02-security.sh
sudo bash scripts/03-verify.sh
```

Toda la ejecución queda registrada en `/var/log/server-bootstrap.log`.

---

## Referencia rápida de `config.env`

| Variable | Por defecto | Descripción |
| :--- | :--- | :--- |
| `SERVER_HOSTNAME` | `"debian-server"` | Nombre del servidor (se registra en `/etc/hosts`). |
| `SERVER_IP` | `""` *(autodetecta)* | IP pública del servidor para asociarla al hostname en `/etc/hosts`. |
| `TIMEZONE` | `"UTC"` | Zona horaria IANA (ej. `UTC`, `America/Mexico_City`). |
| `ADMIN_USER` | `"adminops"` | Usuario administrativo no-root. |
| `SUDO_MODE` | `"password"` | `password` (pide clave al usar `sudo`) o `nopasswd`. |
| `ADMIN_PASSWORD_HASH` | `""` | Hash opcional (`openssl passwd -6`) para modo no interactivo. |
| `SSH_PUBLIC_KEYS` | *(requerido)* | Arreglo Bash con una o más llaves públicas OpenSSH. |
| `SSH_PORT` | `"22"` | Puerto SSH final (`1`–`65535`). |
| `ENABLE_UFW` | `"yes"` | Activa el firewall UFW (`yes`/`no`). |
| `EXTRA_UFW_PORTS` | `""` | Puertos extra separados por espacio (ej. `"80/tcp 443/tcp"`). |
| `ENABLE_FAIL2BAN` | `"yes"` | Activa Fail2Ban para SSH (`yes`/`no`). |
| `FAIL2BAN_IGNOREIP` | `""` | IPs o redes en lista blanca separadas por espacio. |
| `ENABLE_UNATTENDED_UPGRADES` | `"yes"` | Actualizaciones automáticas (`yes`/`no`), junto a `AUTO_REBOOT` y `AUTO_REBOOT_TIME`. |
| `ENABLE_MOTD` | `"yes"` | Instala el banner ASCII Art y el panel de estado al iniciar sesión. |
| `MOTD_TEXT` | `""` | Texto del banner (vacío = usa `SERVER_HOSTNAME`). |
| `MOTD_COLOR` | `"lime"` | `lime`, `green`, `cyan`, `magenta`, `pink`, `orange`, `yellow`, `purple`, `blue`, `red`, `toxic`, `synthwave`, `rainbow`. |
| `MOTD_ART_STYLE` | `"claude"` | Diseño ASCII Art: `claude`, `hermes`, `shadow`, `block` (`██`) o `ascii` (`##`). |
| `CONFIRM_SSH_HARDENING` | `"NO"` | Cambia a `"YES"` tras probar el acceso SSH con llave. |

---

## Uso con Agentes IA (Autónomo y Remoto)

El repositorio incluye un **Agent Skill** (`.agents/skills/server-bootstrap/SKILL.md`) y un **orquestador remoto** (`scripts/remote-bootstrap.sh`) para que cualquier agente IA compatible (Antigravity, Claude Code, Codex, Gemini CLI, etc.) configure un servidor Debian 13 a distancia pasando únicamente IP/DNS, credencial inicial (password o llave SSH) e indicaciones en lenguaje natural.

- **Instalación global del skill** (para usarlo desde cualquier proyecto):

```bash
bash scripts/install-skill.sh
```

- **Ejecución directa del orquestador remoto**:

```bash
bash scripts/remote-bootstrap.sh \
  --host 203.0.113.10 \
  --ssh-user root \
  --init-pass-file /ruta/segura/init_pass \
  --hostname srv-prod-01 \
  --timezone America/Mexico_City \
  --admin-user adminops \
  --sudo-mode password \
  --admin-pass-file /ruta/segura/admin_pass \
  --pubkey ~/.ssh/id_ed25519.pub \
  --target-ssh-port 2222 \
  --extra-ufw-ports "80/tcp 443/tcp"
```

El orquestador no requiere `git` ni `sshpass` en el servidor destino, no deja contraseñas en claro en `config.env` ni en `/var/log/server-bootstrap.log`, y valida el acceso SSH + `sudo` desde fuera antes de endurecer OpenSSH o cerrar el puerto anterior.

---

## Estructura del proyecto

```text
server-bootstrap/
├── .agents/skills/server-bootstrap/
│   └── SKILL.md            # Skill estándar para agentes IA
├── AGENTS.md               # Guía rápida para agentes en el repo
├── bootstrap.sh            # Orquestador principal y CLI en el servidor
├── config.env.example      # Plantilla comentada de configuración
├── README.md               # Documentación
└── scripts/
    ├── common.sh           # Validaciones, utilidades y manejo de estado
    ├── tui.sh              # Asistente TUI y motor de ASCII Art en Bash puro
    ├── remote-bootstrap.sh # Orquestador remoto autónomo (SSH + fases)
    ├── install-skill.sh    # Instalador global del skill para agentes IA
    ├── 01-system.sh        # Paquetes, usuario, sudo, llaves, prompt y MOTD
    ├── 02-security.sh      # Endurecimiento SSH, transición de puerto, UFW y Fail2Ban
    └── 03-verify.sh        # Diagnóstico y resumen de verificación
```
