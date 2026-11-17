# How to Version-Control an Entire Linux Build Box on Fedora Atomic Using Determinate Nix, Devcontainers, `/etc` Snapshots (`etckeeper`), and Rootless Podman

Modern workstations often force an uncomfortable choice between:
1. Low-level host tuning (custom `sysctl` limits, `zstd` zram, `amd-pstate-epp` performance governors, NVIDIA persistence mode, Btrfs `zstd:1` compression, and full CLI toolchains).
2. **Zero Snowflake Syndrome** — every host change tracked in version control, diffable against the stock OS image, reversible with one command, and reproducible on a fresh machine without `rpm-ostree` package layering.

This blueprint resolves that tension with a six-part stack tested on **Fedora 45 Kinoite (`rpm-ostree`)** with an 8C/16T Ryzen CPU, 32 GB RAM, and NVIDIA RTX GPU, plus **Apple Silicon macOS** parity.

---

## 1. Immutable Base OS (`Fedora Atomic / rpm-ostree`) + Btrfs CoW

Because `/usr` is read-only on Fedora Kinoite/Silverblue, the base OS never accumulates mystery `dnf` drift. Only `/etc` and `/var` (including `/var/home` on Btrfs with `compress=zstd:1`) are writable.
- **Zero `rpm-ostree install` layering**: OS updates stay fast and atomic.
- **Instant CoW Workspaces**: Because `/var/home` is Btrfs with `zstd:1`, spinning up parallel git worktrees or copy-on-write agent workspaces costs almost zero extra disk space and nearly zero I/O time.

---

## 2. Determinate Nix on `composefs` + Cross-Platform `flake.nix`

Fedora Atomic (41+ / 45+) mounts `/` read-only via `composefs`, which causes Determinate Nix's default `nix-directory.service` (`chattr -i /`) to fail with `Operation not supported`.

This stack solves that cleanly without layering packages onto `rpm-ostree`:
1. Enable `root.transient = true` in `/etc/ostree/prepare-root.conf` (tracked in initramfs via `sudo rpm-ostree initramfs-etc --track=/etc/ostree/prepare-root.conf --reboot`).
2. Add `nix-mkdir.service` (`ConditionPathExists=!/nix`, `Before=nix-directory.service nix.mount`) so `/nix` exists before `nix.mount` bind-mounts `/var/home/nix` -> `/nix`.
3. Install Determinate Nix with `sh -s -- install ostree`.
4. Pin all project runtimes and native C libraries (`python315`, `uv`, `nodejs_22`, `flutter`, `brotli`, `binaryen`, `docker-client`, `pango`/`cairo`/`libpq`, etc.) inside [`../flake.nix`](../flake.nix) + [`../flake.lock`](../flake.lock), auto-loaded via `.envrc` (`direnv` + `nix-direnv`).

### Non-NixOS NVIDIA GL/EGL Isolation (`buildboxChromium`)

Setting `LD_LIBRARY_PATH=/usr/lib64` on a non-NixOS Linux host breaks `/nix/store` binaries by leaking the host's `glibc`. Instead, [`../flake.nix`](../flake.nix) wraps `nixpkgs#chromium` by symlinking **only** host `lib*nvidia*.so*`, `libEGL_nvidia*.so*`, `libGLX_nvidia*.so*`, and `libGLESv2_nvidia*.so*` into `~/.cache/buildbox-nix-gl`, setting `__EGL_VENDOR_LIBRARY_FILENAMES`, `__GLX_VENDOR_LIBRARY_NAME`, and `VK_ICD_FILENAMES`, and automatically falling back to `--use-angle=swiftshader --enable-unsafe-swiftshader` when no GPU render node is attached (such as inside CI or GPU-less Devcontainers).

---

## 3. Option A Nix-Backed Devcontainer (`.devcontainer/`)

Rather than maintaining a second apt/curl toolchain inside `Dockerfile.dev` that drifts from host workstations, [`.devcontainer/`](../.devcontainer/README.md) uses a minimal Debian Bookworm base with single-user Nix (`sandbox = false`, `filter-syscalls = false`, `build-users-group =`) and hydrates the exact same `flake.nix` inside a named `/nix` volume (`buildbox-nix-store`).

