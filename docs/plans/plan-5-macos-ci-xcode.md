# Plan 5: Harden an 8 GB / 256 GB Apple M1 Mac mini as an Isolated Xcode & Multi-Repo CI Node

**Goal:** Turn an **8 GB / 256 GB Apple M1 Mac mini** (`arm64` / `aarch64-darwin`, 4P + 4E cores) into a hardened, hybrid workstation + self-hosted Apple/Xcode CI node capable of building and testing multiple Apple repositories—using per-repo GitHub Actions self-hosted runners (restricted defensively as if every repo were public), Tailscale SSH for ad-hoc builds, an isolated non-admin `ci` user with its own `ci.keychain-db`, pinned `Xcode.app` + minimal iOS Simulator footprint, and clean Nix-vs-Xcode toolchain isolation.

**Prerequisites:** Plan 4 Phases 0–2 completed (Determinate Nix `aarch64-darwin` + `direnv`/`nix-direnv` installed; container VMs omitted/reclaimed on a 256 GB SSD).

---

## 1. Resource Budget (256 GB SSD / 8 GB Unified RAM)

| Component | Target Allocation | Control Mechanism |
| :--- | :--- | :--- |
| macOS OS / SSV + Recovery | ~28–35 GB | System-managed |
| Interactive admin apps & files | ~25–40 GB | Keep media/VMs off internal SSD |
| Multi-user `/nix` (`Nix Store` APFS volume) | ~6–10 GB | Weekly `nix store gc` |
| Single pinned `/Applications/Xcode.app` | ~12–16 GB | Installed via `xcodes --experimental-unxip`; `.xip` deleted immediately |
| **Single** latest arm64 iOS Simulator runtime | ~7–10 GB | Prune watchOS / tvOS / visionOS / older runtimes |
| DerivedData + SPM + CocoaPods + Runner workdirs | ~15–25 GB cap | Weekly `ci-janitor.sh` pruning |
| **Free Space Floor (APFS CoW + Swap)** | **>= 30–40 GB free** | `ci-xcode-exec` aborts cleanly if `< 25 GB` free |

### 8 GB Unified Memory Guardrails
- **Strict Build Serialization (`ci-build-lock`):** Two concurrent `xcodebuild` or `dart2wasm` jobs exhaust 8 GB RAM and trigger macOS Jetsam (`SIGKILL`). Every CI job and ad-hoc SSH build acquires `/Users/Shared/ci-lock/xcode.lock`.
- **4-Core Concurrency Cap:** Match M1's 4 Performance cores (`-jobs 4` for `xcodebuild`, `COMPILER_INDEX_STORE_ENABLE=NO`).
- **Interactive Pause/Resume:** Fast User Switching keeps `ci`'s Aqua GUI session alive; `ci-ctl stop` / `start` drains runners cleanly before heavy interactive work.

---

## 2. Defensive Topology & Security Model

```text
  GitHub (<org>/<repo-a>, <org>/<repo-b>, ...)             Linux Workstation
         |                                                         |
         |  ONLY push(main), push(v*), workflow_dispatch           |  Tailscale (tailnet)
         |  (NO pull_request / pull_request_target!)               |  ssh ci@<mac-ci-host>
         v                                                         v
+----------------------------------------------------------------------------------+
|  M1 Mac mini (8 GB RAM / 256 GB SSD) -- Hybrid Workstation + CI                  |
|                                                                                  |
|  +----------------------------------+   +--------------------------------------+ |
|  | $ADMIN_USER (Interactive Admin)  |   | ci (Dedicated Standard / Non-Admin)  | |
|  | * Personal SSH, Apple ID, IDE    |   | * Background Aqua session            | |
|  | * chmod 700 /Users/$ADMIN_USER   |   | * LaunchAgents: ~/runners/<repo>     | |
|  | * Tailscale admin + sudo access  |   | * ~/Library/Keychains/ci.keychain-db | |
|  +----------------------------------+   +-------------------+------------------+ |
|                                                             v                    |
|  Shared System Tools (/Users/Shared/ci-tools/, 0755 owned by $ADMIN_USER):       |
|  * ci-build-lock -> /Users/Shared/ci-lock/xcode.lock (1 heavy build at a time)   |
|  * ci-xcode-exec -> sanitized DEVELOPER_DIR/SDKROOT/DYLD_* + 25 GB disk guard    |
+----------------------------------------------------------------------------------+
```

