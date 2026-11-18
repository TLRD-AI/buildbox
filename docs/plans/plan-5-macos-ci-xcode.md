# Plan 5: Harden an 8 GB / 256 GB Apple M1 Mac mini as an Isolated Xcode & Multi-Repo CI Node

**Goal:** Turn an **8 GB / 256 GB Apple M1 Mac mini** (`arm64` / `aarch64-darwin`, 4P + 4E cores) into a hardened, hybrid workstation + self-hosted Apple/Xcode CI node dedicated strictly to building and testing Apple targets (**iOS → Safari → macOS**, never Linux/backend/Docker test suites)—using per-repo GitHub Actions self-hosted runners (restricted defensively as if every repo were public), Tailscale SSH for ad-hoc builds, an isolated non-admin `ci` user with its own `ci.keychain-db`, pinned `Xcode.app` + minimal iOS Simulator footprint, and clean Nix-vs-Xcode toolchain isolation.

**Prerequisites:** Plan 4 Phases 0–2 completed (Determinate Nix `aarch64-darwin` + `direnv`/`nix-direnv` installed; Linux container VMs omitted/reclaimed on a 256 GB SSD).

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
1. Under a **GitHub Organization**, you can share org-level runners; under a personal account, register per-repo runner directories (`~/runners/<repo>`) while `/Users/Shared/ci-lock/xcode.lock` serializes builds across all repos.
2. **Public-Repo Defense:** Self-hosted workflows **never** listen to `pull_request` or `pull_request_target`, `ci` has zero `sudo` access and cannot read `/Users/$ADMIN_USER`, `ci` is **not** in Nix `trusted-users`, and signing credentials live behind a **GitHub Environment (`apple-release`) with Required Reviewers**.

---

## 3. Phase 0 — Pre-Flight Audit & Plan 4 Container Reclaim

Run read-only checks first as `$ADMIN_USER`:

```zsh
uname -m
sysctl -n hw.memsize hw.ncpu hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu
df -h /
diskutil apfs list
tmutil listlocalsnapshots /
sw_vers
xcode-select -p 2>/dev/null || echo "NO_XCODE_SELECT"
ls -d /Applications/Xcode*.app 2>/dev/null || echo "NO_XCODE_APP"
xcrun simctl list runtimes 2>/dev/null || true
pmset -g
fdesetup status
which -a nix direnv brew tailscale orb colima docker podman fastlane pod xcodes aria2
```

If Plan 4 container runtimes were tried on the 256 GB SSD, reclaim space before `.xip` extraction (which temporarily needs ~35–40 GB free):

```zsh
orb delete -f 2>/dev/null || true
colima delete -f 2>/dev/null || true
nix store gc
df -h /   # Target >= 60-80 GB free before installing Xcode
```

---

## 4. Phase 1 — Host Hardening, Power, FileVault & Tailscale SSH

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
  brew uninstall --cask tailscale-app 2>/dev/null || true
  brew install tailscale
  sudo brew services start tailscale
  sudo tailscale up --ssh --hostname=<mac-ci-host>
  tailscale status
  ```
  Restrict SSH access in Tailscale ACLs so only your admin workstation can connect to `ci@<mac-ci-host>`.
- **FileVault Tradeoff:**
  - *FileVault ON + UPS:* Use `sudo fdesetup authrestart` for planned remote reboots; accept manual unlock if AC power fails beyond UPS runtime.
  - *FileVault OFF + encrypted CI secret vault:* Only if physically secure at home and 100% unattended power recovery (`autorestart 1`) is required.

---

## 5. Phase 2 — Dedicated Non-Admin `ci` User & `ci.keychain-db`

```zsh
# Create standard (non-admin) user `ci`
sudo sysadminctl -addUser ci \
  -fullName "MacMini CI Runner" \
  -home /Users/ci \
  -shell /bin/zsh \
  -password -

id ci
groups ci | grep -vw admin && echo "NON_ADMIN_OK"

