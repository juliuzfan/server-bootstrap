# AI Agent Guide

This repository includes native support for provisioning **Debian 13** servers autonomously and remotely without using the interactive TUI wizard.

- **Main skill**: [.agents/skills/server-bootstrap/SKILL.md](.agents/skills/server-bootstrap/SKILL.md) — Read it and follow its full workflow before running commands.
- **Remote orchestrator**: `scripts/remote-bootstrap.sh` — Runs phases `01-system.sh`, `02-security.sh` (with safe port transition), and `03-verify.sh` from your local machine, performing SSH + `sudo` connection checks between phases.
- **Modal password capture (macOS / Linux / Windows / WSL)**: `scripts/prompt-secret.sh` (or the `--prompt-init-pass` and `--prompt-admin-pass` flags of `remote-bootstrap.sh`) — Displays a native OS dialog with hidden input and saves the secret to a `chmod 600` temporary file without exposing it in stdout/stderr or the agent context.
- **Global skill installation**: `bash scripts/install-skill.sh` — Allows invoking the skill from any other workspace.

## Key Rules
1. Do not run `bootstrap.sh` in interactive mode, do not ask for passwords in chat, and do not pass them as command-line arguments.
2. Use `--prompt-init-pass` / `--prompt-admin-pass` (or `scripts/prompt-secret.sh` to `chmod 600` temporary files with `--init-pass-file` / `--admin-pass-file`) to capture passwords directly from the user via a native OS modal.
3. Run `remote-bootstrap.sh` and `prompt-secret.sh` **outside the harness sandbox** (`BypassSandbox: true` in Antigravity, `with_escalated_permissions: true` in Codex) to allow both SSH connections and access to the OS graphical server (`WindowServer` / X11 / WinForms).
4. Never run `02-security.sh` without going through the external SSH + `sudo` verification of `remote-bootstrap.sh`.
