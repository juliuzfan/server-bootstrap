#!/usr/bin/env bash
# shellcheck shell=bash
# Renderizador de banner ASCII art y utilidades TUI en Bash puro (sin dependencias).

if [[ -n "${__SB_TUI_LOADED:-}" ]]; then
  return 0
fi
__SB_TUI_LOADED=1

# --------------------------------------------------------- Fuente 5x5 bitmap ---
# Cada glifo codifica 5 filas separadas por ':' usando '#' (encendido) y ' ' (apagado).
sb_glyph_rows() {
  case "$1" in
    A) echo " ### :#   #:#####:#   #:#   #" ;;
    B) echo "#### :#   #:#### :#   #:#### " ;;
    C) echo " ####:#    :#    :#    : ####" ;;
    D) echo "#### :#   #:#   #:#   #:#### " ;;
    E) echo "#####:#    :#### :#    :#####" ;;
    F) echo "#####:#    :#### :#    :#    " ;;
    G) echo " ####:#    :#  ##:#   #: ####" ;;
    H) echo "#   #:#   #:#####:#   #:#   #" ;;
    I) echo "#####:  #  :  #  :  #  :#####" ;;
    J) echo "  ###:   # :   # :#  # : ##  " ;;
    K) echo "#   #:#  # :###  :#  # :#   #" ;;
    L) echo "#    :#    :#    :#    :#####" ;;
    M) echo "#   #:## ##:# # #:#   #:#   #" ;;
    N) echo "#   #:##  #:# # #:#  ##:#   #" ;;
    O) echo " ### :#   #:#   #:#   #: ### " ;;
    P) echo "#### :#   #:#### :#    :#    " ;;
    Q) echo " ### :#   #:# # #:#  # : ## #" ;;
    R) echo "#### :#   #:#### :#  # :#   #" ;;
    S) echo " ####:#    : ### :    #:#### " ;;
    T) echo "#####:  #  :  #  :  #  :  #  " ;;
    U) echo "#   #:#   #:#   #:#   #: ### " ;;
    V) echo "#   #:#   #:#   #: # # :  #  " ;;
    W) echo "#   #:#   #:# # #:## ##:#   #" ;;
    X) echo "#   #: # # :  #  : # # :#   #" ;;
    Y) echo "#   #: # # :  #  :  #  :  #  " ;;
    Z) echo "#####:   # :  #  : #   :#####" ;;
    0) echo " ### :#  ##:# # #:##  #: ### " ;;
    1) echo "  #  : ##  :  #  :  #  :#####" ;;
    2) echo " ### :#   #:  ## : #   :#####" ;;
    3) echo "#### :    #: ### :    #:#### " ;;
    4) echo "#  # :#  # :#####:   # :   # " ;;
    5) echo "#####:#    :#### :    #:#### " ;;
    6) echo " ### :#    :#### :#   #: ### " ;;
    7) echo "#####:   # :  #  : #   : #   " ;;
    8) echo " ### :#   #: ### :#   #: ### " ;;
    9) echo " ### :#   #: ####:    #: ### " ;;
    -) echo "     :     :#####:     :     " ;;
    _) echo "     :     :     :     :#####" ;;
    .) echo "     :     :     : ##  : ##  " ;;
    !) echo "  #  :  #  :  #  :     :  #  " ;;
    " ") echo "   :   :   :   :   " ;;
    *) echo " ### :#   #:  ## :     :  #  " ;;
  esac
}

