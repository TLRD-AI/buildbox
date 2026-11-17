# Plan 4: Migrate & Configure an 8 GB Apple Silicon Mac onto Nix Flakes & Devcontainer

**Goal:** Onboard an **8 GB Apple M1 Mac** (`arm64` / `aarch64-darwin`, 8 cores: 4P + 4E, 8 GB unified RAM) cleanly onto the pinned Nix dev shell (`flake.nix` + `flake.lock` + `.envrc`) and optionally verify the `.devcontainer/` stack within an 8 GB unified-memory budget—without Homebrew/pyenv/nvm/Flutter PATH collisions, macOS SIP `DYLD_*` stripping failures, VM OOM kills, or Linux-vs-macOS binary corruption across shared mounts.

---

## 1. Hardware, Architecture & Memory Budget (8 GB M1)

- **Apple Silicon (`arm64` -> `aarch64-darwin`):** Supported natively by `flake.nix` (`[ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ]`). Keep `flake.lock` pinned so derivations download prebuilt binaries from `cache.nixos.org` instead of compiling locally on 8 GB RAM.
- **Mutually Exclusive Workflow Rule on 8 GB RAM:** Run **either** the native macOS Nix flake (`nix develop` / `direnv` with container VMs stopped) **or** the Linux Devcontainer VM (capped at ~4–4.5 GB RAM), never both under heavy parallel load simultaneously.
- **Concurrency Cap:** Set `DJANGO_TEST_PARALLEL=4` (or `2` inside a 4 GB container VM) and `FLUTTER_TEST_CONCURRENCY=4` so parallel workers match the 4 Performance cores and stay comfortably within RAM.
- **Xcode Command Line Tools:** Required for `git` and Apple `clang` headers (`xcode-select --install`).

---

## 2. Phase 0 — Audit Existing macOS Shell Pollution

Before installing Nix, inspect existing shell startup files and tools:

```zsh
ls -la ~/.zshenv ~/.zprofile ~/.zshrc ~/.bashrc ~/.bash_profile 2>/dev/null
which -a python3 uv node npm flutter dart brotli rg fd wasm-opt docker
env | grep -E '^(PATH|FLUTTER_ROOT|PUB_CACHE|PYTHONPATH|PYTHONHOME|VIRTUAL_ENV|DOCKER_HOST|CHROME_BIN|PUPPETEER|DYLD_|OBJC_)'
```

**Common macOS traps:**
1. **`~/.zshenv` exports:** Sourced by *every* `zsh` invocation (interactive and non-interactive). Never set `PATH`, `FLUTTER_ROOT`, `PYTHONHOME`, or `PYTHONPATH` inside `~/.zshenv`.
2. **Version managers (`pyenv`, `conda`, `nvm`, `fnm`, `fvm`):** Leave them if needed for other projects, **provided** `eval "$(direnv hook zsh)"` sits at the **very bottom** of `~/.zshrc` so `direnv` prepends `/nix/store/.../bin` ahead of Homebrew/shims inside flake repos.

---

## 3. Phase 1 — Install Determinate Nix, `direnv`, and `nix-direnv` on macOS

Determinate Nix works seamlessly with macOS's sealed Signed System Volume (SSV) by adding `nix` to `/etc/synthetic.conf`, creating a **case-sensitive APFS volume (`Nix Store`)**, and mounting it at `/nix`:

```zsh
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Open a fresh terminal (or source `/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`), verify `nix --version`, then install `direnv` + `nix-direnv`:

```zsh
nix profile add nixpkgs#direnv nixpkgs#nix-direnv

mkdir -p ~/.config/direnv
cat <<'EOF' > ~/.config/direnv/direnvrc
if [ -f "$HOME/.nix-profile/share/nix-direnv/direnvrc" ]; then
  source "$HOME/.nix-profile/share/nix-direnv/direnvrc"
elif [ -f "/nix/var/nix/profiles/default/share/nix-direnv/direnvrc" ]; then
  source "/nix/var/nix/profiles/default/share/nix-direnv/direnvrc"
fi
EOF
```

Add `eval "$(direnv hook zsh)"` to the bottom of `~/.zshrc`, then enter the cloned repository and run `direnv allow`.

> **macOS OS Update Note:** Major macOS updates occasionally reset `/etc/synthetic.conf` or `/etc/zshrc`. Run `sudo /nix/nix-installer repair` if `/nix` disappears after an update.

---

## 4. Phase 2 — Critical macOS Mechanics Built Into `flake.nix`

1. **System Integrity Protection (SIP) & `DYLD_FALLBACK_LIBRARY_PATH` Stripping:**
   - macOS SIP strips `DYLD_*` environment variables whenever a SIP-protected binary (`/usr/bin/env`, `/bin/bash`, `/bin/sh`) launches.
   - Because shell scripts commonly start with `#!/usr/bin/env bash`, executing `./scripts/verify.sh` directly strips `DYLD_FALLBACK_LIBRARY_PATH`.
   - **Rule:** Always invoke scripts via Nix's `bash` (`nix develop -c bash scripts/verify.sh`), which runs `/nix/store/.../bin/bash` (not SIP-protected).
2. **macOS Objective-C Fork Safety (`OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES`):**
   - Python 3.15 multiprocessing `fork` after macOS Foundation initialization aborts child processes unless `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` is set. `flake.nix` exports this automatically on `!isLinux`.
3. **Xcode Isolation (`mkShellNoCC`):**
   - `flake.nix` selects `pkgs.mkShellNoCC` on Darwin and unsets `DEVELOPER_DIR`, `SDKROOT`, `NIX_CFLAGS_COMPILE`, and `NIX_LDFLAGS` so Nix never shadows `/Applications/Xcode.app`.
4. **Google Chrome / Puppeteer:**
   - Install `/Applications/Google Chrome.app`; `flake.nix` skips Linux Chromium on Darwin and exports `PUPPETEER_SKIP_DOWNLOAD=1`.

Verify natively on macOS:

```zsh
nix develop -c bash scripts/verify.sh
```

---

## 5. Phase 3 — Optional Devcontainer Runtime on 8 GB macOS

> **256 GB SSD Note:** If configuring the Mac mini as a dedicated Xcode CI node (Plan 5), skip the Linux Devcontainer VM on macOS to preserve ~15–25 GB SSD and 4 GB RAM headroom.

If running `.devcontainer/` on macOS:
- **Preferred VM runtime for 8 GB RAM:** **OrbStack** (Memory cap = **4 GB**, dynamic memory ballooning, stop with `orb stop`) or **Colima** (`colima start --arch aarch64 --vm-type vz --mount-type virtiofs --cpu 4 --memory 4 --disk 50`). Avoid Podman Machine on macOS with `init-host.sh` due to `keep-id` + VirtioFS quirks.
- **Named Volume Isolation:** `docker-compose.devcontainer.yml` isolates `/nix`, caches, and downstream `.venv` / `node_modules` inside named Linux volumes so `aarch64-darwin` host binaries never collide with `aarch64-linux` container binaries.
- **Global `@devcontainers/cli` under Nix Node:** Set a writable prefix (`mkdir -p ~/.local/npm-global && nix develop -c npm config set prefix "$HOME/.local/npm-global"`) so `npm install -g @devcontainers/cli` does not attempt writing into read-only `/nix/store`.
