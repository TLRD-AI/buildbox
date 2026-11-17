#!/usr/bin/env bash
# ==============================================================================
# Buildbox — Fedora Atomic Host Tuning & etckeeper Snapshot Orchestrator
# ==============================================================================
# Usage:
#   bash host/apply_host_tuning.sh --status        # Non-privileged host audit
#   bash host/apply_host_tuning.sh --user-desktop  # Link bashrc.d + Flatpak Chrome GPU flags (no sudo)
#   sudo bash host/apply_host_tuning.sh --apply    # Apply tuning + commit /etc
#   sudo bash host/apply_host_tuning.sh --rollback
#
# Secret Protection:
#   Raw `ostree admin config-diff` output contains host-specific identifiers and
#   network connection filenames. This script NEVER writes raw `/etc` diffs into
#   the public buildbox repository; it writes them to `$BUILDBOX_PRIVATE_DIR`
#   (auto-detected sibling `../buildbox-private`) or gitignored `.local/state/`.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ETC_SRC_DIR="${SCRIPT_DIR}/etc"
FLATPAK_SRC_DIR="${SCRIPT_DIR}/flatpak"
TOOLBOX_NAME="${BUILDBOX_TOOLBOX_NAME:-dev}"
WORKLOAD="${BUILDBOX_WORKLOAD:-desktop}"

TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" 2>/dev/null | cut -d: -f6 || true)"
TARGET_HOME="${TARGET_HOME:-${HOME}}"
WORKSPACE_DIR="${BUILDBOX_WORKSPACE:-${TARGET_HOME}/Documents/dev}"

# Resolve private state destination outside tracked public repo files
resolve_state_dir() {
    if [ -n "${BUILDBOX_PRIVATE_DIR:-}" ]; then
        printf '%s\n' "${BUILDBOX_PRIVATE_DIR}"
        return
    fi
    local sibling_private
    sibling_private="$(cd "${REPO_ROOT}/.." && pwd)/buildbox-private"
    if [ -d "${sibling_private}" ]; then
        local host_dir="${sibling_private}/hosts/fedora-kinoite"
        if [ -d "${host_dir}" ]; then
            printf '%s\n' "${host_dir}"
        else
            printf '%s\n' "${sibling_private}/hosts/$(hostname -s 2>/dev/null || echo localhost)"
        fi
        return
    fi
    printf '%s\n' "${REPO_ROOT}/.local/state"
}

STATE_DIR="$(resolve_state_dir)"
OSTREE_DIFF_OUT="${STATE_DIR}/ostree-etc-diff.txt"

MODE="status"
SKIP_DEFRAG=false
SKIP_TOOLBOX=false

for arg in "$@"; do
    case "$arg" in
        --status)
            MODE="status"
            ;;
        --user-desktop)
            MODE="user-desktop"
            ;;
        --apply)
            MODE="apply"
            ;;
        --rollback)
            MODE="rollback"
            ;;
        --skip-defrag)
            SKIP_DEFRAG=true
            ;;
        --skip-toolbox)
            SKIP_TOOLBOX=true
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--status | --user-desktop | --apply | --rollback] [--skip-defrag] [--skip-toolbox]

Options:
  --status         Inspect live kernel, CPU EPP, zram, Btrfs, NVIDIA, Nix, Chrome, and /etc tracking (no root needed)
  --user-desktop   Install user ~/.bashrc.d link and Flatpak Chrome Wayland/NVIDIA GPU flags (no root needed)
  --apply          Snapshot /etc via etckeeper (or git), install /etc drop-ins, tune CPU/GPU/Btrfs/user desktop, and commit /etc
  --rollback       Remove buildbox /etc drop-ins, restore balanced CPU tuning, and commit rollback to /etc
  --skip-defrag    Skip recursive Btrfs zstd defragmentation of ${WORKSPACE_DIR}
  --skip-toolbox   Skip installing optional extras inside the '${TOOLBOX_NAME}' toolbox container

Environment Overrides:
  BUILDBOX_WORKSPACE     Workspace root for Btrfs defrag & optional .toolchains (default: ~/Documents/dev)
  BUILDBOX_PRIVATE_DIR   Directory where private host snapshots (ostree-etc-diff.txt) are written
  BUILDBOX_TOOLBOX_NAME  Fedora Toolbox container name (default: dev)
  BUILDBOX_WORKLOAD      TuneD/EPP profile target: 'desktop' (default) or 'build'
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

