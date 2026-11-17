#!/usr/bin/env bash
# ==============================================================================
# Buildbox — Exemplar Environment, Nix Flake, Compose & Secret Verification
# ==============================================================================
# Usage:
#   nix develop -c bash scripts/verify.sh          # Full verification suite
#   nix develop -c bash scripts/verify.sh --quick  # Skip headless Chromium check
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
QUICK_MODE=false

for arg in "$@"; do
    case "$arg" in
        --quick)
            QUICK_MODE=true
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--quick]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

cd "${REPO_ROOT}"

echo "================================================================"
echo "🔍 Buildbox Verification Pipeline"
echo "================================================================"

echo ""
echo "[1/5] Secret & Host-Artifact Guardrail Audit..."
bash "${REPO_ROOT}/scripts/check_secrets.sh" --all

echo ""
echo "[2/5] Shell Script Syntax & ShellCheck Validation..."
SHELL_FILES=(
    ".devcontainer/init-host.sh"
    ".devcontainer/post-create.sh"
    "host/apply_host_tuning.sh"
    "host/bashrc.d/99-buildbox-env.sh"
    "scripts/check_secrets.sh"
    "scripts/verify.sh"
    "scripts/git-hooks/pre-commit"
)
for sh_file in "${SHELL_FILES[@]}"; do
    bash -n "${sh_file}"
done
echo "  ✔ bash -n passed on all ${#SHELL_FILES[@]} shell files"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "${SHELL_FILES[@]}"
    echo "  ✔ shellcheck passed (0 warnings)"
else
    echo "  ℹ shellcheck not found on PATH; skipping lint pass"
fi

echo ""
echo "[3/5] Nix DevShell Toolchain & Native Library Verification..."
MISSING_TOOLS=0
for tool in python3 uv node npm flutter dart brotli gzip rg fd wasm-opt jq docker; do
    if command -v "${tool}" >/dev/null 2>&1; then
        printf "  ✔ %-12s -> %s\n" "${tool}" "$(command -v "${tool}")"
    else
        printf "  ⚠ %-12s -> not on PATH (run inside 'nix develop')\n" "${tool}"
        MISSING_TOOLS=$((MISSING_TOOLS + 1))
    fi
done

if [ -n "${IN_NIX_SHELL:-}" ] || [[ "$(command -v python3 2>/dev/null || true)" == /nix/store/* ]]; then
    python3 -c '
import ctypes.util, os, sys
jit = os.environ.get("PYTHON_JIT", "unset")
print(f"  ✔ Python {sys.version.split()[0]} (PYTHON_JIT={jit})")
# Verify native C library discovery for WeasyPrint / psycopg / Pillow
for lib in ("pango-1.0", "cairo", "pq", "ssl"):
    resolved = ctypes.util.find_library(lib)
    if not resolved:
        raise SystemExit(f"Missing native library in loader path: {lib}")
print("  ✔ Native shared libraries resolved (pango-1.0, cairo, pq, ssl)")
'
else
    echo "  ℹ Outside nix develop; skipping Nix Python & native C library loader check"
fi

echo ""
echo "[4/5] Devcontainer Compose Configuration Validation..."
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose -f "${REPO_ROOT}/.devcontainer/docker-compose.devcontainer.yml" config -q
    echo "  ✔ .devcontainer/docker-compose.devcontainer.yml is valid"
else
    echo "  ℹ docker compose not available; skipping Compose config check"
fi

echo ""
echo "[5/5] Linux Chromium / WebGL (GPU or SwiftShader) Smoke Check..."
if [ "${QUICK_MODE}" = true ]; then
    echo "  ℹ Skipped in --quick mode"
elif [ "$(uname -s)" = "Linux" ] && [ -n "${CHROME_BIN:-}" ] && [ -x "${CHROME_BIN}" ]; then
    dom_out="$("${CHROME_BIN}" --headless=new --no-sandbox --disable-setuid-sandbox --enable-webgl --ignore-gpu-blocklist --use-gl=angle --use-angle=gl --dump-dom about:blank 2>/dev/null || true)"
    if printf '%s\n' "${dom_out}" | grep -q "<html>"; then
        echo "  ✔ Headless Chromium launched and rendered DOM cleanly (${CHROME_BIN})"
    else
        echo "  ❌ Headless Chromium smoke check failed (${CHROME_BIN})" >&2
        exit 1
    fi
else
    echo "  ℹ Skipping Linux CHROME_BIN smoke check on $(uname -s)"
fi

echo ""
echo "================================================================"
echo "✅ Buildbox Verification Complete!"
echo "================================================================"
