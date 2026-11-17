#!/usr/bin/env bash
# ==============================================================================
# Buildbox — Devcontainer Post-Create Bootstrap (`postCreateCommand`)
# ==============================================================================
# Runs inside the `dev` container as `appuser` after creation:
#   1. Ensures named cache volume mountpoints are writable by appuser.
#   2. Marks `/workspace` as git safe.directory and installs secret-guard hooks.
#   3. Materializes the flake devShell profile & `/nix/var/nix/profiles/buildbox-dev-env.sh`
#      so non-interactive `devcontainer exec` invocations get the full Nix toolchain.
#   4. Runs `direnv allow` for interactive terminals.
# ==============================================================================
set -euo pipefail

export HOME="${HOME:-/home/appuser}"
if [ -r "${HOME}/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "${HOME}/.nix-profile/etc/profile.d/nix.sh"
elif [ -r "/nix/var/nix/profiles/per-user/$(id -un)/profile/etc/profile.d/nix.sh" ]; then
    ln -sfn "/nix/var/nix/profiles/per-user/$(id -un)/profile" "${HOME}/.nix-profile"
    . "${HOME}/.nix-profile/etc/profile.d/nix.sh"
fi

# Ensure named-volume mountpoints are writable by appuser (1000:1000)
for dir in \
    /home/appuser/.cache/pub-cache \
    /home/appuser/.cache/uv; do
    mkdir -p "$dir" 2>/dev/null || true
    if [ ! -w "$dir" ]; then
        sudo chown -R "$(id -u):$(id -g)" "$dir"
    fi
done

git config --global --add safe.directory /workspace

if [ -e /workspace/.git ] && [ -d /workspace/scripts/git-hooks ]; then
    git -C /workspace config --local core.hooksPath scripts/git-hooks || true
fi

echo "[devcontainer post-create] Populating Nix devShell from /workspace/flake.nix..."
nix develop /workspace --profile /nix/var/nix/profiles/buildbox-dev --command bash -c '
    for var in PATH LD_LIBRARY_PATH CHROME_BIN PYTHON_JIT PUPPETEER_SKIP_DOWNLOAD PUB_CACHE DJANGO_TEST_PARALLEL; do
        if [ -n "${!var:-}" ]; then
            printf "export %s=%q\n" "$var" "${!var}"
        fi
    done
' > /nix/var/nix/profiles/buildbox-dev-env.sh

if command -v direnv >/dev/null 2>&1 && [ -f /workspace/.envrc ]; then
    (cd /workspace && direnv allow) || true
fi

echo "[devcontainer post-create] Verifying flake toolchain inside container..."
nix develop /workspace -c bash /workspace/scripts/verify.sh --quick

echo "[devcontainer post-create] Devcontainer bootstrap complete."
