#!/usr/bin/env bash
# Solicita un secreto (contraseña SSH / sudo) mediante un diálogo modal nativo del SO
# (macOS osascript, Linux zenity/kdialog/ssh-askpass/tkinter, Windows/WSL PowerShell WinForms)
# y lo guarda con permisos 0600 sin imprimir jamás el valor en stdout/stderr (cero trazabilidad en logs de agentes IA).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/prompt-secret.sh --out <DEST_FILE> [options]

Options:
  --out FILE        Path where the secret will be saved with 0600 permissions (required).
  --title TEXT      Modal window title (default: "Server Bootstrap — Secure Credential").
  --prompt TEXT     Descriptive prompt for the user (default: "Enter password:").
  --confirm         Ask to confirm the password a second time (useful when setting a new password).
  --allow-tty       Allow falling back to hidden input on /dev/tty if no GUI is available.
  -h, --help        Show this help.
EOF
}

OUT_FILE=""
TITLE="Server Bootstrap — Secure Credential"
PROMPT_TEXT="Enter password:"
CONFIRM=0
ALLOW_TTY=1

while (( $# > 0 )); do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || { echo "[ERROR] Missing argument for --out" >&2; exit 1; }
      OUT_FILE="$2"
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || { echo "[ERROR] Missing argument for --title" >&2; exit 1; }
      TITLE="$2"
      shift 2
      ;;
    --prompt)
      [[ $# -ge 2 ]] || { echo "[ERROR] Missing argument for --prompt" >&2; exit 1; }
      PROMPT_TEXT="$2"
      shift 2
      ;;
    --confirm)
      CONFIRM=1
      shift
      ;;
    --allow-tty)
      ALLOW_TTY=1
      shift
      ;;
    --no-tty)
      ALLOW_TTY=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1 (use --help)" >&2
      exit 1
      ;;
  esac
done

[[ -n "$OUT_FILE" ]] || { echo "[ERROR] Debes indicar --out <ARCHIVO_DESTINO>" >&2; exit 1; }

# Detecta plataforma: macos | wsl | windows | linux
detect_platform() {
  local u
  u="$(uname -s 2>/dev/null || echo unknown)"
  case "$u" in
    Darwin*) echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    Linux*)
      if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    *) echo "linux" ;;
  esac
}

# 1) macOS: AppleScript sobre SystemUIServer (sale al frente sin pedir permisos de Accesibilidad).
ask_macos() {
  local title="$1" prompt="$2"
  command -v osascript >/dev/null 2>&1 || return 2
  osascript - "$title" "$prompt" <<'APPLESCRIPT'
on run argv
  set dlgTitle to item 1 of argv
  set dlgPrompt to item 2 of argv
  try
    tell application "SystemUIServer"
      activate
      set response to display dialog dlgPrompt default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" with title dlgTitle
    end tell
  on error errMsg number errNum
    if errNum is -128 then
      error "Operation cancelled by user." number 1
    end if
    set response to display dialog dlgPrompt default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" with title dlgTitle
  end try
  set secretValue to text returned of response
  if secretValue is "" then
    error "Password cannot be empty." number 2
  end if
  return secretValue
end run
APPLESCRIPT
}

# 2) Windows / WSL2: PowerShell + System.Windows.Forms (modal TopMost con máscara de contraseña).
ask_windows() {
  local title="$1" prompt="$2"
  local ps_bin=""
  if command -v powershell.exe >/dev/null 2>&1; then
    ps_bin="powershell.exe"
  elif command -v pwsh.exe >/dev/null 2>&1; then
    ps_bin="pwsh.exe"
  elif command -v pwsh >/dev/null 2>&1; then
    ps_bin="pwsh"
  else
    return 2
  fi

  PROMPT_MODAL_TITLE="$title" PROMPT_MODAL_TEXT="$prompt" "$ps_bin" -NoProfile -NonInteractive -STA -Command '
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $env:PROMPT_MODAL_TITLE
    $form.Size = New-Object System.Drawing.Size(440, 190)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.Size = New-Object System.Drawing.Size(395, 42)
    $label.Text = $env:PROMPT_MODAL_TEXT
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(16, 64)
    $textBox.Size = New-Object System.Drawing.Size(392, 26)
    $textBox.UseSystemPasswordChar = $true
    $form.Controls.Add($textBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Location = New-Object System.Drawing.Point(242, 106)
    $okButton.Size = New-Object System.Drawing.Size(80, 28)
    $okButton.Text = "Continuar"
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $okButton
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(328, 106)
    $cancelButton.Size = New-Object System.Drawing.Size(80, 28)
    $cancelButton.Text = "Cancel"
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $cancelButton
    $form.Controls.Add($cancelButton)

    $form.Add_Shown({ $form.Activate(); $textBox.Focus() })
    $result = $form.ShowDialog()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
      [Console]::Error.WriteLine("Operation cancelled by user.")
      exit 1
    }
    if ([string]::IsNullOrEmpty($textBox.Text)) {
      [Console]::Error.WriteLine("Password cannot be empty.")
      exit 2
    }
    [Console]::Out.Write($textBox.Text)
  ' | tr -d '\r'
}

