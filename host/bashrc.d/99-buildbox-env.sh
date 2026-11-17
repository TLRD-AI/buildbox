# shellcheck shell=bash
# ==============================================================================
# Buildbox — Interactive Shell Environment (`~/.bashrc.d/99-buildbox-env.sh`)
# ==============================================================================
# Sourced by Fedora interactive bash sessions via `~/.bashrc.d/*.sh`.
# Non-interactive scripts and CI should prefer `nix develop -c ...` or `direnv`.
# ==============================================================================

# Prefer user-local binaries and optional relocated toolchains if present
export BUILDBOX_WORKSPACE="${BUILDBOX_WORKSPACE:-${HOME}/Documents/dev}"
if [ -d "${BUILDBOX_WORKSPACE}/.toolchains/flutter/bin" ] && [[ ":${PATH}:" != *":${BUILDBOX_WORKSPACE}/.toolchains/flutter/bin:"* ]]; then
    export PATH="${BUILDBOX_WORKSPACE}/.toolchains/flutter/bin:${PATH}"
fi
if [ -d "${BUILDBOX_WORKSPACE}/.toolchains/bin" ] && [[ ":${PATH}:" != *":${BUILDBOX_WORKSPACE}/.toolchains/bin:"* ]]; then
    export PATH="${BUILDBOX_WORKSPACE}/.toolchains/bin:${PATH}"
fi
if [ -d "${HOME}/.local/bin" ] && [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
    export PATH="${HOME}/.local/bin:${PATH}"
fi

export PUB_CACHE="${PUB_CACHE:-${HOME}/.cache/pub-cache}"
export PYTHON_JIT="${PYTHON_JIT:-1}"
if [ -z "${DJANGO_TEST_PARALLEL:-}" ]; then
    DJANGO_TEST_PARALLEL="$(nproc 2>/dev/null || echo 8)"
    export DJANGO_TEST_PARALLEL
fi

# Route Docker-compatible CLI tools to rootless Podman when socket is active
_buildbox_uid="$(id -u)"
if [ -z "${DOCKER_HOST:-}" ] && [ -S "/run/user/${_buildbox_uid}/podman/podman.sock" ]; then
    export DOCKER_HOST="unix:///run/user/${_buildbox_uid}/podman/podman.sock"
fi
unset _buildbox_uid
