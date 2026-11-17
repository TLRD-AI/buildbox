# Plan 2: Cross-Platform `flake.nix` + `direnv` Dev Shell

**Goal:** Replace ad-hoc host binaries or manual `.toolchains/` extracts with a pinned, declarative Nix dev shell that behaves consistently across Fedora Atomic Linux (`x86_64-linux`), Linux ARM64 (`aarch64-linux`), Apple Silicon macOS (`aarch64-darwin`), and GitHub Actions CI (`ubuntu-latest` + `macos-latest`).

**Prerequisite:** Plan 1 (Determinate Nix installed on the host) or Nix in CI via `DeterminateSystems/nix-installer-action`.

**Status:** Phases A, B, C, and E implemented and verified on Linux (`python315`, `flutter`, `nodejs_22`, `docker-client` + `docker-compose` + `docker-buildx`, Nix `chromium` GPU/SwiftShader wrapper, `direnv` + `nix-direnv` via `.envrc`). Note: `nixpkgs` `26.11` (`nixos-unstable`) dropped `x86_64-darwin`, so `flake.nix` targets `[ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ]`.

---

## 1. Toolchain Mapping

| Need | Legacy Host Approach | Nix Replacement | Notes |
| :--- | :--- | :--- | :--- |
| Python 3.15 + `.venv` | Host `python3.15` + `.venv` | `pkgs.python315` + `pkgs.uv` | Keep `uv` + `requirements*.txt` as Python package source of truth; Nix supplies interpreter and native C libs |
| Native libs (`WeasyPrint`, `Pillow`, `psycopg`) | Host system packages | `pango`, `cairo`, `gdk-pixbuf`, `harfbuzz`, `fontconfig`, `glib`, `libffi`, `openssl`, `zlib`, `libjpeg`, `postgresql.lib` | Exposed via `LD_LIBRARY_PATH` (Linux) / `DYLD_FALLBACK_LIBRARY_PATH` (macOS) |
| Node 22 + npm | Extracted Node wrapper | `pkgs.nodejs_22` | Works directly with `npm ci` |
| Headless Chrome / Chromium | Puppeteer-downloaded binary | Linux: wrapped `pkgs.chromium` via `CHROME_BIN`; macOS: system `/Applications/Google Chrome.app` | Sets `PUPPETEER_SKIP_DOWNLOAD=1`; Linux wrapper isolates NVIDIA GL/EGL libs and falls back to SwiftShader |
| Flutter & Dart | Manual `.toolchains/flutter` | `pkgs.flutter` (pinned in `flake.lock`) | Eliminates manual SDK syncing across machines |
| Compression & CLI tools | Toolbx-extracted binaries | `pkgs.brotli`, `pkgs.gzip`, `pkgs.ripgrep`, `pkgs.fd`, `pkgs.binaryen`, `pkgs.jq`, `pkgs.shellcheck` | Direct replacement without manual `LD_LIBRARY_PATH` binary shims |
| `docker` / `compose` / `buildx` | Custom wrapper around `podman.sock` | `pkgs.docker-client`, `pkgs.docker-compose`, `pkgs.docker-buildx` + `DOCKER_HOST` | Host Podman or macOS container runtime stays on the host |
| Runtime env vars | `~/.bashrc.d/` exports | `shellHook` in `devShells.default` | `DJANGO_TEST_PARALLEL` derived dynamically from `nproc` / `sysctl -n hw.ncpu` |

---

## 2. Core Files in `buildbox`

```text
buildbox/
├── flake.nix                  # Cross-platform devShell + Linux GPU/SwiftShader Chromium wrapper
├── flake.lock                 # Committed lockfile pinning every tool version
├── .envrc                     # `use flake` (auto-loaded via direnv + nix-direnv)
└── .github/workflows/ci.yml   # Verifies flake + verify.sh on ubuntu-latest and macos-latest
```

---

## 3. Phased Rollout

### Phase A — Basic Shell & Native Library Parity on Linux
1. Author `flake.nix` and lock inputs with `nix flake lock`.
2. Confirm every tool resolves from `/nix/store`:
   ```bash
   nix develop -c bash -c 'for t in python3 uv node npm flutter brotli rg fd wasm-opt jq docker docker-compose chromium; do printf "%-15s %s\n" "$t" "$(command -v "$t")"; done'
   ```
3. Confirm native C library discovery (`pango-1.0`, `cairo`, `pq`, `ssl`) and headless Chromium WebGL/SwiftShader rendering (`scripts/verify.sh`).
4. **Non-NixOS NVIDIA GL isolation:** Never export `/usr/lib64` directly into `LD_LIBRARY_PATH`. Symlink only `lib*nvidia*.so*`, `libEGL_nvidia*.so*`, `libGLX_nvidia*.so*`, and `libGLESv2_nvidia*.so*` into `~/.cache/buildbox-nix-gl`, set `__EGL_VENDOR_LIBRARY_FILENAMES`, `__GLX_VENDOR_LIBRARY_NAME`, and `VK_ICD_FILENAMES` (checking both `/usr/share/vulkan/icd.d/` and `/etc/vulkan/icd.d/`), and fall back to `--use-angle=swiftshader --enable-unsafe-swiftshader` when GPU render nodes are absent.

### Phase B — Auto-Load with `direnv` + `nix-direnv`
1. Install via Nix profile:
   ```bash
   nix profile add nixpkgs#direnv nixpkgs#nix-direnv
   ```
2. Source `nix-direnv` in `~/.config/direnv/direnvrc` and hook `direnv` at the bottom of `~/.bashrc` / `~/.zshrc`.
3. Add `.envrc` containing `use flake` and run `direnv allow`.
4. Remember that non-interactive agent tool calls (`bash -c ...`) do not trigger interactive `direnv` hooks—always invoke automation via `nix develop -c ...`.

### Phase C — Apple Silicon macOS (`aarch64-darwin`) & CI
1. Use `pkgs.mkShellNoCC` on Darwin so Nix never injects `clang-wrapper`, `DEVELOPER_DIR`, or `SDKROOT` over `/Applications/Xcode.app`.
2. Export `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` when running forked Python test workers on macOS.
3. Run scripts via Nix's `bash` (`nix develop -c bash scripts/verify.sh`) rather than `/usr/bin/env bash` so Apple SIP does not strip `DYLD_FALLBACK_LIBRARY_PATH`.
4. Wire `.github/workflows/ci.yml` with `DeterminateSystems/nix-installer-action` and `DeterminateSystems/magic-nix-cache-action` on `[ubuntu-latest, macos-latest]`.

### Phase D — Retire Manual `.toolchains/` Fallbacks
Once Linux, macOS, and CI gates pass using `flake.nix`, legacy `.toolchains/` directories can be archived and host tuning can run with `--skip-toolbox`.

---

## 4. Done Criteria

- `nix flake show --no-write-lock-file` evaluates cleanly.
- `nix develop -c bash scripts/verify.sh` passes on Linux, Apple Silicon macOS, and GitHub Actions CI.
- All secrets and host-specific artifacts remain isolated outside tracked public files.
