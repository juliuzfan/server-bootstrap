# Debian Server Bootstrap

Bootstrap mínimo para una instalación limpia de **Debian 13**. Configura el sistema base y aplica un endurecimiento inicial de SSH, firewall y Fail2Ban.

> Ejecuta únicamente en servidores nuevos o después de revisar qué configuraciones existentes serán modificadas. Mantén acceso a la consola del proveedor.

## Incluye

- Actualización de paquetes e instalación de utilidades.
- Hostname, zona horaria y sincronización horaria.
- Usuario administrativo con `sudo` y llave SSH pública.
- Endurecimiento de OpenSSH.
- UFW con entrada denegada por defecto y salida permitida.
- Fail2Ban para SSH.
- Actualizaciones automáticas mediante `unattended-upgrades`.
- Verificación final.

## Requisitos

- Debian 13 (Trixie), systemd y acceso root/sudo.
- Llave SSH pública del operador.
- Acceso a consola del proveedor por si se requiere recuperación.
- Conectividad a los repositorios Debian.

## Uso

```bash
git clone <URL-DE-TU-REPOSITORIO>
cd debian-server-bootstrap
cp config.env.example config.env
nano config.env
sudo bash bootstrap.sh
```

Edita al menos `HOSTNAME`, `TIMEZONE`, `ADMIN_USER` y `SSH_PUBLIC_KEY`. No coloques una llave privada en este archivo.

El bootstrap instala la llave del usuario y prepara el sistema. **Antes de endurecer SSH**, abre otra terminal y confirma que puedes entrar con la llave:

```bash
ssh -p 22 adminops@IP_DEL_SERVIDOR
```

Vuelve a la sesión original y confirma `YES` cuando el orquestador lo solicite. Solo entonces deshabilitará el login SSH de root y la autenticación por contraseña.

Si no confirmas la prueba, puedes ejecutar más tarde:

```bash
sudo bash scripts/02-security.sh
sudo bash scripts/03-verify.sh
```

## Configuración

Consulta los comentarios de `config.env.example`. Opciones principales:

- `SSH_PORT`: puerto SSH que se configurará. Asegúrate de que el proveedor/firewall externo permita ese puerto.
- `ENABLE_UFW`: `yes` o `no`.
- `ENABLE_FAIL2BAN`: `yes` o `no`.
- `ENABLE_UNATTENDED_UPGRADES`: `yes` o `no`.
- `CONFIRM_SSH_HARDENING`: debe ser `YES` para permitir el endurecimiento SSH.

## Advertencias

- El firewall permite únicamente el puerto SSH configurado. **Añade antes de ejecutar reglas adicionales para HTTP/HTTPS, VPN, bases de datos u otros servicios que necesites.**
- UFW no sustituye el firewall del proveedor. Revisa ambos.
- Docker puede manipular reglas de red y publicar puertos que requieren una política adicional. No asumas que UFW controla por sí solo todo el tráfico de contenedores.
- El script no cambia el puerto SSH del daemon antes de validar el archivo, pero un puerto distinto de 22 requiere que el acceso de red externo esté preparado.
- `config.env` se carga como shell. No uses archivos de configuración de fuentes no confiables.
- Se conserva el port forwarding TCP de OpenSSH para permitir túneles SSH (`ssh -L`/`ssh -R`); restringe esa capacidad solo si tu operación lo permite.
- No ejecuta reinicios automáticos.
- Los scripts son idempotentes en sus operaciones principales, pero respaldan el drop-in SSH previo y no intentan reconciliar configuraciones complejas preexistentes.

## Estructura

```text
debian-server-bootstrap/
├── bootstrap.sh
├── config.env.example
├── README.md
└── scripts/
    ├── common.sh
    ├── 01-system.sh
    ├── 02-security.sh
    └── 03-verify.sh
```

## Licencia

Uso interno. Añade la licencia que corresponda a tu repositorio.
