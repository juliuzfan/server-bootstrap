---
name: server-bootstrap
description: >-
  Autonomously and securely provisions and hardens remote Debian 13 servers over SSH
  (with root or non-root sudo user, key or password authentication).
  Use when the user asks to configure, initialize, secure, or bootstrap a
  Debian/VPS server by providing its IP or DNS, initial credentials, and preferences.
---

# Server Bootstrap (Autonomous Agent)

This skill guides the agent to configure a remote **Debian 13** server unattended via [remote-bootstrap.sh](../../../scripts/remote-bootstrap.sh), avoiding the interactive TUI and ensuring SSH access is never lost and passwords are never exposed in the LLM context.

## Locating the Orchestrator and Utilities

Look for `remote-bootstrap.sh` and `prompt-secret.sh` in the first available path:
1. `./scripts/remote-bootstrap.sh` and `./scripts/prompt-secret.sh` (when this skill is installed globally with its bundle).
2. `../../../scripts/remote-bootstrap.sh` and `../../../scripts/prompt-secret.sh` relative to this `SKILL.md` (inside the `server-bootstrap` repository).
3. `./scripts/remote-bootstrap.sh` in the current workspace if you are inside the repo.

---

## Mandatory Workflow

### Step 1: Gather Minimum Information (ask only for what is missing from the prompt)

Do not ask redundant questions about what the human already specified, but **do confirm** any missing item before executing:

1. **Target & initial access**:
   - IP or DNS (`--host`).
   - Initial SSH port (`--ssh-port`, default `22`).
   - Initial user (`--ssh-user`, default `root`; use `debian`, `admin`, etc. if the provider does not enable direct `root`).
   - Initial credential: path to private key (`--ssh-key`) or initial password (will be requested via **native OS modal** with `--prompt-init-pass`; **never ask the user to type it in chat**).
2. **Public SSH key for the new `ADMIN_USER`**:
   - If the human already provided a public key (or `.pub` path), use it.
   - If **not**: check which public keys exist in `~/.ssh/*.pub` and ask the human whether they prefer:
     - **(a)** Using an existing system key (showing the detected path), or
     - **(b)** Generating a dedicated `ed25519` key pair for that server (e.g., `~/.ssh/id_ed25519_<hostname>` with `ssh-keygen -t ed25519 -N "" -f ... -C ...`).
3. **Admin user & password (`SUDO_MODE`)**:
   - Confirm `ADMIN_USER` (default `adminops`) and `SUDO_MODE` (`password` or `nopasswd`).
   - If `SUDO_MODE="password"` and the human did not provide a hash:
     - Ask whether they **want to enter their own password in a secure native OS modal window** (`--prompt-admin-pass`) **or** **prefer the agent to generate a secure random password** and deliver it only at the end.
4. **Customizable options (apply defaults if the human does not request changes)**:
   - `SERVER_HOSTNAME` (default: `debian-server`), `SERVER_IP` (auto-detect), `TIMEZONE` (default: `UTC`).
   - Final `SSH_PORT` (`--target-ssh-port`, default `22`).
   - `ENABLE_UFW` (`yes`), `EXTRA_UFW_PORTS` (e.g., `"80/tcp 443/tcp"`).
   - `ENABLE_FAIL2BAN` (`yes`), `FAIL2BAN_IGNOREIP` (optional whitelist).
   - `ENABLE_UNATTENDED_UPGRADES` (`yes`), `AUTO_REBOOT` (`no`), `AUTO_REBOOT_TIME` (`04:00`).
   - `ENABLE_MOTD` (`yes`), `MOTD_TEXT` (empty = `SERVER_HOSTNAME`), `MOTD_COLOR` (`lime`, `green`, `cyan`, `magenta`, `pink`, `orange`, `yellow`, `purple`, `blue`, `red`, `toxic`, `synthwave`, `rainbow`), `MOTD_ART_STYLE` (`claude`, `hermes`, `shadow`, `block`, `ascii`).

---

### Step 2: Secure Password Capture via Native Modal (macOS / Linux / Windows / WSL)