**Key rules:**
1. Under a **GitHub Organization**, you can share org-level runners or register per-repo runner dirs (`~/runners/<repo>`) while `/Users/Shared/ci-lock/xcode.lock` serializes builds across all repos.
2. **Public-Repo Defense:** Self-hosted workflows **never** listen to `pull_request` or `pull_request_target`, `ci` has zero `sudo` access and cannot read `/Users/$ADMIN_USER`, `ci` is **not** in Nix `trusted-users`, and signing credentials live behind a **GitHub Environment (`apple-release`) with Required Reviewers**.

---

## 3. Phase 1 — Host Hardening, Power, FileVault & Tailscale SSH

Execute as `$ADMIN_USER`:

```zsh
# Prevent idle/disk sleep; enable auto-restart on power loss and Wake-on-LAN
sudo pmset -a sleep 0 disksleep 0 displaysleep 10 autorestart 1 womp 1 powernap 0 standby 0

# Allow Fast User Switching so ci's Aqua GUI session stays alive in background
sudo defaults write /Library/Preferences/.GlobalPreferences MultipleSessionEnabled -bool true
```

- **Disable auto-updates** for macOS and App Store apps so overnight updates never break pinned Xcode SDKs mid-build.
- **Headless Display:** Plug in a ~$8 4K HDMI dummy plug if running headless so macOS keeps a hardware framebuffer active.
- **Unsandboxed Tailscale Daemon (`tailscale up --ssh`):** Mac App Store / GUI `Tailscale.app` builds run in Apple's NetworkExtension sandbox and do not support `tailscale up --ssh` or pre-login networking. Install Homebrew's CLI daemon instead:
  ```zsh
  brew install tailscale
  sudo brew services start tailscale
  sudo tailscale up --ssh --hostname=<mac-ci-host>
  ```
  Restrict SSH access in Tailscale ACLs so only your admin workstation can connect to `ci@<mac-ci-host>`.
- **FileVault:** With FileVault enabled, use `sudo fdesetup authrestart` for planned reboots. Unattended power recovery after outages requires either a UPS or keeping CI secrets encrypted separately with FileVault disabled.

---

## 4. Phase 2 — Dedicated Non-Admin `ci` User & `ci.keychain-db`

```zsh
# Create standard (non-admin) user `ci`
sudo sysadminctl -addUser ci \
  -fullName "MacMini CI Runner" \
  -home /Users/ci \
  -shell /bin/zsh \
  -password -

chmod 700 "/Users/$ADMIN_USER"
sudo chmod 700 /Users/ci

sudo mkdir -p /Users/Shared/ci-lock /Users/Shared/ci-tools
sudo chown "$ADMIN_USER:staff" /Users/Shared/ci-tools
sudo chmod 1777 /Users/Shared/ci-lock
sudo chmod 755 /Users/Shared/ci-tools
```

Inside `ci`'s GUI/SSH session:

```zsh
# Disable App Nap and prevent Spotlight from indexing CI builds
defaults write NSGlobalDomain NSAppSleepDisabled -bool YES
mkdir -p ~/runners ~/builds ~/Library/Developer/Xcode/DerivedData ~/.cache ~/.secrets
chmod 700 ~/.secrets
touch ~/runners/.metadata_never_index ~/builds/.metadata_never_index \
      ~/Library/Developer/Xcode/DerivedData/.metadata_never_index ~/.cache/.metadata_never_index

# Install direnv/gh/jq via multi-user Nix (do NOT add `ci` to Nix trusted-users)
. '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
nix profile add nixpkgs#direnv nixpkgs#nix-direnv nixpkgs#gh nixpkgs#jq

# Create isolated CI keychain (keep empty for unsigned PR/main CI; use ephemeral
# per-job keychains under $RUNNER_TEMP deleted via `if: always()` for releases)
openssl rand -base64 32 > ~/.secrets/ci-keychain-pass
chmod 600 ~/.secrets/ci-keychain-pass
KEYCHAIN_PATH="$HOME/Library/Keychains/ci.keychain-db"
KC_PASS="$(cat ~/.secrets/ci-keychain-pass)"
security create-keychain -p "$KC_PASS" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db"
```

---

