# Buildbox Documentation Index

Comprehensive architecture writeups, public/private secret separation guides, and the five phased implementation plans for this buildbox stack.

---

## Architecture & Security Guides

- [`architecture-overview.md`](architecture-overview.md) — Concise 6-layer overview of immutable Fedora Atomic, Determinate Nix, Devcontainer, `Toolbx`, rootless Podman, and `/etc/.git` auditing.
- [`architecture-detailed.md`](architecture-detailed.md) — Deep technical breakdown of `composefs` transient root, `LD_LIBRARY_PATH` library isolation, Podman `docker-compose-switch` avoidance, Btrfs CoW workspaces, and dual-ledger `/etc` rollback.
- [`private-overlay-guide.md`](private-overlay-guide.md) — How to pair this public exemplar (`TLRD-AI/buildbox`) with a separate private host-state repo (`buildbox-private`) without sharing Git history or leaking secrets.

---

## Phased Implementation Plans

| Plan | Document | Scope |
| :--- | :--- | :--- |
| **Plan 1** | [`plans/plan-1-determinate-nix-installer.md`](plans/plan-1-determinate-nix-installer.md) | Installing Determinate Nix (`ostree` planner) on Fedora Atomic (`composefs`) using `root.transient = true` and `nix-mkdir.service` |
| **Plan 2** | [`plans/plan-2-flake-nix.md`](plans/plan-2-flake-nix.md) | Replacing ad-hoc host binaries with a pinned cross-platform `flake.nix`, `direnv`/`nix-direnv`, GPU/SwiftShader Chromium wrapper, and CI |
| **Plan 3** | [`plans/plan-3-devcontainer.md`](plans/plan-3-devcontainer.md) | Option A Nix-backed Devcontainer with rootless Podman `keep-id`, SELinux `label:disable`, `oom_score_adj` parity, and NVIDIA CDI |
| **Plan 4** | [`plans/plan-4-macos-nix-devcontainer.md`](plans/plan-4-macos-nix-devcontainer.md) | Onboarding an 8 GB Apple Silicon macOS workstation onto Nix Flakes + Devcontainer (SIP `DYLD_*` rules, Obj-C fork safety, VM memory caps) |
| **Plan 5** | [`plans/plan-5-macos-ci-xcode.md`](plans/plan-5-macos-ci-xcode.md) | Hardening an 8 GB / 256 GB M1 Mac mini as an isolated non-admin Xcode + multi-repo CI node (`mkShellNoCC`, `ci-build-lock`, `apple-release` gates) |

---

## Component READMEs

- [`../host/README.md`](../host/README.md) — Host OS `/etc` drop-in templates and `apply_host_tuning.sh`
- [`../.devcontainer/README.md`](../.devcontainer/README.md) — Nix-backed Devcontainer stack
- [`../scripts/git-hooks/README.md`](../scripts/git-hooks/README.md) — Pre-commit secret and host-artifact guardrails