chmod 700 "/Users/$ADMIN_USER"
sudo chmod 700 /Users/ci

sudo mkdir -p /Users/Shared/ci-lock /Users/Shared/ci-tools
sudo chown "$ADMIN_USER:staff" /Users/Shared/ci-tools
sudo chmod 1777 /Users/Shared/ci-lock
sudo chmod 755 /Users/Shared/ci-tools
```

Inside `ci`'s GUI/SSH session (log into `ci` once via Fast User Switching so Aqua/Keychain initialize cleanly):

```zsh
# 1. Disable App Nap and prevent Spotlight from indexing CI builds
defaults write NSGlobalDomain NSAppSleepDisabled -bool YES
mkdir -p ~/runners ~/builds ~/Library/Developer/Xcode/DerivedData ~/.cache ~/.secrets ~/.appstoreconnect/private_keys
chmod 700 ~/.secrets ~/.appstoreconnect ~/.appstoreconnect/private_keys
touch ~/runners/.metadata_never_index ~/builds/.metadata_never_index \
      ~/Library/Developer/Xcode/DerivedData/.metadata_never_index ~/.cache/.metadata_never_index

# 2. Install direnv/gh/jq via multi-user Nix (do NOT add `ci` to Nix trusted-users)
. '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
nix profile add nixpkgs#direnv nixpkgs#nix-direnv nixpkgs#gh nixpkgs#jq

mkdir -p ~/.config/direnv
cat <<'EOF' > ~/.config/direnv/direnvrc
if [ -f "$HOME/.nix-profile/share/nix-direnv/direnvrc" ]; then
  source "$HOME/.nix-profile/share/nix-direnv/direnvrc"
elif [ -f "/nix/var/nix/profiles/default/share/nix-direnv/direnvrc" ]; then
  source "/nix/var/nix/profiles/default/share/nix-direnv/direnvrc"
fi
EOF

# 3. Clean ~/.zshenv and ~/.zshrc (never set FLUTTER_ROOT here)
cat <<'EOF' > ~/.zshenv
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export CI_BUILD_LOCK_FILE="/Users/Shared/ci-lock/xcode.lock"
export PATH="$HOME/bin:/Users/Shared/ci-tools:/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
EOF

cat <<'EOF' > ~/.zshrc
eval "$(direnv hook zsh)"
EOF

# 4. Create isolated CI keychain (keep empty for unsigned PR/main CI; use ephemeral
#    per-job keychains under $RUNNER_TEMP deleted via `if: always()` for releases)
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

## 6. Phase 3 — Pinned Xcode & Minimal Simulator Runtime

Run as `$ADMIN_USER`:

```zsh
brew install aria2 fastlane cocoapods create-dmg
brew install xcodesorg/made/xcodes

xcodes list | tail -n 20
xcodes install <XCODE_VERSION> --experimental-unxip
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch

# Install only the arm64 iOS Simulator runtime; prune unused ones
sudo xcodebuild -downloadPlatform iOS -architectureVariant arm64
xcrun simctl runtime list
xcrun simctl delete unavailable
```

