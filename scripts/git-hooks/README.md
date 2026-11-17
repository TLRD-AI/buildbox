# Git Secret Guardrail Hooks

This directory provides a client-side `pre-commit` hook backed by [`../check_secrets.sh`](../check_secrets.sh) to keep secrets and machine-specific host artifacts out of the public `TLRD-AI/buildbox` repository.

## Enable Once Per Clone

```bash
git config core.hooksPath scripts/git-hooks
```

*(Inside the `.devcontainer/`, [`../../.devcontainer/post-create.sh`](../../.devcontainer/post-create.sh) configures `core.hooksPath` automatically.)*

## What Is Blocked

- `.env` and `.env.*` (except `.env.example`)
- Private keys and certificates (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.priv`, `id_rsa*`, `id_ed25519*`)
- Raw host dumps (`ostree-etc-diff.txt`, `pre-nix-status.txt`, `host-status.txt`, `*.nmconnection`)
- Generated local Compose overrides (`.devcontainer/docker-compose.local.yml`)
- Token/key patterns (`ghp_`, `gho_`, `github_pat_`, `AKIA...`, `AIza...`, `-----BEGIN ... PRIVATE KEY-----`) and hardcoded secret assignments
- Files larger than 5 MB
