# Plan 3: Option A Nix-Backed Devcontainer (Rootless Podman, Codespaces & CI Parity)

**Goal:** Provide a zero-host-setup containerized dev environment driven by `.devcontainer/devcontainer.json` that shares the exact same `flake.nix` + `flake.lock` as the host, works seamlessly on **Fedora Atomic rootless Podman**, **macOS**, **GitHub Codespaces**, and **GitHub Actions**, and prevents host/container drift.

**Positioning:** Secondary onboarding, Codespaces, and CI-parity option alongside host Nix (`flake.nix`). Interactive GPU Chromium and native hardware builds remain fastest directly on the host.

**Status:** Implemented and verified on Fedora 45 Kinoite (rootless Podman) and scaffolded for GitHub Actions (`.github/workflows/devcontainer-ci.yml`).

---

## 1. Architecture Decision: Nix-Backed Devcontainer (Option A) vs. Standalone `Dockerfile.dev`

| Approach | How It Works | Pros | Cons |
| :--- | :--- | :--- | :--- |
| **Option A (Chosen): Nix-Backed Devcontainer** | Minimal Debian Bookworm base + single-user Nix (`flake.nix` + `flake.lock`), loading the Nix devShell via `BASH_ENV` and `direnv` | **Single source of truth** (`flake.lock`) shared across Linux, macOS, CI, and container | Initial build populates `/nix` inside a named Docker/Podman volume |
| **Option B: Standalone `Dockerfile.dev`** | Duplicates Python, Node, Flutter, Chromium, `brotli`, and `wasm-opt` via `apt`/tarballs | Familiar apt pattern | **Two tool manifests that drift apart** |

---

## 2. File Layout in `.devcontainer/`

```text
.devcontainer/
├── README.md                        # Usage & rootless Podman notes
├── devcontainer.json                # Compose orchestration, ports, BASH_ENV, postCreateCommand
├── docker-compose.devcontainer.yml  # db (Postgres 16), redis (Redis 7), and dev service + named volumes
├── Dockerfile.dev                   # Debian 12 Slim + UID 1000 appuser + single-user Nix + direnv
├── init-host.sh                     # Bootstraps .env from .env.example; writes gitignored docker-compose.local.yml
└── post-create.sh                   # Hydrates Nix profile, installs git hooks, runs scripts/verify.sh --quick
```

---

## 3. Critical Engineering Details Solved

1. **Container-Safe Single-User Nix (`/etc/nix/nix.conf`):**
   - Containers lack `systemd` and nested user namespaces by default. `Dockerfile.dev` installs Nix with `--no-daemon --yes` owned by `appuser` (`1000:1000`) and configures:
     ```ini
     experimental-features = nix-command flakes
     sandbox = false
     filter-syscalls = false
     build-users-group =
     max-jobs = auto
     ```
2. **Non-Interactive Shell Environment (`BASH_ENV`):**
   - `post-create.sh` runs `nix develop /workspace --profile /nix/var/nix/profiles/buildbox-dev` and exports `PATH`, `LD_LIBRARY_PATH`, `CHROME_BIN`, `PYTHON_JIT`, `PUPPETEER_SKIP_DOWNLOAD`, `PUB_CACHE`, and `DJANGO_TEST_PARALLEL` into `/nix/var/nix/profiles/buildbox-dev-env.sh`.
   - `devcontainer.json` sets `BASH_ENV=/home/appuser/.buildbox-bash-env`, so `devcontainer exec bash -c ...` commands immediately see the Nix toolchain without needing an interactive shell.
3. **Rootless Podman vs. Docker Desktop / Codespaces (`init-host.sh`):**
   - On rootless Podman (Fedora Kinoite), `init-host.sh` generates gitignored `.devcontainer/docker-compose.local.yml` with:
     - `userns_mode: keep-id` (UID 1000 bind-mount parity)
     - `security_opt: ["label:disable"]` (SELinux bind-mount access without relabeling host Btrfs trees)
     - `oom_score_adj` matching `podman.service` / `/proc/self/oom_score_adj` (fixes `OOMScoreAdjust=200` `EACCES` on `exec`/healthchecks under systemd `app.slice`)
     - Optional NVIDIA CDI device reservation (`nvidia.com/gpu=all`) when `/etc/cdi/nvidia.yaml` exists
   - On Docker Desktop, OrbStack, Colima, and GitHub Codespaces, `init-host.sh` writes `services: {}`.
4. **Shared Memory (`/dev/shm`) & SwiftShader WebGL:**
   - Both `db` and `dev` allocate `shm_size: 2gb` so PostgreSQL parallel workers and headless Chromium never hit Docker's tiny 64 MB default `/dev/shm`.
   - When GPU render nodes (`/dev/nvidia0`, `/dev/dri/renderD*`) are absent inside containers/CI, `flake.nix`'s `buildboxChromium` wrapper automatically switches `--use-angle=gl` to `--use-angle=swiftshader --enable-unsafe-swiftshader`.
5. **Named Volumes for Performance & ABI Isolation:**
   - `/nix`, `pub-cache`, and `uv` caches (plus `.venv` / `node_modules` in downstream apps) live in named Linux volumes so macOS APFS/VirtioFS case-insensitivity and `aarch64-darwin` binaries never collide with `aarch64-linux` containers.
6. **Fresh Clone `.env` Safety:**
   - `init-host.sh` copies `.env.example` -> `.env` when absent, and `docker-compose.devcontainer.yml` marks `env_file` with `required: false` so `docker compose config -q` passes even before `init-host.sh` runs.

---

## 4. Verification Commands

```bash
# Bring up Compose stack (on Fedora Atomic, pass --docker-path if using a Podman docker shim)
nix develop -c devcontainer up --workspace-folder .

# Run verification checks inside the running container
nix develop -c devcontainer exec --workspace-folder . bash scripts/verify.sh
```