- **NEVER** ask for passwords in chat, pass them as plaintext command-line arguments, or print them to `stdout`/`stderr`.
- **Use the built-in modal flags in `remote-bootstrap.sh`** (or invoke `scripts/prompt-secret.sh` directly):
  - `--prompt-init-pass`: opens a native OS dialog with a hidden field (`•••••`) to capture the initial SSH/sudo password.
  - `--prompt-admin-pass`: opens a native OS dialog (with double confirmation) to capture the `sudo` password for the new `ADMIN_USER`.
  - If you need to capture a secret separately before running a command:
    ```bash
    bash scripts/prompt-secret.sh \
      --title "Server Bootstrap — Secure Credential" \
      --prompt "Current root password to connect to the server:" \
      --out /tmp/sb-secret.XXXXXX
    ```
- **Automatic cross-platform support in `prompt-secret.sh`**:
  - **macOS (`Darwin`)**: uses `osascript` via `SystemUIServer` with `with hidden answer` and `activate` (brings the dialog to the front without requiring Accessibility permissions).
  - **Linux (X11 / Wayland)**: uses `zenity --password`, `kdialog --password`, `ssh-askpass`, or `python3` (`tkinter.simpledialog`).
  - **Windows (Git Bash / MSYS2) & WSL2**: invokes `powershell.exe -NoProfile -NonInteractive -STA` with a `System.Windows.Forms` dialog (`UseSystemPasswordChar = $true`, `TopMost = $true`).
  - **No-GUI fallback**: reads from `/dev/tty` with `read -rs`.

#### ⚠️ Harness Permissions (Mandatory for the OS to display the modal and allow SSH networking)

AI agent sandboxes (Seatbelt on macOS for Codex/Antigravity, Landlock/Bubblewrap on Linux) block both SSH network connections and access to the graphical server (`WindowServer` / `mach-lookup` on macOS, X11/D-Bus on Linux, `powershell.exe` interop on WSL) by default.

Therefore, when invoking `remote-bootstrap.sh` or `prompt-secret.sh`:
- **In Antigravity**: run `run_command` with `BypassSandbox: true`.
- **In OpenAI Codex CLI / Desktop**: run the shell tool with escalated permissions (`with_escalated_permissions: true` / `sandbox_permissions: "require_escalated"`).
- **In Claude Code / Cursor**: run the command allowing sandbox bypass if prompted by the environment.

---

### Step 3: Autonomous Execution & Per-Phase Checks

1. **(Recommended optional)** Run `--dry-run` first (with `--prompt-init-pass` if using an initial password) to validate initial SSH connectivity, verify the remote system is Debian, and check privileges (`root` or `sudo`).
2. Run `remote-bootstrap.sh` with all agreed flags:
   - **Phase 01**: installs packages (`neovim`, `htop`, `wget`, `locales`, `sharutils`, etc.), creates `ADMIN_USER`, installs SSH keys, configures `sudo`, `.bashrc`, and MOTD.
   - **External check 1**: the script opens a **new, independent** SSH session as `ADMIN_USER` and validates `sudo`. If it fails, **it aborts without hardening SSH** to keep initial access intact.
   - **Phase 02 (and port transition)**: if `--target-ssh-port` differs from the initial port, it opens both ports (`--transition-only`), verifies external connectivity on the new port, and only then closes the old port and enables Fail2Ban. If the new port does not respond, it leaves both ports open and aborts.
   - **Phase 03**: runs `03-verify.sh` and cleans up the remote temporary directory and any local temporary password files.

---

### Step 4: Final Report to the Human

When finished (or if any check fails), report clearly and concisely:
1. **Status of each phase and `03-verify.sh` summary** (`OK / WARN / FAIL` or the exact diagnostic if a connection check failed, indicating which ports remain open).
2. **Exact command to connect**:
   `ssh -p <SSH_PORT> [-i <key_path>] <ADMIN_USER>@<HOST>`
3. **Generated credentials** (only if the agent generated a dedicated SSH key or a random `sudo` password), indicating the key path or password so the human can store it safely.