# Renderiza una matriz 5x5 con sombra 3D ANSI (6 filas) para los estilos claude, hermes y shadow.
sb_render_shaded_text() {
  local text=$1
  shift
  local -a pal=("$@")
  local -a grid0=() grid1=() grid2=() grid3=() grid4=()
  local i ch spec g0 g1 g2 g3 g4
  for (( i = 0; i < ${#text}; i++ )); do
    ch="${text:i:1}"
    spec="$(sb_glyph_rows "$ch")"
    IFS=':' read -r g0 g1 g2 g3 g4 <<<"$spec"
    grid0+=("$g0")
    grid1+=("$g1")
    grid2+=("$g2")
    grid3+=("$g3")
    grid4+=("$g4")
  done

  # Construye cadenas binarias de 6 filas (fila 5 vacía para proyectar sombra inferior)
  local b0="" b1="" b2="" b3="" b4="" b5=""
  for (( i = 0; i < ${#text}; i++ )); do
    b0+="${grid0[i]} "
    b1+="${grid1[i]} "
    b2+="${grid2[i]} "
    b3+="${grid3[i]} "
    b4+="${grid4[i]} "
  done
  local width=${#b0}
  printf -v b5 '%*s' "$width" ""

  local -a rows=("$b0" "$b1" "$b2" "$b3" "$b4" "$b5")
  local r c cur prev_row prev_diag line
  SB_SHADED_LINES=()
  for (( r = 0; r < 6; r++ )); do
    line=""
    cur="${rows[r]}"
    prev_row=""
    (( r > 0 )) && prev_row="${rows[r-1]}"
    for (( c = 0; c < width; c++ )); do
      if [[ "${cur:c:1}" == "#" ]]; then
        line+="\033[1;38;5;${pal[r]}m██"
      elif (( r > 0 && c > 0 )) && [[ "${prev_row:c-1:1}" == "#" ]]; then
        line+="\033[0;38;5;${pal[r]}m░░"
      elif (( r > 0 )) && [[ "${prev_row:c:1}" == "#" ]]; then
        line+="\033[0;38;5;${pal[r]}m▀▀"
      elif (( c > 0 )) && [[ "${cur:c-1:1}" == "#" ]]; then
        line+="\033[0;38;5;${pal[r]}m▌ "
      else
        line+="  "
      fi
    done
    line+="\033[0m"
    SB_SHADED_LINES+=("$line")
  done
}

# Renderiza texto ($1) con color ($2: lime, cyan, rainbow, ...) y estilo ($3: claude | hermes | shadow | block | ascii).
render_ascii_banner() {
  local text="${1:-SERVER}" color="${2:-lime}" style="${3:-claude}"
  text="$(printf '%s' "$text" | tr '[:lower:]' '[:upper:]')"

  local -a pal
  read -ra pal <<<"$(motd_palette "$color")"
  local acc="${pal[0]}"

  case "$style" in
    claude)
      (( ${#text} > 18 )) && text="${text:0:18}"
      sb_render_shaded_text "$text" "${pal[@]}"
      local -a m=(
        "   \033[1;38;5;${pal[0]}m╭───────────╮\033[0m   "
        "   \033[1;38;5;${pal[1]}m│  \033[1;97m▀▄   ▄▀\033[1;38;5;${pal[1]}m  │\033[0m   "
        "   \033[1;38;5;${pal[2]}m│  \033[1;97m  ▀▀▀  \033[1;38;5;${pal[2]}m  │\033[0m   "
        "   \033[1;38;5;${pal[3]}m╰──┬─────┬──╯\033[0m   "
        "   \033[1;38;5;${pal[4]}m   │ \033[1;97m▛▀▜\033[1;38;5;${pal[4]}m │   \033[0m   "
        "   \033[1;38;5;${pal[5]}m   ╰─┴─┴─╯   \033[0m   "
      )
      printf '\n'
      local idx
      for (( idx = 0; idx < 6; idx++ )); do
        printf '%b%b\n' "${m[idx]}" "${SB_SHADED_LINES[idx]}"
      done
      printf '\n'
      ;;

    hermes)
      (( ${#text} > 16 )) && text="${text:0:16}"
      sb_render_shaded_text "$text" "${pal[@]}"
      local -a h=(
        "  \033[1;38;5;${pal[0]}m ╲╲╲  \033[1;97m╭───╮\033[1;38;5;${pal[0]}m  ╱╱╱ \033[0m  "
        "  \033[1;38;5;${pal[1]}m  ╲╲╲ \033[1;97m╰─┬─╯\033[1;38;5;${pal[1]}m ╱╱╱  \033[0m  "
        "  \033[1;38;5;${pal[2]}m   ╲╲\033[1;97m╭──┼──╮\033[1;38;5;${pal[2]}m╱╱   \033[0m  "
        "  \033[1;38;5;${pal[3]}m     \033[1;97m╰──┼──╯\033[1;38;5;${pal[3]}m     \033[0m  "
        "  \033[1;38;5;${pal[4]}m     \033[1;97m ╭─┼─╮ \033[1;38;5;${pal[4]}m     \033[0m  "
        "  \033[1;38;5;${pal[5]}m     \033[1;97m ╰─┴─╯ \033[1;38;5;${pal[5]}m     \033[0m  "
      )
      printf '\n'
      local idx
      for (( idx = 0; idx < 6; idx++ )); do
        printf '%b%b\n' "${h[idx]}" "${SB_SHADED_LINES[idx]}"
      done
      printf '\n'
      ;;

    shadow)
      (( ${#text} > 22 )) && text="${text:0:22}"
      sb_render_shaded_text "$text" "${pal[@]}"
      printf '\n'
      local idx
      for (( idx = 0; idx < 6; idx++ )); do
        printf '  %b\n' "${SB_SHADED_LINES[idx]}"
      done
      printf '\n'
      ;;

    block|ascii|*)
      (( ${#text} > 26 )) && text="${text:0:26}"
      local on="██" off="  "
      if [[ "$style" == "ascii" ]]; then
        on="##"
      fi
      local r0="" r1="" r2="" r3="" r4=""
      local i ch spec g0 g1 g2 g3 g4
      for (( i = 0; i < ${#text}; i++ )); do
        ch="${text:i:1}"
        spec="$(sb_glyph_rows "$ch")"
        IFS=':' read -r g0 g1 g2 g3 g4 <<<"$spec"
        g0="${g0//#/$on}"; g0="${g0// /$off}"
        g1="${g1//#/$on}"; g1="${g1// /$off}"
        g2="${g2//#/$on}"; g2="${g2// /$off}"
        g3="${g3//#/$on}"; g3="${g3// /$off}"
        g4="${g4//#/$on}"; g4="${g4// /$off}"
        r0+="${g0}  "
        r1+="${g1}  "
        r2+="${g2}  "
        r3+="${g3}  "
        r4+="${g4}  "
      done
      printf '\n'
      printf '  \033[1;38;5;%sm%s\033[0m\n' "${pal[0]}" "$r0"
      printf '  \033[1;38;5;%sm%s\033[0m\n' "${pal[1]}" "$r1"
      printf '  \033[1;38;5;%sm%s\033[0m\n' "${pal[2]}" "$r2"
      printf '  \033[1;38;5;%sm%s\033[0m\n' "${pal[3]}" "$r3"
      printf '  \033[1;38;5;%sm%s\033[0m\n' "${pal[4]}" "$r4"
      printf '\n'
      ;;
  esac
}

# ------------------------------------------------------- Controles TUI puros ---
tui_banner() {
  local title="${1:-Debian Server Bootstrap}" subtitle="${2:-Asistente interactivo}"
  printf '\n\033[1;38;5;118m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m\n'
  printf '\033[1;38;5;118m┃\033[0m \033[1;97m%-66s\033[0m \033[1;38;5;118m┃\033[0m\n' "$title"
  printf '\033[1;38;5;118m┃\033[0m \033[0;36m%-66s\033[0m \033[1;38;5;118m┃\033[0m\n' "$subtitle"
  printf '\033[1;38;5;118m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m\n'
}

tui_section() {
  printf '\n\033[1;38;5;51m── %s ──\033[0m\n' "$1"
}

# tui_input "Etiqueta" "default" "validador_fn" "Mensaje de error" -> resultado en TUI_REPLY
tui_input() {
  local prompt="$1" default="${2:-}" validator="${3:-}" err_msg="${4:-Valor inválido.}"
  local val=""
  while true; do
    if [[ -n "$default" ]]; then
      printf '\033[1;36m?\033[0m %s \033[2m[%s]\033[0m: ' "$prompt" "$default"
    else
      printf '\033[1;36m?\033[0m %s: ' "$prompt"
    fi
    IFS= read -r val || val=""
    val="$(trim "$val")"
    [[ -z "$val" ]] && val="$default"
    if [[ -z "$validator" ]] || "$validator" "$val"; then
      TUI_REPLY="$val"
      return 0
    fi
    printf '  \033[1;31m✗ %s\033[0m\n' "$err_msg" >&2
  done
}

# tui_yesno "Pregunta" "yes|no" -> TUI_REPLY="yes"|"no"
tui_yesno() {
  local prompt="$1" default="${2:-yes}" hint="Y/n" ans=""
  [[ "$default" == "no" ]] && hint="y/N"
  while true; do
    printf '\033[1;36m?\033[0m %s \033[2m(%s)\033[0m: ' "$prompt" "$hint"
    IFS= read -r ans || ans=""
    ans="$(trim "$ans" | tr '[:upper:]' '[:lower:]')"
    [[ -z "$ans" ]] && ans="$default"
    case "$ans" in
      y|yes|s|si|sí) TUI_REPLY="yes"; return 0 ;;
      n|no)          TUI_REPLY="no";  return 0 ;;
      *) printf '  \033[1;31m✗ Responde s/y (sí) o n (no).\033[0m\n' >&2 ;;
    esac
  done
}

# Menú interactivo con flechas ↑/↓ y Enter, o número directo si la terminal es básica.
# Uso: tui_select "Título" "default_val" "val1|Etiqueta 1" "val2|Etiqueta 2" ...
# Resultado en TUI_REPLY (contiene el valor antes de '|').
tui_select() {
  local prompt="$1" default_val="$2"
  shift 2
  local -a items=("$@")
  local -a vals=() labels=()
  local idx=0 i=0 item v l

  for item in "${items[@]}"; do
    v="${item%%|*}"
    l="${item#*|}"
    vals+=("$v")
    labels+=("$l")
    if [[ "$v" == "$default_val" ]]; then
      idx=$i
    fi
    (( i += 1 ))
  done

  local count=${#vals[@]}
  printf '\033[1;36m?\033[0m \033[1m%s\033[0m \033[2m(↑/↓ y Enter, o escribe 1-%d)\033[0m\n' "$prompt" "$count"

  local key rest drawn=0
  while true; do
    if (( drawn == 1 )); then
      printf '\033[%dA' "$count"
    fi
    for (( i = 0; i < count; i++ )); do
      if (( i == idx )); then
        printf '\r\033[2K  \033[1;38;5;118m❯ [%d] %s\033[0m\n' "$((i + 1))" "${labels[i]}"
      else
        printf '\r\033[2K    \033[2m[%d]\033[0m %s\n' "$((i + 1))" "${labels[i]}"
      fi
    done
    drawn=1

    IFS= read -rsn1 key || { TUI_REPLY="${vals[idx]}"; return 0; }
    if [[ "$key" == "" ]]; then
      TUI_REPLY="${vals[idx]}"
      return 0
    elif [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 -t 0.1 rest || rest=""
      case "$rest" in
        "[A"|"[D") idx=$(( (idx - 1 + count) % count )) ;;
        "[B"|"[C") idx=$(( (idx + 1) % count )) ;;
      esac
    elif [[ "$key" == "k" || "$key" == "K" ]]; then
      idx=$(( (idx - 1 + count) % count ))
    elif [[ "$key" == "j" || "$key" == "J" ]]; then
      idx=$(( (idx + 1) % count ))
    elif [[ "$key" =~ ^[1-9]$ ]] && (( key >= 1 && key <= count )); then
      idx=$(( key - 1 ))
      if (( drawn == 1 )); then
        printf '\033[%dA' "$count"
        for (( i = 0; i < count; i++ )); do
          if (( i == idx )); then
            printf '\r\033[2K  \033[1;38;5;118m❯ [%d] %s\033[0m\n' "$((i + 1))" "${labels[i]}"
          else
            printf '\r\033[2K    \033[2m[%d]\033[0m %s\n' "$((i + 1))" "${labels[i]}"
          fi
        done
      fi
      TUI_REPLY="${vals[idx]}"
      return 0
    fi
  done
}

# Escribe config.env con permisos 600 a partir de las variables en memoria.
write_config_file() {
  local target="${1:-${ROOT_DIR}/config.env}" tmp key
  tmp="$(mktemp "${target}.XXXXXX")"
  chmod 600 "$tmp"

  {
    printf '# Generado por server-bootstrap (%s)\n' "$(date -Iseconds 2>/dev/null || date)"
    printf '# Archivo cargado como shell: mantén permisos 600 y valores de confianza.\n\n'
    printf 'SERVER_HOSTNAME=%s\n' "$(shell_quote "$SERVER_HOSTNAME")"
    printf 'SERVER_IP=%s\n' "$(shell_quote "${SERVER_IP:-}")"
    printf 'TIMEZONE=%s\n\n' "$(shell_quote "$TIMEZONE")"
    printf 'ADMIN_USER=%s\n' "$(shell_quote "$ADMIN_USER")"
    printf 'SUDO_MODE=%s\n' "$(shell_quote "$SUDO_MODE")"
    printf 'ADMIN_PASSWORD_HASH=%s\n\n' "$(shell_quote "${ADMIN_PASSWORD_HASH:-}")"
    printf 'SSH_PUBLIC_KEYS=(\n'
    for key in "${SB_KEYS[@]}"; do
      printf '  %s\n' "$(shell_quote "$key")"
    done
    printf ')\n\n'
    printf 'SSH_PORT=%s\n' "$(shell_quote "$SSH_PORT")"
    printf 'ENABLE_UFW=%s\n' "$(shell_quote "$ENABLE_UFW")"
    printf 'EXTRA_UFW_PORTS=%s\n' "$(shell_quote "${EXTRA_UFW_PORTS:-}")"
    printf 'ENABLE_FAIL2BAN=%s\n' "$(shell_quote "$ENABLE_FAIL2BAN")"
    printf 'FAIL2BAN_IGNOREIP=%s\n\n' "$(shell_quote "${FAIL2BAN_IGNOREIP:-}")"
    printf 'ENABLE_UNATTENDED_UPGRADES=%s\n' "$(shell_quote "$ENABLE_UNATTENDED_UPGRADES")"
    printf 'AUTO_REBOOT=%s\n' "$(shell_quote "${AUTO_REBOOT:-no}")"
    printf 'AUTO_REBOOT_TIME=%s\n\n' "$(shell_quote "${AUTO_REBOOT_TIME:-04:00}")"
    printf 'ENABLE_MOTD=%s\n' "$(shell_quote "${ENABLE_MOTD:-yes}")"
    printf 'MOTD_TEXT=%s\n' "$(shell_quote "${MOTD_TEXT:-}")"
    printf 'MOTD_COLOR=%s\n' "$(shell_quote "${MOTD_COLOR:-lime}")"
    printf 'MOTD_ART_STYLE=%s\n\n' "$(shell_quote "${MOTD_ART_STYLE:-claude}")"
    printf 'CONFIRM_SSH_HARDENING=%s\n' "$(shell_quote "${CONFIRM_SSH_HARDENING:-NO}")"
  } >"$tmp"

  mv -f "$tmp" "$target"
  chmod 600 "$target"
}

# Asistente guiado paso a paso para crear o editar config.env.
run_config_wizard() {
  local target="${1:-${ROOT_DIR}/config.env}"
  if [[ -f "$target" ]]; then
    # Carga valores previos si existen (ignora errores de validación aún incompletos).
    # shellcheck disable=SC1090
    source "$target" 2>/dev/null || true
  fi

  local cur_host cur_srv_ip cur_tz cur_ip
  cur_host="${SERVER_HOSTNAME:-$(hostname -s 2>/dev/null || echo debian-server)}"
  valid_hostname "$cur_host" || cur_host="debian-server"
  cur_srv_ip="${SERVER_IP:-$(detect_server_ip)}"
  valid_single_ip "$cur_srv_ip" || cur_srv_ip=""
  cur_tz="${TIMEZONE:-UTC}"
  valid_timezone "$cur_tz" || cur_tz="UTC"
  cur_ip="$(client_ip)"

  tui_banner "Debian 13 Server Bootstrap — Asistente TUI" "Configuración guiada de sistema, seguridad, prompt y MOTD"

  tui_section "1. Identidad del servidor y /etc/hosts"
  tui_input "Hostname del servidor" "$cur_host" valid_hostname "Usa letras, números, puntos o guiones (ej. srv-prod-01)."
  SERVER_HOSTNAME="$TUI_REPLY"

  tui_input "IP pública del servidor para /etc/hosts" "$cur_srv_ip" valid_single_ip "Indica una dirección IPv4/IPv6 válida (no 127.x.x.x)."
  SERVER_IP="$TUI_REPLY"

  tui_input "Zona horaria (IANA)" "$cur_tz" valid_timezone "Zona horaria no encontrada en /usr/share/zoneinfo (ej. UTC o America/Mexico_City)."
  TIMEZONE="$TUI_REPLY"

  tui_section "2. Usuario administrativo y sudo"
  tui_input "Nombre del usuario administrador (no root)" "${ADMIN_USER:-adminops}" valid_username "Usa minúsculas, dígitos, _ o - (sin root)."
  ADMIN_USER="$TUI_REPLY"

  tui_select "Modo de privilegios sudo para ${ADMIN_USER}" "${SUDO_MODE:-password}" \
    "password|Pedir contraseña al ejecutar sudo (recomendado; se solicitará en el paso 01)" \
    "nopasswd|Permitir sudo sin contraseña (NOPASSWD en /etc/sudoers.d)"
  SUDO_MODE="$TUI_REPLY"
  ADMIN_PASSWORD_HASH="${ADMIN_PASSWORD_HASH:-}"

  tui_section "3. Llaves SSH públicas"
  SB_KEYS=()
  if declare -p SSH_PUBLIC_KEYS >/dev/null 2>&1 && (( ${#SSH_PUBLIC_KEYS[@]} > 0 )) && [[ "${SSH_PUBLIC_KEYS[0]}" != *AAAA_REEMPLAZAR* ]]; then
    printf '  Llaves actuales detectadas: %d\n' "${#SSH_PUBLIC_KEYS[@]}"
    tui_yesno "¿Conservar las llaves públicas actuales?" "yes"
    if [[ "$TUI_REPLY" == "yes" ]]; then
      SB_KEYS=("${SSH_PUBLIC_KEYS[@]}")
    fi
  elif [[ -s /root/.ssh/authorized_keys ]]; then
    local root_key
    root_key="$(grep -Ev '^[[:space:]]*(#|$)' /root/.ssh/authorized_keys | head -n1 || true)"
    if [[ -n "$root_key" ]] && valid_pubkey "$root_key"; then
      printf '  Detectada llave en /root/.ssh/authorized_keys:\n  \033[2m%.68s...\033[0m\n' "$root_key"
      tui_yesno "¿Importar esta llave para ${ADMIN_USER}?" "yes"
      if [[ "$TUI_REPLY" == "yes" ]]; then
        SB_KEYS+=("$root_key")
      fi
    fi
  fi

  while (( ${#SB_KEYS[@]} == 0 )); do
    tui_input "Pega la llave SSH PÚBLICA (ssh-ed25519 / ssh-rsa / ecdsa / sk-*)" "" valid_pubkey "No parece una llave pública OpenSSH válida."
    SB_KEYS+=("$TUI_REPLY")
  done

  while true; do
    tui_yesno "¿Agregar otra llave SSH pública adicional?" "no"
    [[ "$TUI_REPLY" == "no" ]] && break
    tui_input "Llave SSH pública adicional" "" valid_pubkey "No parece una llave pública OpenSSH válida."
    SB_KEYS+=("$TUI_REPLY")
  done

  tui_section "4. SSH, Firewall (UFW) y Fail2Ban"
  tui_input "Puerto SSH deseado" "${SSH_PORT:-22}" valid_port "Debe ser un puerto entre 1 y 65535."
  SSH_PORT="$TUI_REPLY"

  tui_yesno "¿Habilitar firewall UFW (entrada DENY, salida ALLOW)?" "${ENABLE_UFW:-yes}"
  ENABLE_UFW="$TUI_REPLY"

  if [[ "$ENABLE_UFW" == "yes" ]]; then
    tui_input "Puertos extra en UFW separados por espacio (ej. '80/tcp 443/tcp', vacío = solo SSH)" "${EXTRA_UFW_PORTS:-}" valid_ufw_ports "Usa formato puerto/proto, ej.: 80/tcp 443/tcp 60000:61000/udp"
    EXTRA_UFW_PORTS="$TUI_REPLY"
  else
    EXTRA_UFW_PORTS=""
  fi

  tui_yesno "¿Habilitar Fail2Ban para proteger SSH?" "${ENABLE_FAIL2BAN:-yes}"
  ENABLE_FAIL2BAN="$TUI_REPLY"

  if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
    local default_ignore="${FAIL2BAN_IGNOREIP:-$cur_ip}"
    tui_input "IPs/redes en lista blanca de Fail2Ban (separadas por espacio, vacío = solo loopback)" "$default_ignore" valid_ip_list "Formato inválido. Ejemplo: 203.0.113.10 198.51.100.0/24"
    FAIL2BAN_IGNOREIP="$TUI_REPLY"
  else
    FAIL2BAN_IGNOREIP=""
  fi

  tui_section "5. Actualizaciones automáticas"
  tui_yesno "¿Habilitar actualizaciones automáticas de seguridad (unattended-upgrades)?" "${ENABLE_UNATTENDED_UPGRADES:-yes}"
  ENABLE_UNATTENDED_UPGRADES="$TUI_REPLY"
  if [[ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]]; then
    tui_yesno "¿Reiniciar automáticamente si el kernel lo requiere?" "${AUTO_REBOOT:-no}"
    AUTO_REBOOT="$TUI_REPLY"
    if [[ "$AUTO_REBOOT" == "yes" ]]; then
      tui_input "Hora del reinicio automático (HH:MM)" "${AUTO_REBOOT_TIME:-04:00}" valid_time "Formato de 24 horas HH:MM, ej.: 04:00"
      AUTO_REBOOT_TIME="$TUI_REPLY"
    fi
  fi

  tui_section "6. MOTD con ASCII Art (el .bashrc y prompt se configuran automáticamente)"
  tui_yesno "¿Configurar MOTD de bienvenida con banner ASCII Art y estado del servidor?" "${ENABLE_MOTD:-yes}"
  ENABLE_MOTD="$TUI_REPLY"

  if [[ "$ENABLE_MOTD" == "yes" ]]; then
    tui_input "Texto del banner ASCII Art (vacío = usar hostname '${SERVER_HOSTNAME}')" "${MOTD_TEXT:-$SERVER_HOSTNAME}" valid_motd_text "Máximo 40 caracteres: letras, números, espacio y . _ ! -"
    MOTD_TEXT="$TUI_REPLY"

    tui_select "Color neón del banner MOTD" "${MOTD_COLOR:-lime}" \
      "lime|Verde lima neón (default)" \
      "green|Verde matriz" \
      "cyan|Cian eléctrico" \
      "magenta|Magenta neón" \
      "pink|Rosa neón" \
      "orange|Naranja láser" \
      "yellow|Amarillo neón" \
      "purple|Púrpura eléctrico" \
      "blue|Azul hielo" \
      "red|Rojo carmesí" \
      "toxic|Gradiente Toxic (verde → lima → amarillo)" \
      "synthwave|Gradiente Synthwave (magenta → violeta → cian)" \
      "rainbow|Gradiente Arcoíris neón"
    MOTD_COLOR="$TUI_REPLY"

    tui_select "Nombre del diseño ASCII Art para el MOTD" "${MOTD_ART_STYLE:-claude}" \
      "claude|Claude Code (emblema de terminal + tipografía ANSI con sombra 3D)" \
      "hermes|Hermes Agent (emblema alado + tipografía ANSI con sombra 3D)" \
      "shadow|ANSI Shadow 3D (tipografía con relieve y sombreado ▀ ▄ █ ░)" \
      "block|Bloques sólidos Unicode (██)" \
      "ascii|Caracteres ASCII clásicos (##)"
    MOTD_ART_STYLE="$TUI_REPLY"

    printf '\n  \033[2mVista previa del banner MOTD:\033[0m\n'
    render_ascii_banner "${MOTD_TEXT:-$SERVER_HOSTNAME}" "$MOTD_COLOR" "$MOTD_ART_STYLE"
  fi

  CONFIRM_SSH_HARDENING="${CONFIRM_SSH_HARDENING:-NO}"
  write_config_file "$target"
  log "Configuración guardada en ${target} (permisos 600)."
}