check_dropin_status() {
    local primary="$1"
    local legacy="${2:-}"
    if [ -f "${primary}" ]; then
        echo "installed (${primary})"
    elif [ -n "${legacy}" ] && [ -f "${legacy}" ]; then
        echo "installed via legacy path (${legacy})"
    else
        echo "not installed"
    fi
}

print_status() {
    echo "================================================================"
    echo "🖥️  Buildbox — Live Host & Portability Status"
    echo "================================================================"

    echo ""
    echo "[1] Kernel Sysctl Limits & VM Parameters:"
    sysctl \
        fs.inotify.max_user_instances \
        fs.inotify.max_user_watches \
        vm.swappiness \
        vm.vfs_cache_pressure \
        vm.dirty_background_ratio \
        vm.dirty_ratio \
        kernel.sched_autogroup_enabled 2>/dev/null || true
    sysctl vm.page-cluster 2>/dev/null || true

    echo ""
    echo "[2] CPU Frequency Scaling & Tuned Profile:"
    if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        echo "  scaling_governor              : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
        echo "  scaling_driver                : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)"
        echo "  energy_performance_preference : $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo 'N/A')"
    fi
    if command -v tuned-adm &> /dev/null; then
        echo "  tuned-adm active              : $(tuned-adm active 2>/dev/null || echo 'unavailable')"
    fi

    echo ""
    echo "[3] Zram Swap Configuration:"
    if command -v zramctl &> /dev/null; then
        zramctl || true
    fi

    echo ""
    echo "[4] Btrfs Home Mount Compression:"
    findmnt --raw -no TARGET,FSTYPE,OPTIONS /var/home 2>/dev/null || findmnt --raw -no TARGET,FSTYPE,OPTIONS /home 2>/dev/null || true

    echo ""
    echo "[5] NVIDIA GPU Persistence & Driver:"
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi --query-gpu=name,persistence_mode,pstate,temperature.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null || true
    else
        echo "  nvidia-smi not found"
    fi

    echo ""
    echo "[6] /etc Version Control (etckeeper / git) & Drop-In Presence:"
    echo "  etckeeper binary              : $(command -v etckeeper || echo 'not installed on host')"
    echo "  /etc/.git present             : $([ -d /etc/.git ] && echo 'yes' || echo 'no')"
    echo "  sysctl drop-in                : $(check_dropin_status /etc/sysctl.d/99-buildbox.conf /etc/sysctl.d/99-tlrd-buildbox.conf)"
    echo "  zram drop-in                  : $(check_dropin_status /etc/systemd/zram-generator.conf.d/99-buildbox-zram.conf /etc/systemd/zram-generator.conf.d/99-tlrd.conf)"
    echo "  journald drop-in              : $(check_dropin_status /etc/systemd/journald.conf.d/99-buildbox-journal.conf)"
    echo "  coredump drop-in              : $(check_dropin_status /etc/systemd/coredump.conf.d/99-buildbox-coredump.conf)"
    echo "  udev cpu epp rule             : $(check_dropin_status /etc/udev/rules.d/99-amd-pstate-epp.rules /etc/udev/rules.d/99-tlrd-amd-pstate.rules)"
    echo "  ostree prepare-root.conf      : $([ -f /etc/ostree/prepare-root.conf ] && echo 'installed' || echo 'not installed')"
    echo "  nix-mkdir.service             : $([ -f /etc/systemd/system/nix-mkdir.service ] && echo 'installed' || echo 'not installed')"
    if [ -e "${TARGET_HOME}/.bashrc.d/99-buildbox-env.sh" ] || [ -e "${TARGET_HOME}/.bashrc.d/99-tlrd-buildbox.sh" ]; then
        echo "  bashrc.d link                 : active"
    else
        echo "  bashrc.d link                 : missing"
    fi

    echo ""
    echo "[7] Nix & /nix Mount Status:"
    if mountpoint -q /nix 2>/dev/null; then
        echo "  /nix mount                    : mounted ($(findmnt --raw -no FSTYPE,SOURCE /nix 2>/dev/null || echo 'mounted'))"
    elif [ -d /nix ]; then
        echo "  /nix mount                    : directory exists (not mounted)"
    else
        echo "  /nix mount                    : not mounted"
    fi
    if command -v nix &> /dev/null; then
        echo "  nix version                   : $(nix --version)"
    elif [ -x /nix/var/nix/profiles/default/bin/nix ]; then
        echo "  nix version                   : $(/nix/var/nix/profiles/default/bin/nix --version) (not in PATH)"
    else
        echo "  nix version                   : not installed"
    fi

    echo ""
    echo "[8] NVIDIA Container CDI Status (Podman GPU Passthrough):"
    if command -v nvidia-ctk &> /dev/null; then
        echo "  nvidia-ctk                    : $(command -v nvidia-ctk)"
    else
        echo "  nvidia-ctk                    : not on PATH (can run via nixpkgs#nvidia-container-toolkit)"
    fi
    if [ -f /etc/cdi/nvidia.yaml ]; then
        echo "  /etc/cdi/nvidia.yaml          : present"
    elif [ -f /var/run/cdi/nvidia.yaml ]; then
        echo "  /var/run/cdi/nvidia.yaml      : present"
    else
        echo "  CDI nvidia.yaml               : absent"
    fi

    if command -v ostree &> /dev/null; then
        echo ""
        echo "[9] Ostree /etc Diff Snapshot (Private Output: ${OSTREE_DIFF_OUT}):"
        if [ -r "${OSTREE_DIFF_OUT}" ]; then
            echo "  Saved snapshot lines          : $(wc -l < "${OSTREE_DIFF_OUT}")"
        else
            echo "  No saved private snapshot yet (generated on --apply with sudo)."
        fi
    fi

    echo ""
    echo "[10] Desktop, Storage & Chrome Flatpak Status:"
    if df -h /var/home >/dev/null 2>&1; then
        echo "  /var/home usage               : $(df -h --output=used,size,pcent /var/home | tail -n 1 | xargs)"
    fi
    if [ -r /proc/cmdline ]; then
        if grep -q "nvidia-drm.fbdev=0" /proc/cmdline; then
            echo "  kernel cmdline                : nvidia-drm.fbdev=0 present (may expose ghost Unknown-1 output)"
        elif grep -q "nvidia-drm.modeset=1" /proc/cmdline; then
            echo "  kernel cmdline                : nvidia-drm.modeset=1 active"
        fi
    fi
    local chrome_flags="${TARGET_HOME}/.var/app/com.google.Chrome/config/chrome-flags.conf"
    if [ -f "${chrome_flags}" ]; then
        echo "  Chrome Flatpak flags          : installed (${chrome_flags})"
    else
        echo "  Chrome Flatpak flags          : not installed"
    fi
    if command -v flatpak &> /dev/null && flatpak info com.google.Chrome >/dev/null 2>&1; then
        if flatpak override --user --show com.google.Chrome 2>/dev/null | grep -q "NVD_BACKEND=direct"; then
            echo "  Chrome NVD_BACKEND override   : direct"
        else
            echo "  Chrome NVD_BACKEND override   : unset"
        fi
    fi
}

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        echo "❌ Error: --${MODE} modifies /etc and kernel settings and must be run as root (use: sudo bash $0 --${MODE})." >&2
        exit 1
    fi
}