As `ci`, configure headless Xcode defaults and 8 GB concurrency limits (including both spellings of Apple's historical SPM plugin validation key):

```zsh
defaults write com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks 4
defaults write com.apple.dt.Xcode ShowBuildOperationDuration -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES
```

---

## 7. Phase 4 — Nix vs. Xcode Toolchain Isolation & 8 GB Build Lock

Because `flake.nix` uses `pkgs.mkShellNoCC` on Darwin and unsets `DEVELOPER_DIR` / `SDKROOT`, host Xcode works alongside Nix tools. Install these two wrappers into `/Users/Shared/ci-tools/` **as `$ADMIN_USER`** (`chmod 0755`) so `ci` cannot alter them and interactive `$ADMIN_USER` builds share the same mutex:

1. **`/Users/Shared/ci-tools/ci-build-lock`** (Python `fcntl.flock` mutex, since stock macOS lacks Linux `flock`):
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   LOCK_FILE="${CI_BUILD_LOCK_FILE:-/Users/Shared/ci-lock/xcode.lock}"
   mkdir -p "$(dirname "$LOCK_FILE")"
   [ "$#" -gt 0 ] || { echo "Usage: ci-build-lock <command> [args...]" >&2; exit 2; }
   exec /usr/bin/python3 - "$LOCK_FILE" "$@" <<'PY'
   import fcntl, os, subprocess, sys, time
   lock_path, cmd = sys.argv[1], sys.argv[2:]
   fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o666)
   try: os.chmod(lock_path, 0o666)
   except PermissionError: pass
   try:
       fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
   except BlockingIOError:
       print(f"[ci-build-lock] Waiting for active build lock ({lock_path})...", file=sys.stderr, flush=True)
       t0 = time.monotonic()
       fcntl.flock(fd, fcntl.LOCK_EX)
       print(f"[ci-build-lock] Lock acquired after {time.monotonic() - t0:.1f}s.", file=sys.stderr, flush=True)
   os.ftruncate(fd, 0)
   os.write(fd, f"pid={os.getpid()} user={os.environ.get('USER','?')} cmd={' '.join(cmd[:4])}\n".encode())
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

## 8. Phase 5 — Self-Hosted Runners, Hybrid Control & Defensive CI Design

### 8.1 Register Per-Repo `LaunchAgent` Runners (`ci`)
Install each repository into its own directory under `~/runners/<repo>` so `./svc.sh` creates distinct `LaunchAgent` plists running inside `ci`'s Aqua GUI session:

```zsh
# --- Run inside `ci`'s GUI / SSH session ---
mkdir -p ~/runners ~/builds/cache
cd ~/runners
RUNNER_VER="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name | ltrimstr("v")')"
curl -fL -o "actions-runner-osx-arm64-${RUNNER_VER}.tar.gz" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VER}/actions-runner-osx-arm64-${RUNNER_VER}.tar.gz"

# Repeat per repository (e.g., <repo-a>, <repo-b>)
for repo in <repo-a> <repo-b>; do
  mkdir -p "$HOME/runners/$repo"
  tar xzf "actions-runner-osx-arm64-${RUNNER_VER}.tar.gz" -C "$HOME/runners/$repo"
  cd "$HOME/runners/$repo"
  ./config.sh \
    --url "https://github.com/<org>/$repo" \
    --token "<REG_TOKEN_FOR_$repo>" \
    --name "macmini-m1-$repo" \
    --labels "self-hosted,macOS,ARM64,xcode,m1-8gb" \
    --work "_work" \
    --replace
  ./svc.sh install
  ./svc.sh start

  # Ensure LaunchAgent sees /Users/Shared/ci-tools, Homebrew, and Nix paths
  env_file="$HOME/runners/$repo/.env"
  [ -f "$env_file" ] && grep -vE '^(PATH|LANG|LC_ALL|CI_BUILD_LOCK_FILE)=' "$env_file" > "$env_file.tmp" || : > "$env_file.tmp"
  cat <<'EOF' >> "$env_file.tmp"
PATH=/Users/ci/bin:/Users/Shared/ci-tools:/opt/homebrew/bin:/opt/homebrew/sbin:/Users/ci/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
CI_BUILD_LOCK_FILE=/Users/Shared/ci-lock/xcode.lock
EOF
  mv "$env_file.tmp" "$env_file"
  ./svc.sh stop && ./svc.sh start
done

rm -f ~/runners/"actions-runner-osx-arm64-${RUNNER_VER}.tar.gz"
```

### 8.2 Hybrid Pause / Resume Helper (`/Users/ci/bin/ci-ctl`)
```zsh
cat <<'EOF' > /Users/ci/bin/ci-ctl
#!/usr/bin/env zsh
set -euo pipefail
action="${1:-status}"
for r in "$HOME"/runners/*(N/); do
  [ -x "$r/svc.sh" ] || continue
  echo "=== $(basename "$r") ==="
  (cd "$r" && ./svc.sh "$action") || true
done
EOF
chmod +x /Users/ci/bin/ci-ctl
```

