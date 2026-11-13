# Debian 13 Server Bootstrap

Get a freshly installed **Debian 13 (Trixie)** server ready in just a few minutes.

Through an interactive terminal wizard (pure Bash TUI, no external dependencies), it configures the base system, creates your admin user with `sudo`, hardens OpenSSH without locking you out, enables the firewall, and customizes the terminal with a modern prompt and a neon-colored ASCII Art banner.

> **Golden rule:** keep your current `root` session open and have your provider's web console handy until you verify that you can log in from a new window.

---

## Quick Start

On a minimal Debian image, `git` is usually not pre-installed. Log in as `root` (or a user with `sudo`) and run:

```bash
# 1. Install git and base certificates
apt-get update && apt-get install -y git ca-certificates

# 2. Clone the repository
git clone https://github.com/juliuzfan/server-bootstrap.git
cd server-bootstrap

# 3. Start the interactive wizard
sudo bash bootstrap.sh
```

The wizard will guide you step by step with navigable menus (`↑`/`↓` and `Enter`), detect current server settings, show you a color preview of the banner, and save your `config.env` with secure permissions (`600`).

---

## How Does It Prevent Losing SSH Access?

The process is divided into phases with confirmation pauses so you never lock out `root` blindly:

1. **Phase 01 — System & User**: installs packages, configures `sudo`, and adds your public SSH key to the new user without touching `sshd` restrictions yet.
2. **Verification pause**: the script pauses and shows you the exact command to open **another terminal** and verify that you can log in with your key and that `sudo -v` responds properly.
3. **Phase 02 — Hardening**: only after you confirm by typing `YES` does it disable `root` login and password authentication over SSH.
   - *If you chose to change the SSH port (e.g., from `22` to `2222`)*: it temporarily opens **both ports** in the firewall and `sshd`, asks you to test the new port, and only then closes the old one.
4. **Phase 03 — Verification**: prints a final `[OK] / [WARN] / [FAIL]` summary of the server state.

---

## What's Included

### System & Maintenance
- **Updates & tools**: updates packages non-interactively and installs essential utilities (`htop`, `neovim` as the system replacement for `vim`/`vi`/`editor`, `wget`, `curl`, `git`, `lsof`, `dnsutils`, `sharutils`).
- **Identity, `/etc/hosts`, locales & time**: sets the `hostname`, registers the server's public IP (`SERVER_IP`, chosen or auto-detected) in `/etc/hosts` alongside `127.0.1.1`, enables the `en_US.UTF-8` locale, sets the timezone (`UTC` by default), and enables `chrony` for NTP synchronization.
- **Automatic patches**: enables `unattended-upgrades` with an optional scheduled automatic reboot if required by the kernel.

### Access & Security
- **Admin user with real `sudo`**: creates the user and configures `sudo` with a password (prompted in step 01 or via hash) or passwordless (`NOPASSWD` validated with `visudo`).
- **SSH keys**: accepts one or more public keys (`ed25519`, `rsa`, `ecdsa`, and `sk-*` FIDO2 hardware keys), validated with `ssh-keygen`.
- **Hardened OpenSSH**: applies configuration in `/etc/ssh/sshd_config.d/`, validates it with `sshd -t` before reloading, and performs automatic rollback if anything fails.
- **Firewall (UFW)**: blocks all incoming traffic except SSH and any extra ports you specify (e.g., `80/tcp 443/tcp`), with IPv6 support and automatic cleanup of old rules.
- **Fail2Ban**: protects the SSH port using the `systemd` + `nftables` backend and lets you whitelist trusted IPs or networks.

### Terminal Experience (`.bashrc` + Prompt + MOTD)
- **Ready-to-use `.bashrc` and Prompt out of the box**: automatically installs your standard `.bashrc` for `root`, the admin user, and `/etc/skel` (Roster.li header with dynamic year and hostname, color prompt with Git branch `on <branch>`, navigation/safety/`nvim`/`gst` aliases, and the `password_generator` function).
- **Welcome MOTD with ASCII Art**: generates a pure-Bash banner selectable by name (`claude` Claude Code style, `hermes` Hermes Agent style, `shadow` 3D ANSI, `block`, or `ascii`), using the server name or custom text, neon or gradient colors (`lime`, `cyan`, `magenta`, `toxic`, `synthwave`, `rainbow`, etc.), and a login resource summary (OS, IP, uptime, load, RAM, and disk).

---

## Advanced Usage & Automation

If you prefer preparing the configuration without going through the interactive wizard:

```bash
cp config.env.example config.env
chmod 600 config.env
nano config.env
sudo bash bootstrap.sh
```

### Command-Line Options

```bash
sudo bash bootstrap.sh --wizard                  # Open the TUI wizard to edit config.env
sudo bash bootstrap.sh --config /path/config.env # Use a specific configuration file
sudo bash bootstrap.sh --yes                     # Unattended mode (CI/CD or cloud-init)
```

