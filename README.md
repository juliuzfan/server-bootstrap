# Debian Server Bootstrap

Bootstrap mínimo e interactivo (TUI en Bash puro, sin dependencias externas) para una instalación limpia de **Debian 13 (Trixie)**. Prepara el sistema base, configura `sudo`, endurece OpenSSH con transición segura de puerto, activa UFW y Fail2Ban, e instala un prompt Bash moderno en colores junto con un MOTD con banner ASCII Art neón.

> Ejecuta en servidores nuevos o tras revisar qué archivos serán gestionados. Mantén siempre abierta una sesión root y acceso a la consola de tu proveedor.

## Incluye

- **Asistente TUI guiado en Bash puro**: menús con flechas `↑`/`↓`, validación en vivo, detección automática de llave SSH existente y vista previa en color del banner ASCII Art.
- **Sistema base**: actualización no interactiva segura (`--force-confdef`/`--force-confold`), utilidades esenciales, zona horaria, `hostname` y resolución en `/etc/hosts`, sincronización NTP con `chrony`.
- **Usuario administrativo y `sudo` funcional**: creación de cuenta, soporte para múltiples llaves públicas (`ed25519`, `rsa`, `ecdsa`, `sk-*` FIDO2) y configuración de `sudo` con contraseña (`SUDO_MODE=password` o `ADMIN_PASSWORD_HASH`) o sin contraseña (`SUDO_MODE=nopasswd` validado con `visudo`).
- **Endurecimiento de OpenSSH sin bloqueos**: validación previa con `sshd -t`, respaldo automático con rollback si falla y **transición segura en dos pasos** cuando `SSH_PORT` cambia (abre ambos puertos, verifica acceso en el nuevo y cierra el antiguo).
- **Firewall UFW**: política `deny incoming` / `allow outgoing`, soporte IPv6, puertos adicionales vía `EXTRA_UFW_PORTS` y reconciliación automática de reglas obsoletas al cambiar de puerto.
- **Fail2Ban para SSH**: instala explícitamente `python3-systemd` y `nftables` para el backend `systemd`, y soporta lista blanca (`FAIL2BAN_IGNOREIP`).
- **Actualizaciones automáticas**: `unattended-upgrades` con reinicio programado opcional (`AUTO_REBOOT` / `AUTO_REBOOT_TIME`).
- **Prompt Bash moderno y MOTD ASCII Art**:
  - Prompt de dos líneas en colores para `root` (distintivo rojo `ROOT`) y el usuario administrador, con código de salida (`✔`/`✘`), hora, `usuario@host`, ruta y rama Git.
  - Banner ASCII Art generado en Bash puro con texto personalizable (o `SERVER_HOSTNAME` por defecto), estilos `block` (`██`) o `ascii` (`##`), y colores neón/gradientes (`lime`, `green`, `cyan`, `magenta`, `pink`, `orange`, `yellow`, `purple`, `blue`, `red`, `toxic`, `synthwave`, `rainbow`), acompañado de un resumen de estado (OS, IP, uptime, carga, RAM y disco).
- **Registro y verificación**: bitácora completa en `/var/log/server-bootstrap.log` y chequeo final con `scripts/03-verify.sh`.

## Requisitos

- Debian 13 (Trixie), `systemd` y acceso `root` / `sudo`.
- Al menos una llave SSH pública del operador.
- Acceso a consola del proveedor por seguridad.

## Uso rápido (TUI guiado)

```bash
git clone https://github.com/juliuzfan/server-bootstrap.git
cd server-bootstrap
sudo bash bootstrap.sh
```

Si `config.env` no existe (o ejecutas `sudo bash bootstrap.sh --wizard`), se abrirá el asistente TUI paso a paso para generarlo con permisos `600`.

### Uso con archivo `config.env` manual o automatizado (CI/CD / cloud-init)

```bash
cp config.env.example config.env
chmod 600 config.env
nano config.env
sudo bash bootstrap.sh
```

Para ejecuciones desatendidas (requiere `CONFIRM_SSH_HARDENING="YES"` y `SUDO_MODE="nopasswd"` o `ADMIN_PASSWORD_HASH` definido):

```bash
sudo bash bootstrap.sh --yes --config /ruta/a/config.env
```

### Flujo de verificación antes de endurecer SSH

1. Tras completar la **Fase 01**, el orquestador se pausa y muestra el comando exacto para probar en **otra terminal** el login con llave y `sudo -v`.
2. Solo cuando escribes `YES` ejecuta la **Fase 02** (deshabilita login de `root` y contraseñas por SSH).
3. Si configuraste un `SSH_PORT` distinto del actual, la Fase 02 mantiene temporalmente ambos puertos abiertos en `sshd` y UFW hasta que confirmes que puedes entrar por el nuevo puerto.

También puedes ejecutar cada fase por separado:

```bash
sudo bash scripts/01-system.sh
sudo bash scripts/02-security.sh   # requiere CONFIRM_SSH_HARDENING="YES" en config.env
sudo bash scripts/03-verify.sh
```

## Opciones principales en `config.env`

| Variable | Descripción |
| :--- | :--- |
| `SERVER_HOSTNAME` | Nombre del host (también actualiza `/etc/hosts`). |
| `TIMEZONE` | Zona horaria IANA (`UTC` por defecto; ej. `America/Mexico_City`). |
| `ADMIN_USER` | Usuario administrativo no-root. |
| `SUDO_MODE` | `password` (pide contraseña en `sudo`) o `nopasswd` (`NOPASSWD` en `/etc/sudoers.d`). |
| `ADMIN_PASSWORD_HASH` | Hash opcional (`openssl passwd -6`) para `SUDO_MODE=password` sin prompt interactivo. |
| `SSH_PUBLIC_KEYS` | Arreglo Bash con una o más llaves públicas OpenSSH. |
| `SSH_PORT` | Puerto SSH final (`1`–`65535`). |
| `ENABLE_UFW` / `EXTRA_UFW_PORTS` | Activa UFW (`yes`/`no`) y abre puertos extra (ej. `"80/tcp 443/tcp"`). |
| `ENABLE_FAIL2BAN` / `FAIL2BAN_IGNOREIP` | Activa Fail2Ban (`yes`/`no`) e IPs/redes en lista blanca. |
| `ENABLE_UNATTENDED_UPGRADES` | Activa parches automáticos (`yes`/`no`), junto con `AUTO_REBOOT` y `AUTO_REBOOT_TIME`. |
| `ENABLE_PROMPT` | Instala el prompt Bash moderno para `root` y `ADMIN_USER` (`yes`/`no`). |
| `ENABLE_MOTD` | Instala el MOTD con ASCII Art y resumen del sistema (`yes`/`no`). |
| `MOTD_TEXT` | Texto del banner ASCII Art (vacío = usa `SERVER_HOSTNAME`). |
| `MOTD_COLOR` | `lime` (default), `green`, `cyan`, `magenta`, `pink`, `orange`, `yellow`, `purple`, `blue`, `red`, `toxic`, `synthwave`, `rainbow`. |
| `MOTD_ART_STYLE` | `block` (`██`) o `ascii` (`##`). |
| `CONFIRM_SSH_HARDENING` | `NO` por defecto; debe ser `YES` para aplicar `02-security.sh`. |

## Estructura

```text
server-bootstrap/
├── bootstrap.sh
├── config.env.example
├── README.md
└── scripts/
    ├── common.sh
    ├── tui.sh
    ├── 01-system.sh
    ├── 02-security.sh
    └── 03-verify.sh
```