### 8.3 Generic Defensive `xcode-ci.yml` & Release Signing Pattern
- **Never** trigger `self-hosted` jobs on `pull_request` or `pull_request_target`; restrict to `push` (`main` / `v*`) and `workflow_dispatch`.
- In repository Settings -> Actions -> General -> Fork pull request workflows, require approval for outside collaborators.
- Gate signing/notarization secrets (`CERTIFICATE_P12`, `CERTIFICATE_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `MATCH_PASSWORD`, `MATCH_GIT_URL`) inside GitHub Environment **`apple-release`** with **Required reviewers**:
  - **Direct macOS distribution:** Use ephemeral `$RUNNER_TEMP/build.keychain-db` (`set-keychain-settings`, `unlock-keychain`, `security import ... -T /usr/bin/codesign -T /usr/bin/xcodebuild`, `security set-key-partition-list -S apple-tool:,apple:,codesign:`), `xcodebuild archive` + `-exportArchive`, `xcrun notarytool submit ... --wait`, `xcrun stapler staple`, and delete temp keychain/`.p8` in `if: always()`.
  - **App Store / TestFlight distribution:** Use Fastlane `setup_ci(force: true)` + `app_store_connect_api_key(...)` + `match(readonly: true, ...)` + `build_app` + `upload_to_testflight`, cleaning temporary keychains/profiles in `ensure` / `if: always()`.

```yaml
name: Apple & Xcode CI

on:
  push:
    branches: [main]
    tags: ["v*"]
  workflow_dispatch:

concurrency:
  group: xcode-ci-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  build-unsigned:
    if: ${{ github.event_name != 'pull_request' && github.event_name != 'pull_request_target' }}
    runs-on: [self-hosted, macOS, ARM64, xcode, m1-8gb]
    steps:
      - uses: actions/checkout@v4
        with:
          clean: true
          persist-credentials: false
      - name: Build iOS target (unsigned Simulator validation)
        run: |
          ci-xcode-exec xcodebuild build \
            -scheme "<IOS_SCHEME>" \
            -destination "generic/platform=iOS Simulator" \
            -derivedDataPath "$RUNNER_TEMP/DerivedData" \
            -jobs 4 -skipMacroValidation -skipPackagePluginValidation \
            COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""
      - name: Build Safari / macOS target (unsigned)
        run: |
          ci-xcode-exec xcodebuild build \
            -scheme "<MACOS_OR_SAFARI_SCHEME>" \
            -destination "platform=macOS,arch=arm64" \
            -derivedDataPath "$RUNNER_TEMP/DerivedData" \
            -jobs 4 -skipMacroValidation -skipPackagePluginValidation \
            COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""

  release:
    needs: build-unsigned
    if: ${{ startsWith(github.ref, 'refs/tags/v') }}
    environment: apple-release
    runs-on: [self-hosted, macOS, ARM64, xcode, m1-8gb]
    steps:
      - uses: actions/checkout@v4
        with:
          clean: true
          persist-credentials: false
      - name: Signed archive & notarize / upload
        run: ci-xcode-exec bundle exec fastlane release
```

---

## 9. Phase 6 — Automated 256 GB Disk Hygiene (`ci-janitor.sh`)

Schedule weekly cleanup under `ci` (`~/Library/LaunchAgents/local.ci.janitor.plist`):

```zsh
cat <<'EOF' > /Users/ci/bin/ci-janitor.sh
#!/usr/bin/env zsh
set -euo pipefail
echo "[ci-janitor] Starting cleanup at $(date -Iseconds)"
df -h /

find "$HOME/Library/Developer/Xcode/DerivedData" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
find "$HOME/Library/Developer/Xcode/Archives" -mindepth 1 -maxdepth 2 -mtime +14 -exec rm -rf {} + 2>/dev/null || true
find "$HOME/Library/Developer/Xcode/iOS DeviceSupport" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + 2>/dev/null || true

xcrun simctl delete unavailable 2>/dev/null || true
rm -rf "$HOME/Library/Developer/CoreSimulator/Caches/"* 2>/dev/null || true
rm -rf "$HOME/Library/Caches/CocoaPods/"* 2>/dev/null || true
find "$HOME/runners" -path "*/_diag/*" -mtime +7 -delete 2>/dev/null || true
find "$HOME/runners" -path "*/_work/_temp/*" -mtime +2 -delete 2>/dev/null || true
find "$HOME/builds" -mindepth 1 -maxdepth 1 -mtime +14 -exec rm -rf {} + 2>/dev/null || true

. '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
nix-collect-garbage --delete-older-than 14d || true
df -h /
EOF
chmod +x /Users/ci/bin/ci-janitor.sh

cat <<'EOF' > ~/Library/LaunchAgents/local.ci.janitor.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.ci.janitor</string>
  <key>ProgramArguments</key><array><string>/Users/ci/bin/ci-janitor.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>4</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>/Users/ci/Library/Logs/ci-janitor.log</string>
  <key>StandardErrorPath</key><string>/Users/ci/Library/Logs/ci-janitor.err.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.ci.janitor.plist
```

---

## 10. Troubleshooting & Done Criteria

| Symptom / Error | Root Cause | Fix |
| :--- | :--- | :--- |
| `The Tailscale SSH server does not run in sandboxed Tailscale GUI builds` | Installed Mac App Store or GUI `Tailscale.app` | Uninstall GUI cask/app, `brew install tailscale`, `sudo brew services start tailscale`, `sudo tailscale up --ssh` |
| `Connection closed by <lan-ip> port 22` on macOS `sshd` for `ci` | Standard non-admin user missing from macOS Remote Login ACL (`com.apple.access_ssh`) | Use Tailscale SSH (`ssh ci@<mac-ci-host>`), or on LAN run `sudo dseditgroup -o edit -a ci -t user com.apple.access_ssh` |
| `xcodebuild` fails on wrong `SDKROOT` or unknown Clang flag | Run directly inside Nix `mkShell` | Use `pkgs.mkShellNoCC` on Darwin and wrap Xcode calls with `ci-xcode-exec` |
| `codesign` hangs or throws `errSecInternalComponent` | Missing `set-key-partition-list`, locked keychain, or `LaunchDaemon` instead of `Aqua` `LaunchAgent` | Run runner via `./svc.sh` inside `ci`'s Aqua GUI session and run `security set-key-partition-list -S apple-tool:,apple:,codesign:` |
| `CoreSimulatorService` connection error | Runner executing outside an Aqua GUI login session | Keep `ci` logged into an Aqua session (auto-login or Fast User Switching) |
| Build killed with `exit 137` on 8 GB M1 | Concurrent builds or too many compile threads | Route all builds through `ci-xcode-exec` (`ci-build-lock`) + `-jobs 4` + `COMPILER_INDEX_STORE_ENABLE=NO`; use `ci-ctl stop` during heavy interactive work |
| `command not found` in runner jobs | `launchd` does not source `~/.zshrc` | Set full `PATH` in `~/runners/<repo>/.env` and restart `./svc.sh` |

### Done When
- [ ] `df -h /` has **>= 30–40 GB free** with pinned `Xcode.app` + 1 arm64 iOS Simulator runtime installed.
- [ ] `pmset -g` shows `sleep 0`, `autorestart 1`, `womp 1`; `ssh ci@<mac-ci-host>` works over Tailscale.
- [ ] `ci` is non-admin, excluded from Nix `trusted-users`, has an active Aqua session + `ci.keychain-db`, and `ci-build-lock` serializes concurrent invocations.
- [ ] Registered `LaunchAgent` runners show **Idle / Online** in GitHub Actions, **zero** `self-hosted` workflows trigger on `pull_request` / `pull_request_target`, and signing secrets sit behind `apple-release` Required Reviewers.
