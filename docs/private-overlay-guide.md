# Public / Private Repository Separation Guide

This repository (`TLRD-AI/buildbox`) is **public** and designed as an exemplar Fedora Atomic + Nix + Devcontainer blueprint. Live workstations inevitably accumulate machine-specific or sensitive files that should **never** be published:

- Local `.env` files with API tokens, passwords, or SSH targets
- Raw `ostree admin config-diff` output (which includes `NetworkManager/system-connections/<SSID>.nmconnection`, `nvme/hostnqn`, `machine-id`, and `pki/akmods/private/*`)
- Live host status snapshots, private Tailscale hostnames, or internal organization runbooks

---

## Why Not Fork a Private Repo to a Public "Redacted" Branch?

1. **GitHub visibility restriction:** GitHub does not allow forking a private repository into a public repository, nor making a single branch public inside a private repo.
2. **Git history leaks:** Even if you push a "redacted" branch to a separate public repository, any shared commit ancestor retains the original unredacted files in `git log`. Redacting in a later commit does **not** scrub earlier commits.

---

## Recommended Pattern: Two Independent Repositories (Zero Shared History)

Keep two completely separate sibling repositories with **no shared Git commits**:

```text
~/Documents/dev/
├── buildbox/                  # PUBLIC (TLRD-AI/buildbox)
│   ├── flake.nix              # Exemplar Nix flake, Devcontainer, host drop-ins, docs
│   ├── .env.example           # Safe placeholders only
│   └── scripts/check_secrets.sh
├── buildbox-private/          # PRIVATE (TLRD-AI/buildbox-private)
│   ├── hosts/fedora-kinoite/
│   │   ├── ostree-etc-diff.txt
│   │   └── pre-nix-status.txt
│   └── notes/                 # Internal org/host-specific runbooks
└── my-app/                    # Downstream project repos referencing ../buildbox
```

### How `host/apply_host_tuning.sh` Integrates Automatically

[`../host/apply_host_tuning.sh`](../host/apply_host_tuning.sh) checks for the private repo automatically when recording `ostree admin config-diff`:
1. If `$BUILDBOX_PRIVATE_DIR` is exported, snapshots are written there.
2. Otherwise, if `../buildbox-private` exists beside `buildbox`, snapshots are written into `../buildbox-private/hosts/<host>/ostree-etc-diff.txt`.
3. Otherwise, snapshots fall back to gitignored `.local/state/ostree-etc-diff.txt` inside `buildbox`.

### Defense in Depth Inside `buildbox`

- [`.gitignore`](../.gitignore) excludes `.env`, keys, `.nmconnection`, raw status/diff dumps, and `.local/` / `private/`.
- [`../scripts/check_secrets.sh`](../scripts/check_secrets.sh) and [`../scripts/git-hooks/pre-commit`](../scripts/git-hooks/pre-commit) block accidental staging of forbidden paths, oversized files, API tokens, private keys, or host-private paths.
- [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs `bash scripts/check_secrets.sh --all` on every push and pull request.