> In `--yes` mode, make sure `config.env` has `CONFIRM_SSH_HARDENING="YES"` and `SUDO_MODE="nopasswd"` (or `ADMIN_PASSWORD_HASH`).

You can also run each stage independently at any time:

```bash
sudo bash scripts/01-system.sh
sudo bash scripts/02-security.sh
sudo bash scripts/03-verify.sh
```

All execution output is logged to `/var/log/server-bootstrap.log`.

---

## Quick `config.env` Reference

| Variable | Default | Description |
| :--- | :--- | :--- |
| `SERVER_HOSTNAME` | `"debian-server"` | Server name (registered in `/etc/hosts`). |
| `SERVER_IP` | `""` *(auto-detect)* | Server public IP to associate with the hostname in `/etc/hosts`. |
| `TIMEZONE` | `"UTC"` | IANA timezone (e.g. `UTC`, `America/Mexico_City`). |
| `ADMIN_USER` | `"adminops"` | Non-root administrative user. |
| `SUDO_MODE` | `"password"` | `password` (prompts for password on `sudo`) or `nopasswd`. |
| `ADMIN_PASSWORD_HASH` | `""` | Optional hash (`openssl passwd -6`) for non-interactive mode. |
| `SSH_PUBLIC_KEYS` | *(required)* | Bash array with one or more OpenSSH public keys. |
| `SSH_PORT` | `"22"` | Final SSH port (`1`–`65535`). |
| `ENABLE_UFW` | `"yes"` | Enables UFW firewall (`yes`/`no`). |
| `EXTRA_UFW_PORTS` | `""` | Space-separated extra ports (e.g. `"80/tcp 443/tcp"`). |
| `ENABLE_FAIL2BAN` | `"yes"` | Enables Fail2Ban for SSH (`yes`/`no`). |
| `FAIL2BAN_IGNOREIP` | `""` | Space-separated whitelisted IPs or networks. |
| `ENABLE_UNATTENDED_UPGRADES` | `"yes"` | Automatic updates (`yes`/`no`), along with `AUTO_REBOOT` and `AUTO_REBOOT_TIME`. |
| `ENABLE_MOTD` | `"yes"` | Installs the ASCII Art banner and login status panel. |
| `MOTD_TEXT` | `""` | Banner text (empty = uses `SERVER_HOSTNAME`). |
| `MOTD_COLOR` | `"lime"` | `lime`, `green`, `cyan`, `magenta`, `pink`, `orange`, `yellow`, `purple`, `blue`, `red`, `toxic`, `synthwave`, `rainbow`. |
| `MOTD_ART_STYLE` | `"claude"` | ASCII Art design: `claude`, `hermes`, `shadow`, `block` (`██`), or `ascii` (`##`). |
| `CONFIRM_SSH_HARDENING` | `"NO"` | Change to `"YES"` after testing key-based SSH access. |

---

## Using with AI Agents (Autonomous & Remote)

The repository includes an **Agent Skill** (`.agents/skills/server-bootstrap/SKILL.md`) and a **remote orchestrator** (`scripts/remote-bootstrap.sh`) so any compatible AI agent (Antigravity, Claude Code, Codex, Gemini CLI, etc.) can configure a remote Debian 13 server given only an IP/DNS, initial credentials (password or SSH key), and natural-language instructions.

- **Global skill installation** (to use it from any project):

```bash
bash scripts/install-skill.sh
```

- **Direct execution of the remote orchestrator**:

```bash
bash scripts/remote-bootstrap.sh \
  --host 203.0.113.10 \
  --ssh-user root \
  --init-pass-file /secure/path/init_pass \
  --hostname srv-prod-01 \
  --timezone America/Mexico_City \
  --admin-user adminops \
  --sudo-mode password \
  --admin-pass-file /secure/path/admin_pass \
  --pubkey ~/.ssh/id_ed25519.pub \
  --target-ssh-port 2222 \
  --extra-ufw-ports "80/tcp 443/tcp"
```

The orchestrator does not require `git` or `sshpass` on the target server, never leaves plaintext passwords in `config.env` or `/var/log/server-bootstrap.log`, and validates SSH + `sudo` access from outside before hardening OpenSSH or closing the old port.

---

## Project Structure

```text
server-bootstrap/
├── .agents/skills/server-bootstrap/
│   └── SKILL.md            # Standard skill for AI agents
├── AGENTS.md               # Quick guide for agents in the repo
├── bootstrap.sh            # Main orchestrator and CLI on the server
├── config.env.example      # Commented configuration template
├── README.md               # Documentation
└── scripts/
    ├── common.sh           # Validations, utilities, and state management
    ├── tui.sh              # TUI wizard and pure-Bash ASCII Art engine
    ├── remote-bootstrap.sh # Autonomous remote orchestrator (SSH + phases)
    ├── install-skill.sh    # Global AI agent skill installer
    ├── 01-system.sh        # Packages, user, sudo, keys, prompt, and MOTD
    ├── 02-security.sh      # SSH hardening, port transition, UFW, and Fail2Ban
    └── 03-verify.sh        # Diagnostics and verification summary
```
