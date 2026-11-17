#!/usr/bin/env bash
# ==============================================================================
# Buildbox — Secret & Sensitive Host Artifact Guardrail Scanner
# ==============================================================================
# Usage:
#   bash scripts/check_secrets.sh --staged   # Pre-commit hook mode
#   bash scripts/check_secrets.sh --all      # Full repository audit (CI / verify)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE="${1:---all}"
MAX_FILE_BYTES="${MAX_FILE_BYTES:-5242880}"

RED=$'\033[31m'
RST=$'\033[0m'
blocked=0

block() {
    echo "${RED}✖ SECRET/SAFETY BLOCK:${RST} $1" >&2
    blocked=1
}

# Build target file list
cd "${REPO_ROOT}"
if [ "${MODE}" = "--staged" ]; then
    files="$(git diff --cached --name-only --diff-filter=ACMR)"
elif [ "${MODE}" = "--all" ]; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        files="$(git ls-files)"
    else
        files="$(find . -maxdepth 5 -type f \
            ! -path './.git/*' \
            ! -path './.direnv/*' \
            ! -path './.local/*' \
            ! -path './local/*' \
            ! -path './private/*' \
            ! -path './.venv/*' \
            ! -path './node_modules/*' \
            | sed 's|^\./||' | sort)"
    fi
else
    echo "Usage: $(basename "$0") [--staged | --all]" >&2
    exit 2
fi

[ -z "${files}" ] && exit 0

# 1. Forbidden file paths (secrets, raw host diffs, keys, caches)
forbidden_path_re='(^|/)\.env(\..*)?$|(^|/)docker-compose\.local\.yml$|\.(pem|key|p12|pfx|priv|nmconnection)$|(^|/)id_(rsa|ed25519|ecdsa)(\.pub)?$|(^|/)(ostree-etc-diff|pre-nix-status|host-status)\.txt$|\.sqlite3?(-journal)?$|(^|/)node_modules/|(^|/)\.venv/'

while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
        .env.example|*/.env.example|host/ostree-etc-diff.example.txt) continue ;;
    esac
    if [[ "$f" =~ $forbidden_path_re ]]; then
        block "forbidden path in public repo: $f"
    fi
done <<< "${files}"

# 2. Oversized file guard (> 5 MB)
while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ "${MODE}" = "--staged" ]; then
        size="$(git cat-file -s ":$f" 2>/dev/null || echo 0)"
    else
        size="$(stat -c "%s" "$f" 2>/dev/null || stat -f "%z" "$f" 2>/dev/null || echo 0)"
    fi
    if [ "${size}" -gt "${MAX_FILE_BYTES}" ]; then
        block "$f is $((size / 1024)) KB (limit $((MAX_FILE_BYTES / 1024)) KB)."
    fi
done <<< "${files}"

# 3. Secret & host-private pattern scan (skipping scanner definitions themselves)
secret_re='(gh[pou]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|(sk_live_|rk_live_)[A-Za-z0-9]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|^[ADM][[:space:]]+(NetworkManager/system-connections/|pki/akmods/private/|nvme/hostnqn|machine-id|shadow))'
assigned_secret_re='(API_KEY|SECRET_KEY|ACCESS_TOKEN|PRIVATE_KEY|PASSWORD)[A-Z_]*[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_./+=-]{24,}'

scan_lines() {
    local input="$1"
    local hits=""
    hits="$(printf '%s\n' "${input}" | grep -E "${secret_re}" || true)"
    if [ -n "${hits}" ]; then
        block "sensitive literal or host-private artifact detected:"
        printf '%s\n' "${hits}" | head -n 5 >&2
    fi

    local assigned_hits=""
    assigned_hits="$(printf '%s\n' "${input}" | grep -E "${assigned_secret_re}" | grep -viE 'example|placeholder|changeme|local-dev-only|your[_-]?key|dummy|fake|test|os\.environ|getenv' || true)"
    if [ -n "${assigned_hits}" ]; then
        block "possible hardcoded secret assignment detected (value redacted):"
        printf '%s\n' "${assigned_hits}" | head -n 5 | sed -E 's/([:=][[:space:]]*["'"'"']?[A-Za-z0-9_.\/+=-]{4})[A-Za-z0-9_.\/+=-]*/\1...[redacted]/' >&2
    fi
}

if [ "${MODE}" = "--staged" ]; then
    added="$(git diff --cached -U0 --diff-filter=ACMR -- . ':(exclude).env.example' ':(exclude)scripts/check_secrets.sh' ':(exclude)scripts/git-hooks/pre-commit' | grep -E '^\+[^+]' || true)"
    [ -n "${added}" ] && scan_lines "${added}"
else
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$f" in
            .env.example|scripts/check_secrets.sh|scripts/git-hooks/pre-commit|flake.lock) continue ;;
        esac
        [ -r "$f" ] || continue
        if grep -Iq . "$f" 2>/dev/null; then
            file_hits="$(grep -nH -E "${secret_re}" "$f" || true)"
            if [ -n "${file_hits}" ]; then
                block "sensitive pattern in tracked file $f:"
                printf '%s\n' "${file_hits}" | head -n 5 >&2
            fi
            assigned_file_hits="$(grep -nH -E "${assigned_secret_re}" "$f" | grep -viE 'example|placeholder|changeme|local-dev-only|your[_-]?key|dummy|fake|test|os\.environ|getenv' || true)"
            if [ -n "${assigned_file_hits}" ]; then
                block "possible hardcoded secret assignment in $f:"
                printf '%s\n' "${assigned_file_hits}" | head -n 5 | sed -E 's/([:=][[:space:]]*["'"'"']?[A-Za-z0-9_.\/+=-]{4})[A-Za-z0-9_.\/+=-]*/\1...[redacted]/' >&2
            fi
        fi
    done <<< "${files}"
fi

if [ "${blocked}" -ne 0 ]; then
    echo "" >&2
    echo "Guardrail check failed. Move host-specific snapshots or secrets to ../buildbox-private or gitignored .env." >&2
    exit 1
fi

echo "✔ Secret & safety guardrail passed (${MODE})."