Before Compose boots, [`.devcontainer/init-host.sh`](../.devcontainer/init-host.sh) inspects `docker info` and writes a gitignored `.devcontainer/docker-compose.local.yml`:
- **On Fedora rootless Podman**: Adds `userns_mode: keep-id`, `security_opt: [label:disable]`, explicit `oom_score_adj` matching systemd `app.slice` (preventing Podman's `OOMScoreAdjust=200` `create` vs `exec` `EACCES` bug), and NVIDIA CDI (`nvidia.com/gpu=all`) when `/etc/cdi/nvidia.yaml` exists.
- **On macOS / Ubuntu / Codespaces**: Writes `services: {}` so standard Docker Compose semantics apply unmodified.

---

## 4. Rootless Podman Masquerading as Docker

To keep `docker` and `docker compose` workflows working unmodified without a root daemon:
- Enable the user socket: `systemctl --user enable --now podman.socket` (`/run/user/$UID/podman/podman.sock`).
- `flake.nix` and `host/bashrc.d/99-buildbox-env.sh` export `DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"` when the socket is active.
- Using Nix-provided `docker-client`, `docker-compose`, and `docker-buildx` also avoids Fedora's `/usr/bin/docker-compose` `docker-compose-switch` recursion edge case.

---

## 5. Never Edit `/etc` In-Place — Use Modular Drop-Ins Checked Into Git

Instead of hand-editing `/etc/sysctl.conf` or `/etc/systemd/zram-generator.conf`, modular drop-ins live in [`../host/etc/`](../host/etc/):
- `sysctl.d/99-buildbox.conf` (`inotify` watches at 1M, `vm.swappiness=100` for `zstd` zram, `kernel.sched_autogroup_enabled=1` for responsive interactive desktop/browser scheduling)
- `systemd/zram-generator.conf.d/99-buildbox-zram.conf` (`min(ram / 2, 16384)` `zstd` swap)
- `systemd/journald.conf.d/99-buildbox-journal.conf` & `systemd/coredump.conf.d/99-buildbox-coredump.conf` (`250M` / `256M` caps on compact Btrfs roots)
- `udev/rules.d/99-amd-pstate-epp.rules` (`amd-pstate-epp` `balance_performance` for cool idle + full single-core boost)
- `ostree/prepare-root.conf` & `systemd/system/nix-mkdir.service` (Fedora Atomic `/nix` support)
- `flatpak/com.google.Chrome/chrome-flags.conf` (Wayland Ozone, GPU rasterization, NVIDIA VA-API video decode)
- `bashrc.d/99-buildbox-env.sh` (symlinked into `~/.bashrc.d/`)

---

## 6. Dual-Ledger `/etc` Auditing: `etckeeper` (`/etc/.git`) + Private `ostree admin config-diff`

[`../host/apply_host_tuning.sh`](../host/apply_host_tuning.sh) bridges this repository and live `/etc` using `--status`, `--user-desktop`, `--apply`, and `--rollback`:
1. **Pre-snapshot**: Initializes `/etc/.git` (or uses host `etckeeper`) with a `.gitignore` excluding secrets (`shadow*`, `ssh_host_*_key`, `pki/*/private/*`) and commits a pre-tuning snapshot.
2. **Apply**: Installs the modular drop-ins into `/etc`, reloads `sysctl`/`udev`/`zram0`/`journald`, switches `tuned-adm` to `desktop` (or `throughput-performance` under `BUILDBOX_WORKLOAD=build`), enables Btrfs `compress=zstd:1` and NVIDIA persistence mode, generates `/etc/cdi/nvidia.yaml` via `nixpkgs#nvidia-container-toolkit`, and applies user `~/.bashrc.d` + Flatpak Chrome GPU flags.
3. **Post-snapshot + Private Ostree diff**: Commits the post-tuning state to `/etc/.git` and writes `ostree admin config-diff` strictly to `$BUILDBOX_PRIVATE_DIR` (`../buildbox-private/hosts/<host>/ostree-etc-diff.txt` or gitignored `.local/state/ostree-etc-diff.txt`) so personal Wi-Fi SSIDs, machine IDs, and key filenames never touch the public repository.
4. **One-command rollback**: `sudo bash host/apply_host_tuning.sh --rollback` deletes the drop-ins, restores the `balanced` CPU profile, and records a rollback commit in `/etc/.git`.
