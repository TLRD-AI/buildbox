# Plan 1: Install Nix on Fedora Atomic (`composefs`) with the Determinate Nix Installer

**Goal:** Add multi-user Nix with Flakes directly to a Fedora Atomic (`rpm-ostree`) host without layering any OS packages. Keep `/etc/.git` audit history going, and preserve any existing `.toolchains/` fallback until Plan 2 (`flake.nix`) is proven.

**Status:** Completed and verified on Fedora 45 Kinoite (`Determinate Nix 3.24.2` / `nix 2.35.3`, Flakes enabled, survives `rpm-ostree` upgrades + reboots). Because Fedora 45 Kinoite enables `composefs` by default, `/` required enabling `root.transient = true` in `/etc/ostree/prepare-root.conf` (tracked via `rpm-ostree initramfs-etc`) plus a pre-mount `nix-mkdir.service` unit so `nix-directory.service` skips `chattr -i /`.

---

## Step 1: Snapshot and Checks Before Installing

The installer creates systemd units, `/etc/nix/nix.conf`, and a mount for `/nix`. Snapshot `/etc` first so every change it makes shows up as a clean diff.

1. Commit the current `/etc` state:
   ```bash
   sudo git -C /etc add -A
   sudo git -C /etc commit -m "Pre-Determinate Nix installer snapshot"
   ```
2. Check the ostree deployment and free disk space:
   ```bash
   rpm-ostree status
   df -h /var /var/home
   ```
   Ensure `/var` has roughly 15–20 GB free. `/nix/store` grows quickly once Flutter, Chromium, and Python are pulled in.
3. Save a baseline status report outside the public repo (for example into `../buildbox-private`):
   ```bash
   bash host/apply_host_tuning.sh --status > ../buildbox-private/hosts/fedora-kinoite/pre-nix-status.txt
   ```

---

## Step 2: Enable Transient Root for `composefs` and Install Determinate Nix (`ostree` Planner)

Fedora Atomic enables `composefs` in `/usr/lib/ostree/prepare-root.conf`, which mounts `/` read-only and breaks `nix-directory.service`'s `chattr -i /` (`Operation not supported while reading flags on /`). Enable `root.transient = true`, reboot, pre-create `/nix` with `nix-mkdir.service` (causing `nix-directory.service`'s `ConditionPathExists=!/nix` to skip cleanly), and run the installer in a normal host terminal (not inside a Toolbx or Distrobox):

```bash
sudo install -m 644 host/etc/ostree/prepare-root.conf /etc/ostree/prepare-root.conf
sudo git -C /etc add -A
sudo git -C /etc commit -m "Enable ostree root.transient for /nix mount point"
sudo rpm-ostree initramfs-etc --track=/etc/ostree/prepare-root.conf --reboot
```

After rebooting:

```bash
sudo install -m 644 host/etc/systemd/system/nix-mkdir.service /etc/systemd/system/nix-mkdir.service
sudo systemctl daemon-reload
sudo systemctl enable --now nix-mkdir.service

curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install ostree
```

- The `ostree` planner is built for an immutable `/`. It keeps the store under `/var/home/nix` and bind-mounts it at `/nix` with `nix.mount`. It also sets SELinux contexts, turns on Flakes (`extra-experimental-features = nix-command flakes`), and enables `nix-daemon.socket`.
- Review the plan printed by the installer before confirming.
- Open a new login shell afterwards so `nix-daemon.sh` gets sourced.

---

## Step 3: Record the New `/etc` State

```bash
sudo git -C /etc status
sudo git -C /etc add -A
sudo git -C /etc commit -m "Install Determinate Nix (ostree planner)"
# Write raw ostree config-diff to your private host-state repo (never the public repo)
sudo ostree admin config-diff > ../buildbox-private/hosts/fedora-kinoite/ostree-etc-diff.txt
```

---

## Step 4: Verify Nix and Existing Host Services

1. Nix and Flakes:
   ```bash
   nix --version
   nix flake --help >/dev/null && echo "FLAKES_OK"
   nix run nixpkgs#hello
   ```
2. Existing rootless Podman & host tuning:
   ```bash
   systemctl --user is-active podman.socket
   bash host/apply_host_tuning.sh --status
   ```
3. Survives OS updates and reboots: run `rpm-ostree upgrade`, reboot, and confirm `/nix` mounts and `nix run nixpkgs#hello` still works.

---

## Rollback

The Determinate installer includes an uninstaller that removes `/nix`, its systemd units, and `/etc/nix`:

```bash
/nix/nix-installer uninstall
sudo systemctl disable --now nix-mkdir.service
sudo rm -f /etc/systemd/system/nix-mkdir.service /etc/ostree/prepare-root.conf
sudo systemctl daemon-reload
sudo git -C /etc add -A
sudo git -C /etc commit -m "Uninstall Determinate Nix"
sudo rpm-ostree initramfs-etc --untrack=/etc/ostree/prepare-root.conf --reboot
```

---

## Risks and Mitigations

| Risk | Mitigation |
| :--- | :--- |
| A future Fedora major-version rebase breaks the `/nix` mount unit or SELinux labels | Re-run `/nix/nix-installer repair` |
| `/var` runs out of space as `/nix/store` grows | Run `nix store gc` periodically; enable `auto-optimise-store = true` in `/etc/nix/nix.custom.conf` |
| Non-login agent shells do not source `nix-daemon.sh` | Use `direnv` + `nix-direnv` (Plan 2) or invoke commands with `nix develop -c ...` |