# 3) Linux Desktop (X11 / Wayland): zenity -> kdialog -> ssh-askpass -> python3 tkinter.
ask_linux_gui() {
  local title="$1" prompt="$2"
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 2

  local out=""
  if command -v zenity >/dev/null 2>&1; then
    out="$(zenity --password --title="$title" --text="$prompt" 2>/dev/null)" || return 1
  elif command -v kdialog >/dev/null 2>&1; then
    out="$(kdialog --title "$title" --password "$prompt" 2>/dev/null)" || return 1
  elif command -v ssh-askpass >/dev/null 2>&1; then
    out="$(ssh-askpass "${title} — ${prompt}" 2>/dev/null)" || return 1
  elif command -v python3 >/dev/null 2>&1; then
    out="$(PROMPT_MODAL_TITLE="$title" PROMPT_MODAL_TEXT="$prompt" python3 - <<'PY'
import os, sys
try:
    import tkinter as tk
    from tkinter import simpledialog
except Exception:
    sys.exit(2)
root = tk.Tk()
root.withdraw()
root.attributes("-topmost", True)
val = simpledialog.askstring(
    os.environ.get("PROMPT_MODAL_TITLE", "Credencial"),
    os.environ.get("PROMPT_MODAL_TEXT", "Password:"),
    show="*",
    parent=root,
)
root.destroy()
if val is None:
    sys.exit(1)
if val == "":
    sys.exit(3)
sys.stdout.write(val)
PY
)" || return 1
  else
    return 2
  fi

  if [[ -z "$out" ]]; then
    echo "[ERROR] Password cannot be empty." >&2
    return 1
  fi
  printf '%s' "$out"
}

# 4) Fallback interactivo en /dev/tty si no hay entorno gráfico disponible.
ask_tty() {
  local title="$1" prompt="$2" val=""
  (( ALLOW_TTY == 1 )) || return 2
  [[ -r /dev/tty && -w /dev/tty ]] || return 2
  printf '\n[%s]\n%s ' "$title" "$prompt" >/dev/tty
  IFS= read -rs val </dev/tty || { printf '\n' >/dev/tty; return 1; }
  printf '\n' >/dev/tty
  if [[ -z "$val" ]]; then
    echo "[ERROR] Password cannot be empty." >&2
    return 1
  fi
  printf '%s' "$val"
}

prompt_once() {
  local title="$1" prompt="$2" platform
  platform="$(detect_platform)"
  case "$platform" in
    macos)
      ask_macos "$title" "$prompt" && return 0
      ;;
    windows|wsl)
      ask_windows "$title" "$prompt" && return 0
      ;;
    linux)
      ask_linux_gui "$title" "$prompt" && return 0
      ;;
  esac
  ask_tty "$title" "$prompt"
}

SECRET_VAL="$(prompt_once "$TITLE" "$PROMPT_TEXT")" || {
  echo "[ERROR] Could not obtain password (cancelled by user or no GUI/TTY access). If running from an AI agent, make sure to run outside the sandbox (BypassSandbox / escalated permissions)." >&2
  exit 1
}

if (( CONFIRM == 1 )); then
  SECRET_CONFIRM="$(prompt_once "$TITLE" "Confirm password:")" || {
    echo "[ERROR] Confirmation cancelled." >&2
    exit 1
  }
  if [[ "$SECRET_VAL" != "$SECRET_CONFIRM" ]]; then
    echo "[ERROR] Passwords do not match." >&2
    exit 1
  fi
  unset SECRET_CONFIRM
fi

mkdir -p "$(dirname "$OUT_FILE")"
(
  umask 077
  printf '%s' "$SECRET_VAL" >"$OUT_FILE"
)
chmod 600 "$OUT_FILE"
secret_len="${#SECRET_VAL}"
unset SECRET_VAL

printf '[OK] Password captured securely in %s (length: %d characters, permissions: 600).\n' "$OUT_FILE" "$secret_len"