## 5. Phase 3 — Pinned Xcode & Minimal Simulator Runtime

Run as `$ADMIN_USER`:

```zsh
brew install aria2 fastlane cocoapods create-dmg
brew install xcodesorg/made/xcodes

xcodes install <XCODE_VERSION> --experimental-unxip
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch

# Install only the arm64 iOS Simulator runtime; prune unused ones
sudo xcodebuild -downloadPlatform iOS -architectureVariant arm64
xcrun simctl delete unavailable
```

As `ci`, throttle Xcode compile tasks for 8 GB RAM:

```zsh
defaults write com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks 4
defaults write com.apple.dt.Xcode ShowBuildOperationDuration -bool YES
```

---

## 6. Phase 4 — Nix vs. Xcode Toolchain Isolation & 8 GB Build Lock

Because `flake.nix` uses `pkgs.mkShellNoCC` on Darwin and unsets `DEVELOPER_DIR` / `SDKROOT`, host Xcode works alongside Nix tools. Install these two wrappers into `/Users/Shared/ci-tools/` (`chmod 0755`, owned by `$ADMIN_USER`):

1. **`/Users/Shared/ci-tools/ci-build-lock`** (Python `fcntl.flock` mutex, since stock macOS lacks Linux `flock`):
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   LOCK_FILE="${CI_BUILD_LOCK_FILE:-/Users/Shared/ci-lock/xcode.lock}"
   mkdir -p "$(dirname "$LOCK_FILE")"
   [ "$#" -gt 0 ] || { echo "Usage: ci-build-lock <command> [args...]" >&2; exit 2; }
   exec /usr/bin/python3 - "$LOCK_FILE" "$@" <<'PY'
   import fcntl, os, subprocess, sys
   lock_path, cmd = sys.argv[1], sys.argv[2:]
   fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o666)
   try: os.chmod(lock_path, 0o666)
   except PermissionError: pass
   fcntl.flock(fd, fcntl.LOCK_EX)
   os.ftruncate(fd, 0)
   os.write(fd, f"pid={os.getpid()} user={os.environ.get('USER','?')}\n".encode())
   sys.exit(subprocess.run(cmd).returncode)
   PY
   ```
2. **`/Users/Shared/ci-tools/ci-xcode-exec`** (free-space guard + `caffeinate -s` + sanitized Apple env):
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   MIN_FREE_GB="${CI_MIN_FREE_GB:-25}"
   FREE_GB=$(( $(df -k / | awk 'NR==2 {print $4}') / 1024 / 1024 ))
   if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
     echo "Aborting: only ${FREE_GB} GiB free on / (minimum ${MIN_FREE_GB} GiB)." >&2
     exit 1
   fi
   exec /Users/Shared/ci-tools/ci-build-lock /usr/bin/caffeinate -s /usr/bin/env \
     -u DEVELOPER_DIR -u SDKROOT -u CC -u CXX -u LD -u AR \
     -u NIX_CFLAGS_COMPILE -u NIX_LDFLAGS \
     -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH \
     DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" "$@"
   ```

---

## 7. Phase 5 — Self-Hosted Runners, Defensive Triggers & Disk Janitor

1. **Register `osx-arm64` `actions/runner` as a `LaunchAgent`** (`./svc.sh install && ./svc.sh start`) inside `ci`'s Aqua GUI session so `codesign` and `CoreSimulatorService` have Aqua session access.
2. **Replace each runner's `.env` `PATH`** (`~/runners/<repo>/.env`) with explicit `/Users/Shared/ci-tools`, Homebrew, and Nix paths because `launchd` does not source `~/.zshrc`.
3. **Restrict `.github/workflows/xcode-ci.yml`** strictly to `push` (`main` / `v*`) and `workflow_dispatch`, with `actions/checkout@v4` (`clean: true`, `persist-credentials: false`), `-jobs 4`, `COMPILER_INDEX_STORE_ENABLE=NO`, and signing secrets gated behind a GitHub Environment (`apple-release`) with **Required reviewers**.
4. **Weekly `ci-janitor.sh` LaunchAgent** pruning `DerivedData` (`>7d`), `Archives` (`>14d`), `xcrun simctl delete unavailable`, runner `_diag`/`_temp`, and `nix-collect-garbage --delete-older-than 14d`.
