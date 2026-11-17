# Fedora Atomic Buildbox Architecture Overview

This setup layers **immutable OS infrastructure**, **declarative Nix Flakes**, **rootless Podman Devcontainers**, and **version-controlled `/etc` drop-ins** to get low-level workstation performance and full portability while keeping the host OS clean, auditable, and reproducible on a fresh machine:

1. **Immutable Base OS (`Fedora Atomic / rpm-ostree`)**: `/usr` stays read-only and untouched—zero `rpm-ostree install` package layering. That keeps OS updates fast and atomic and prevents package drift over time, while `/var/home` lives on Btrfs with copy-on-write compression (`zstd:1`).
2. **Determinate Nix + Cross-Platform `flake.nix`**: Multi-user `/nix` store (`nix-daemon.socket`) bind-mounted from `/var/home/nix` using `root.transient = true` + `nix-mkdir.service` on `composefs` hosts. All project compilers, runtimes, native C libraries, and Chromium wrappers are pinned in `flake.nix` + `flake.lock` and auto-loaded via `direnv` + `nix-direnv`.
3. **Nix-Backed Devcontainer (`.devcontainer/`)**: Secondary onboarding, Codespaces, and CI-parity container built on Debian Bookworm + single-user Nix consuming the exact same `flake.nix`. `init-host.sh` auto-detects rootless Podman (`keep-id`, SELinux `label:disable`, `oom_score_adj` parity, NVIDIA CDI) vs Docker Desktop / Codespaces.
4. **Rootless `Podman` with `Docker` CLI Workflows**: Rather than running a root Docker daemon, the user-level `podman.socket` is enabled (`systemctl --user enable --now podman.socket`) and Nix's `docker-client` / `docker-compose` / `docker-buildx` point at `DOCKER_HOST` automatically.
5. **Drop-In Configs in Git (Never Editing `/etc` In-Place)**: System tweaks (`sysctl.d`, `zram-generator.conf.d`, `udev/rules.d`, `ostree/prepare-root.conf`, `systemd/system/nix-mkdir.service`) and shell exports (`~/.bashrc.d/`) live as modular files in `host/` alongside an idempotent `--status` / `--apply` / `--rollback` orchestrator. Base `/etc` files are never hand-edited.
6. **Dual `/etc` Auditing + Private Snapshot Isolation**: Whenever `host/apply_host_tuning.sh` applies or rolls back host changes, it takes pre- and post-change Git commits in `/etc/.git` (via `etckeeper` or Git, ignoring `shadow` and host keys) and saves `ostree admin config-diff` to a private host-state directory outside the public repo.

| Tool / Layer | Role in the Setup | How It Is Tracked / Reproduced |
| :--- | :--- | :--- |
| **Fedora Atomic (`rpm-ostree`)** | Immutable `/usr` base OS + Btrfs CoW `/var/home` | Stock upstream image + private `ostree admin config-diff` audit |
| **Determinate Nix + `flake.nix`** | Multi-user `/nix` store (`nix-daemon.socket`) + pinned devShell (`Linux` + `aarch64-darwin`) | `flake.nix`, `flake.lock`, `.envrc`, `host/etc/ostree/prepare-root.conf`, `nix-mkdir.service` |
| **Option A Devcontainer** | Disposable, CI-identical container sharing host `flake.lock` | `.devcontainer/` + `init-host.sh` + `post-create.sh` |
| **`host/` Drop-Ins & Orchestrator** | Portable source of truth for kernel, zram, CPU EPP, and shell exports | Standard `git clone` + `sudo bash host/apply_host_tuning.sh --apply` |
| **`etckeeper` / `/etc/.git`** | Chronological commit log of live `/etc` before and after every change | Automatic pre/post commits in `/etc/.git` (`sudo git -C /etc log -p`) |
| **Rootless `Podman` + `Docker` CLI** | Daemonless container runtime compatible with `docker` and `docker compose` | User `systemd` socket (`podman.socket`) + `DOCKER_HOST` export |
