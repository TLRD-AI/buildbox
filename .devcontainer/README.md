# Exemplar Nix-Backed Devcontainer (`Option A`)

This `.devcontainer/` directory implements a **single-source-of-truth** development container driven directly by the repository's root [`flake.nix`](../flake.nix) and [`flake.lock`](../flake.lock).

Instead of maintaining a separate `apt` / `curl` toolchain manifest inside `Dockerfile.dev` that drifts from host workstations, the container installs single-user Nix + `direnv`/`nix-direnv` on a lean Debian Bookworm base and hydrates the exact same pinned `/nix/store` derivations used on Fedora Atomic Linux, macOS Apple Silicon, and CI.

---

## Architecture Highlights

| File | Runs Where | Responsibility |
| :--- | :--- | :--- |
| [`devcontainer.json`](devcontainer.json) | Host IDE / `@devcontainers/cli` | Orchestrates Compose (`db`, `redis`, `dev`), forwards ports, sets `BASH_ENV` for non-interactive shells, and triggers `init-host.sh` + `post-create.sh` |
| [`Dockerfile.dev`](Dockerfile.dev) | Image build (`dev`) | Debian 12 Slim + UID/GID `1000` `appuser` + single-user Nix (`sandbox = false`, `filter-syscalls = false`) + `direnv`/`nix-direnv` + `.buildbox-bash-env` |
| [`docker-compose.devcontainer.yml`](docker-compose.devcontainer.yml) | Compose stack | Defines `db` (`postgres:16-alpine`, `shm_size: 2gb`), `redis` (`redis:7-alpine`), and `dev` (`shm_size: 2gb`, named volumes isolating `/nix` and caches) |
| [`init-host.sh`](init-host.sh) | Host (`initializeCommand`) | Bootstraps `.env` from `.env.example` if absent; auto-detects rootless Podman (`keep-id`, SELinux `label:disable`, `oom_score_adj` parity, NVIDIA CDI) vs Docker Desktop/Codespaces into gitignored `docker-compose.local.yml` |
| [`post-create.sh`](post-create.sh) | Container (`postCreateCommand`) | Fixes named-volume permissions, enables `scripts/git-hooks` secret guardrails, materializes `/nix/var/nix/profiles/buildbox-dev-env.sh`, and allows `.envrc` |

---

## Why Rootless Podman Needs `init-host.sh`

On **Fedora Atomic / Kinoite** running rootless Podman under `systemd` (`app.slice`):
1. **UID / File Ownership (`userns_mode: keep-id`)**: Maps host UID `1000` directly to container `appuser` (`1000:1000`) on bind-mounted `/workspace` files.
2. **SELinux Relabeling Avoidance (`security_opt: [label:disable]`)**: Allows the container to access `/workspace` cleanly without relabeling host Btrfs subvolumes or breaking host IDE access.
3. **`oom_score_adj` Parity**: Under KDE/GNOME `app.slice` (typically `OOMScoreAdjust=200`), Podman's Docker-compat API clamps omitted container `oom_score_adj` to `200` on `create` while `exec`/healthchecks try `0` (`EACCES`). Setting `oom_score_adj` explicitly on `db`, `redis`, and `dev` keeps `create`, `exec`, and healthchecks consistent.
4. **Native Podman Builder (`DOCKER_BUILDKIT=0` / `COMPOSE_BAKE=false`)**: When `flake.nix` detects rootless `podman.sock`, it defaults `DOCKER_BUILDKIT=0` and `COMPOSE_BAKE=false` so `docker compose build` and `devcontainer up` use Podman's native Buildah builder instead of spawning a nested `moby/buildkit` container.
5. **Optional NVIDIA CDI GPU Passthrough**: If `/etc/cdi/nvidia.yaml` (or `/var/run/cdi/nvidia.yaml`) exists, `init-host.sh` injects `driver: cdi` (`nvidia.com/gpu=all`). Otherwise `flake.nix` automatically switches Chromium ANGLE GL to SwiftShader software WebGL.

On **macOS (OrbStack / Docker Desktop / Colima)**, **Ubuntu**, and **GitHub Codespaces**, `init-host.sh` writes `services: {}` to `docker-compose.local.yml` so the stack boots with standard Docker semantics and zero manual editing.

---

## Quick Usage

```bash
# 1. On Fedora Atomic with rootless Podman socket active:
systemctl --user enable --now podman.socket

# 2. Bring up the stack (db, redis, dev) via @devcontainers/cli inside nix develop:
nix develop -c devcontainer up --workspace-folder .

# 3. Run the verification suite inside the container:
nix develop -c devcontainer exec --workspace-folder . bash scripts/verify.sh

# 4. Tear down when finished (preserves named /nix and cache volumes):
nix develop -c docker compose \
  -f .devcontainer/docker-compose.devcontainer.yml \
  -f .devcontainer/docker-compose.local.yml \
  down
```
