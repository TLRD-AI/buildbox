# Buildbox — Exemplar Fedora Atomic + Determinate Nix + Devcontainer Stack

A reproducible, zero-snowflake development workstation and cross-platform Devcontainer blueprint for **Fedora Atomic / Kinoite (`rpm-ostree`)**, **Apple Silicon macOS (`aarch64-darwin`)**, and **GitHub Actions CI**, built around **Determinate Nix Flakes**, **rootless Podman**, **`/etc/.git` (`etckeeper`) auditing**, and strict **public/private secret isolation**.

---

## Architecture at a Glance

```text
  +-------------------------------------------------------------------+
  |  Layer 1: Immutable Host OS (Fedora Atomic / Kinoite)             |
  |  * Read-only /usr (zero rpm-ostree package layering)              |
  |  * /etc/ostree/prepare-root.conf (composefs + root.transient=true)|
  |  * /etc/systemd/system/nix-mkdir.service (pre-mounts /nix)        |
  |  * Modular 99-* drop-ins in host/etc/ + /etc/.git rollback ledger |
  +---------------------------------+---------------------------------+
                                    |
  +---------------------------------v---------------------------------+
  |  Layer 2: Declarative Nix Flake (flake.nix + flake.lock + .envrc) |
  |  * x86_64-linux, aarch64-linux, aarch64-darwin (mkShellNoCC)      |
  |  * Pinned Python 3.15, uv, Node 22, Flutter, Brotli, Binaryen     |
  |  * Isolated NVIDIA GL/EGL + SwiftShader Chromium wrapper on Linux |
  +---------------------------------+---------------------------------+
                                    |
  +---------------------------------v---------------------------------+
  |  Layer 3: Option A Nix-Backed Devcontainer (.devcontainer/)       |
  |  * Debian Bookworm + single-user Nix + direnv + BASH_ENV          |
  |  * init-host.sh auto-detects rootless Podman keep-id, SELinux,    |
  |    systemd app.slice oom_score_adj parity, and NVIDIA CDI         |
  |  * Postgres 16 + Redis 7 Compose stack with named /nix volume     |
  +---------------------------------+---------------------------------+
                                    |
  +---------------------------------v---------------------------------+
  |  Layer 4: Secret Guardrails & Private Host Overlay                |
  |  * scripts/check_secrets.sh + scripts/git-hooks/pre-commit        |
  |  * Raw host state (ostree-etc-diff.txt, .env) stays outside this  |
  |    public repo in ../buildbox-private or gitignored .local/state  |
  +-------------------------------------------------------------------+
```

---

## Repository Layout

| Path | Purpose |
| :--- | :--- |
| [`flake.nix`](flake.nix) & [`flake.lock`](flake.lock) | Cross-platform Nix devShell (`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`), `mkShellNoCC` Darwin Xcode isolation, and NVIDIA/SwiftShader Chromium wrapper |
| [`.envrc`](.envrc) & [`.env.example`](.env.example) | `direnv` + `nix-direnv` activation and zero-secret local env template |
| [`.devcontainer/`](.devcontainer/README.md) | Self-contained Option A Nix-backed Devcontainer (`Dockerfile.dev`, `devcontainer.json`, Compose stack, `init-host.sh`, `post-create.sh`) |
| [`host/`](host/README.md) | Fedora Atomic `ostree/prepare-root.conf`, `nix-mkdir.service`, `sysctl.d`/`zram`/`udev` drop-ins, shell exports, and `apply_host_tuning.sh` (`--status`/`--apply`/`--rollback`) |
| [`scripts/verify.sh`](scripts/verify.sh) | Verifies secrets hygiene, `bash -n` + `shellcheck`, Nix toolchain & native C libraries, Compose config, and headless Chromium WebGL/SwiftShader |
| [`scripts/check_secrets.sh`](scripts/check_secrets.sh) & [`scripts/git-hooks/`](scripts/git-hooks/README.md) | Secret and host-artifact scanner run by `pre-commit` and CI |
| [`docs/`](docs/README.md) | Architecture guides, public/private split guide, and phased plans (`plan-1` through `plan-5`) |
| [`.github/workflows/`](.github/workflows/) | CI workflows for secret/shell linting, `nix develop` (`ubuntu-latest` + `macos-latest`), and `.devcontainer/` build verification |

---

## Quickstart

### 1. Enable Pre-Commit Secret Guardrails (Recommended on Any Clone)

```bash
git config core.hooksPath scripts/git-hooks
```

### 2. Enter the Declarative Nix DevShell (Linux or Apple Silicon macOS)

Requires [Determinate Nix](https://docs.determinate.systems/) (on Fedora Atomic 41+/45+ with `composefs`, follow [`docs/plans/plan-1-determinate-nix-installer.md`](docs/plans/plan-1-determinate-nix-installer.md) first):

```bash
# Run full verification inside the pinned devShell
nix develop -c bash scripts/verify.sh

# Or auto-load the shell when entering this directory
direnv allow
```

### 3. Apply Fedora Atomic Host Tuning (Optional, Linux Host Only)

```bash
# Inspect live kernel, CPU EPP, zram, Btrfs, Nix, NVIDIA CDI, and /etc status (no sudo)
bash host/apply_host_tuning.sh --status

# Link interactive shell exports
mkdir -p ~/.bashrc.d
ln -sfn "$(pwd)/host/bashrc.d/99-buildbox-env.sh" ~/.bashrc.d/99-buildbox-env.sh

# Apply modular /etc drop-ins and record pre/post commits in /etc/.git
sudo bash host/apply_host_tuning.sh --apply --skip-toolbox

# Revert cleanly at any time
sudo bash host/apply_host_tuning.sh --rollback
```

### 4. Boot the Exemplar Nix-Backed Devcontainer

Works on **Fedora Atomic rootless Podman**, **macOS (OrbStack / Docker Desktop / Colima)**, **Ubuntu**, and **GitHub Codespaces**:

```bash
# On Fedora Atomic, ensure the user Podman socket is active first:
systemctl --user enable --now podman.socket

# Start db, redis, and dev (auto-generates gitignored .env & docker-compose.local.yml)
nix develop -c devcontainer up --workspace-folder .

# Run checks inside the devcontainer
nix develop -c devcontainer exec --workspace-folder . bash scripts/verify.sh
```

---

## Security & Public/Private Repository Separation

`TLRD-AI/buildbox` is intentionally **public** and contains **zero secrets or raw host dumps**:
- **Never commit** `.env`, SSH/signing keys, `*.nmconnection` Wi-Fi profiles, `machine-id`, or raw `ostree admin config-diff` snapshots to this repository.
- Keep machine-specific state in a separate **private** repository with **zero shared Git history** (for example `../buildbox-private`), or locally under gitignored `.local/state/`.
- See [`docs/private-overlay-guide.md`](docs/private-overlay-guide.md) for the full dual-repo pattern, why you should never fork a private secrets repo into a public one, and how `host/apply_host_tuning.sh` routes host snapshots to `../buildbox-private` automatically.
