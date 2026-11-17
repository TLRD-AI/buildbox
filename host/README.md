# Host OS Layer (Fedora Atomic / Kinoite + `/etc/.git` Auditing)

This directory contains modular host-level configurations and the idempotent orchestrator [`apply_host_tuning.sh`](apply_host_tuning.sh) for turning a **Fedora Atomic / Kinoite (`rpm-ostree`)** workstation (or comparable Linux host) into a fast, reproducible, non-snowflake build box without `rpm-ostree` package layering.

---

## Tracked Host Templates (`host/etc/` & `host/bashrc.d/`)

| Repo Path | Host Destination | Purpose |
| :--- | :--- | :--- |
| [`etc/sysctl.d/99-buildbox.conf`](etc/sysctl.d/99-buildbox.conf) | `/etc/sysctl.d/99-buildbox.conf` | Bumps `inotify` limits for IDE/hot-reload/multi-agent swarms, tunes `vm.swappiness=100` + `page-cluster=0` for `zstd` zram, tunes dirty page writeback, and keeps `sched_autogroup_enabled=1` for responsive interactive desktop/browser scheduling |
| [`etc/systemd/zram-generator.conf.d/99-buildbox-zram.conf`](etc/systemd/zram-generator.conf.d/99-buildbox-zram.conf) | `/etc/systemd/zram-generator.conf.d/99-buildbox-zram.conf` | Configures `/dev/zram0` up to 16 GiB (`min(ram / 2, 16384)`) with `zstd` compression |
| [`etc/systemd/journald.conf.d/99-buildbox-journal.conf`](etc/systemd/journald.conf.d/99-buildbox-journal.conf) | `/etc/systemd/journald.conf.d/99-buildbox-journal.conf` | Caps persistent journald disk usage at `250M` on compact Btrfs root partitions |
| [`etc/systemd/coredump.conf.d/99-buildbox-coredump.conf`](etc/systemd/coredump.conf.d/99-buildbox-coredump.conf) | `/etc/systemd/coredump.conf.d/99-buildbox-coredump.conf` | Caps systemd coredump retention at `256M` so crash dumps cannot fill `/var` |
| [`etc/udev/rules.d/99-amd-pstate-epp.rules`](etc/udev/rules.d/99-amd-pstate-epp.rules) | `/etc/udev/rules.d/99-amd-pstate-epp.rules` | Sets `energy_performance_preference="balance_performance"` for `amd-pstate-epp` CPUs so idle cores cool down while preserving full single-core boost (ignored harmlessly on non-AMD CPUs) |
| [`etc/ostree/prepare-root.conf`](etc/ostree/prepare-root.conf) | `/etc/ostree/prepare-root.conf` | Enables `root.transient = true` alongside `composefs` so `/nix` can be created cleanly at boot on Fedora 41+ / 45 Atomic |
| [`etc/systemd/system/nix-mkdir.service`](etc/systemd/system/nix-mkdir.service) | `/etc/systemd/system/nix-mkdir.service` | Creates `/nix` on transient root before `nix-directory.service` and `nix.mount`, avoiding `chattr -i /` errors under `composefs` |
| [`flatpak/com.google.Chrome/chrome-flags.conf`](flatpak/com.google.Chrome/chrome-flags.conf) | `~/.var/app/com.google.Chrome/config/chrome-flags.conf` | Enables Wayland Ozone auto-detection, GPU rasterization, and Linux/NVIDIA VA-API hardware video decode (`NVD_BACKEND=direct` Flatpak override) |
| [`bashrc.d/99-buildbox-env.sh`](bashrc.d/99-buildbox-env.sh) | `~/.bashrc.d/99-buildbox-env.sh` (symlink) | Exports `PYTHON_JIT=1`, `PUB_CACHE`, dynamic `DJANGO_TEST_PARALLEL`, and rootless `DOCKER_HOST` (`podman.sock`) |
| [`ostree-etc-diff.example.txt`](ostree-etc-diff.example.txt) | Reference only (sanitized) | Redacted example of `ostree admin config-diff`; **never commit raw host `/etc` diffs to a public repo** |

---

## Why Raw Host Diffs Stay Out of the Public Repo

Running `ostree admin config-diff` on a live machine prints filenames from `/etc` such as:
- `NetworkManager/system-connections/<SSID>.nmconnection` (Wi-Fi network names)
- `nvme/hostnqn`, `nvme/hostid`, `machine-id` (hardware/host identifiers)
- `pki/akmods/private/*.priv` (local module signing keys)

`apply_host_tuning.sh` therefore writes `ostree-etc-diff.txt` to `$BUILDBOX_PRIVATE_DIR` (automatically resolving to `../buildbox-private/hosts/<host>/` if that private sibling repository exists, or gitignored `.local/state/` otherwise).

---

## Usage

```bash
# 1. Inspect live host kernel, CPU EPP, zram, Btrfs, NVIDIA CDI, Nix, Chrome, and /etc tracking (no sudo)
bash host/apply_host_tuning.sh --status

# 2. Apply user-level ~/.bashrc.d link and Flatpak Chrome GPU/VA-API flags (no sudo)
bash host/apply_host_tuning.sh --user-desktop
source ~/.bashrc.d/99-buildbox-env.sh

# 3. Apply drop-in host tuning & record pre/post commits in /etc/.git
#    (Defaults to BUILDBOX_WORKLOAD=desktop; pass BUILDBOX_WORKLOAD=build for headless throughput-performance)
#    (Add --skip-toolbox if relying strictly on flake.nix without Toolbx extras)
sudo bash host/apply_host_tuning.sh --apply --skip-toolbox

# 4. Inspect chronological /etc history recorded by etckeeper / /etc/.git
sudo git -C /etc log --oneline -n 10

# 5. Revert all buildbox /etc drop-ins and restore balanced CPU profile
sudo bash host/apply_host_tuning.sh --rollback
```

> **Note on `/etc/ostree/prepare-root.conf` and `nix-mkdir.service`:** These two files affect initramfs/early boot for Determinate Nix on `composefs` systems and require `rpm-ostree initramfs-etc --track=/etc/ostree/prepare-root.conf --reboot`. Follow [`../docs/plans/plan-1-determinate-nix-installer.md`](../docs/plans/plan-1-determinate-nix-installer.md) to install them safely with pre/post `/etc/.git` snapshots.