init_or_commit_etc() {
    local msg="$1"
    if command -v etckeeper &> /dev/null; then
        if [ ! -d /etc/.git ]; then
            etckeeper init
        fi
        etckeeper commit "$msg" || true
    elif command -v git &> /dev/null; then
        if [ ! -d /etc/.git ]; then
            git -C /etc init -q
            chmod 700 /etc/.git
            cat > /etc/.gitignore <<'GITIGNORE'
shadow
shadow-
gshadow
gshadow-
passwd-
group-
subuid-
subgid-
.pwd.lock
ssh/ssh_host_*_key
pki/*/private/*
GITIGNORE
            git -C /etc config user.name "Buildbox Etc Tracker"
            git -C /etc config user.email "buildbox@localhost"
        fi
        git -C /etc add -A
        if ! git -C /etc diff --cached --quiet; then
            git -C /etc commit -q -m "$msg"
            echo "  ✔ Committed /etc snapshot: $msg"
        else
            echo "  ℹ /etc has no uncommitted changes ($msg)"
        fi
    fi

    if command -v ostree &> /dev/null; then
        mkdir -p "${STATE_DIR}"
        ostree admin config-diff > "${OSTREE_DIFF_OUT}" 2>/dev/null || true
        if [ -n "${SUDO_USER:-}" ]; then
            chown -R "${SUDO_USER}:${SUDO_USER}" "${STATE_DIR}" 2>/dev/null || true
        fi
        echo "  ✔ Wrote private ostree diff snapshot to ${OSTREE_DIFF_OUT}"
    fi
}

apply_user_desktop_tuning() {
    echo "================================================================"
    echo "🖥️  Applying User Shell & Chrome Flatpak Desktop Tuning (${TARGET_USER})"
    echo "================================================================"

    run_as_target() {
        if [ "${EUID}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
            sudo -u "${TARGET_USER}" env HOME="${TARGET_HOME}" "$@"
        else
            "$@"
        fi
    }

    run_as_target mkdir -p "${TARGET_HOME}/.bashrc.d"
    run_as_target ln -sfn "${SCRIPT_DIR}/bashrc.d/99-buildbox-env.sh" "${TARGET_HOME}/.bashrc.d/99-buildbox-env.sh"
    echo "  ✔ Linked ${TARGET_HOME}/.bashrc.d/99-buildbox-env.sh"

    if command -v flatpak &> /dev/null && flatpak info com.google.Chrome >/dev/null 2>&1; then
        local chrome_cfg_dir="${TARGET_HOME}/.var/app/com.google.Chrome/config"
        local chrome_flags_src="${FLATPAK_SRC_DIR}/com.google.Chrome/chrome-flags.conf"
        if [ -f "${chrome_flags_src}" ]; then
            run_as_target mkdir -p "${chrome_cfg_dir}"
            run_as_target install -m 644 "${chrome_flags_src}" "${chrome_cfg_dir}/chrome-flags.conf"
            echo "  ✔ Installed ${chrome_cfg_dir}/chrome-flags.conf"
        fi
        if command -v nvidia-smi &> /dev/null; then
            run_as_target flatpak override --user --env=NVD_BACKEND=direct com.google.Chrome || true
            echo "  ✔ Set Flatpak override NVD_BACKEND=direct for com.google.Chrome"
        fi
    else
        echo "  ℹ Flatpak com.google.Chrome not installed; skipping Chrome tuning"
    fi
}

apply_tuning() {
    require_root
    echo "================================================================"
    echo "⚡ Applying Buildbox Host Tuning & /etc Snapshots (workload: ${WORKLOAD})"
    echo "================================================================"

    echo "[1/7] Recording pre-change /etc snapshot..."
    init_or_commit_etc "Pre-buildbox host tuning snapshot"

    echo "[2/7] Installing modular /etc drop-in configs..."
    install -d -m 755 \
        /etc/sysctl.d \
        /etc/systemd/zram-generator.conf.d \
        /etc/systemd/journald.conf.d \
        /etc/systemd/coredump.conf.d \
        /etc/udev/rules.d
    # Remove any legacy pre-extraction TLRD drop-ins to avoid duplicate configs
    rm -f \
        /etc/sysctl.d/99-tlrd-buildbox.conf \
        /etc/systemd/zram-generator.conf.d/99-tlrd.conf \
        /etc/udev/rules.d/99-tlrd-amd-pstate.rules
    install -m 644 "${ETC_SRC_DIR}/sysctl.d/99-buildbox.conf" /etc/sysctl.d/99-buildbox.conf
    install -m 644 "${ETC_SRC_DIR}/systemd/zram-generator.conf.d/99-buildbox-zram.conf" /etc/systemd/zram-generator.conf.d/99-buildbox-zram.conf
    install -m 644 "${ETC_SRC_DIR}/systemd/journald.conf.d/99-buildbox-journal.conf" /etc/systemd/journald.conf.d/99-buildbox-journal.conf
    install -m 644 "${ETC_SRC_DIR}/systemd/coredump.conf.d/99-buildbox-coredump.conf" /etc/systemd/coredump.conf.d/99-buildbox-coredump.conf
    install -m 644 "${ETC_SRC_DIR}/udev/rules.d/99-amd-pstate-epp.rules" /etc/udev/rules.d/99-amd-pstate-epp.rules
    sysctl --system
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=cpu || true

    echo "[3/7] Reloading systemd zram & journald limits..."
    systemctl daemon-reload
    systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl restart systemd-journald.service 2>/dev/null || true

    echo "[4/7] Activating TuneD '${WORKLOAD}' profile & AMD P-State EPP..."
    local target_epp="balance_performance"
    local target_tuned="desktop"
    if [ "${WORKLOAD}" = "build" ]; then
        target_epp="performance"
        target_tuned="throughput-performance"
        sysctl -w kernel.sched_autogroup_enabled=0 >/dev/null || true
    fi
    if command -v tuned-adm &> /dev/null; then
        tuned-adm profile "${target_tuned}" || tuned-adm profile balanced || true
    fi
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [ -w "$epp" ] && echo "${target_epp}" > "$epp" || true
    done

    echo "[5/7] Verifying Btrfs compress=zstd:1 on /var/home..."
    mount -o remount,compress=zstd:1 /var/home 2>/dev/null || mount -o remount,compress=zstd:1 /home 2>/dev/null || true
    if [ "$SKIP_DEFRAG" = false ] && command -v btrfs &> /dev/null && [ -d "${WORKSPACE_DIR}" ]; then
        echo "  Compressing ${WORKSPACE_DIR} with zstd..."
        btrfs filesystem defragment -r -czstd "${WORKSPACE_DIR}" || true
    fi

    echo "[6/7] Enabling NVIDIA persistence mode & Podman CDI (if GPU present)..."
    systemctl enable --now nvidia-persistenced 2>/dev/null || true
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi -pm 1 || true
        nvidia_ctk_bin="$(command -v nvidia-ctk || true)"
        if [ -z "${nvidia_ctk_bin}" ]; then
            nix_bin="$(command -v nix || echo /nix/var/nix/profiles/default/bin/nix)"
            if [ -x "${nix_bin}" ]; then
                if [ -n "${SUDO_USER:-}" ]; then
                    nct_out="$(sudo -u "${SUDO_USER}" "${nix_bin}" --extra-experimental-features "nix-command flakes" build --no-link --print-out-paths nixpkgs#nvidia-container-toolkit 2>/dev/null || true)"
                else
                    nct_out="$("${nix_bin}" --extra-experimental-features "nix-command flakes" build --no-link --print-out-paths nixpkgs#nvidia-container-toolkit 2>/dev/null || true)"
                fi
                if [ -n "${nct_out}" ] && [ -x "${nct_out}/bin/nvidia-ctk" ]; then
                    nvidia_ctk_bin="${nct_out}/bin/nvidia-ctk"
                fi
            fi
        fi
        if [ -n "${nvidia_ctk_bin}" ] && [ -x "${nvidia_ctk_bin}" ]; then
            install -d -m 755 /etc/cdi
            "${nvidia_ctk_bin}" cdi generate --nvidia-cdi-hook-path="${nvidia_ctk_bin}" --output=/etc/cdi/nvidia.yaml || true
        fi
    fi

    if [ "$SKIP_TOOLBOX" = false ] && [ -n "${SUDO_USER:-}" ] && command -v podman &> /dev/null; then
        echo "[7/7] Installing optional CLI extras inside '${TOOLBOX_NAME}' toolbox..."
        USER_UID="$(id -u "${SUDO_USER}")"
        sudo -u "${SUDO_USER}" env XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
            podman start "${TOOLBOX_NAME}" >/dev/null 2>&1 || true
        sudo -u "${SUDO_USER}" env XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
            podman exec --user root "${TOOLBOX_NAME}" dnf install -y btop nvtop etckeeper || true
    else
        echo "[7/7] Skipping toolbox package install (Nix flake provides project dev tools)."
    fi

    apply_user_desktop_tuning

    echo "Recording post-tuning /etc snapshot..."
    init_or_commit_etc "Apply buildbox host tuning"
    echo "✅ Host tuning applied and recorded!"
}

rollback_tuning() {
    require_root
    echo "================================================================"
    echo "↩️  Rolling Back Buildbox Host Tuning"
    echo "================================================================"
    rm -f \
        /etc/sysctl.d/99-buildbox.conf \
        /etc/systemd/zram-generator.conf.d/99-buildbox-zram.conf \
        /etc/systemd/journald.conf.d/99-buildbox-journal.conf \
        /etc/systemd/coredump.conf.d/99-buildbox-coredump.conf \
        /etc/udev/rules.d/99-amd-pstate-epp.rules \
        /etc/sysctl.d/99-tlrd-buildbox.conf \
        /etc/systemd/zram-generator.conf.d/99-tlrd.conf \
        /etc/udev/rules.d/99-tlrd-amd-pstate.rules
    sysctl --system || true
    udevadm control --reload-rules || true
    systemctl restart systemd-journald.service 2>/dev/null || true
    if command -v tuned-adm &> /dev/null; then
        tuned-adm profile balanced || true
    fi
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [ -w "$epp" ] && echo "balance_performance" > "$epp" || true
    done
    init_or_commit_etc "Rollback buildbox host tuning"
    echo "✅ Rollback complete."
}

case "$MODE" in
    status)
        print_status
        ;;
    user-desktop)
        apply_user_desktop_tuning
        ;;
    apply)
        apply_tuning
        ;;
    rollback)
        rollback_tuning
        ;;
esac
