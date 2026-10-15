# Contributing to Two-Node Toolbox

Two-Node Toolbox (TNT) is a deployment automation framework for two-node
OpenShift clusters in development and testing environments. It supports
arbiter and fencing topologies via dev-scripts, kcli, and assisted installer
deployment methods. Contributions from across Red Hat engineering are welcome.

## Getting Started

1. Fork `openshift-eng/two-node-toolbox` on GitHub.
2. Clone your fork:

   ```bash
   git clone git@github.com:<your-username>/two-node-toolbox.git
   cd two-node-toolbox
   ```

3. Set up commit signing (GPG or SSH). The repo enforces signature
   verification — unsigned commits are rejected. See [GitHub's signing
   docs](https://docs.github.com/en/authentication/managing-commit-signature-verification)
   for setup instructions.
4. Ensure a container engine is available. All linters run in containers,
   so no local tool installation is needed beyond the engine itself.
   `CONTAINER_ENGINE` defaults to `podman`; override with
   `CONTAINER_ENGINE=docker` if needed.
5. Install the pre-commit hook:

   ```bash
   make install-pre-commit
   ```

   The hook runs `make verify` automatically on every commit, catching
   lint issues before they reach CI.

## What You Can Contribute

| Type | Location | Guidance |
|------|----------|---------|
| New deployment method | `deploy/openshift-clusters/roles/` | Add an Ansible role, wire into the Makefile |
| New topology | `deploy/openshift-clusters/` | Add config template and playbook support |
| Bug fix / enhancement | Relevant component directory | Follow existing patterns in that area |
| Helper script | `helpers/` | Standalone utility for cluster operations |
| Documentation | `docs/`, component READMEs | See the [Documentation](#documentation) section |
| CI / Prow job | External: `openshift/release` repo | CI configuration lives outside this repo |

## Development Workflow

Create a branch from `main` using the appropriate naming convention:

- Features: `OCPEDGE-XXXX-short-slug`
- Bug fixes: `fix/OCPBUGS-XXXX-slug`

Run all checks before committing:

```bash
make verify
```

For targeted checks, run individual linters:

```bash
make shellcheck      # Shell script linting
make yamlfmt         # YAML formatting (auto-formats by default)
make ansible-lint    # Ansible linting + playbook syntax check
```

`make yamlfmt` auto-formats files by default. `make verify` runs it in
validate-only mode (no modifications). `make shellcheck` is read-only.

## Code Standards

All linters run inside containers via `hack/` scripts — no local tool
installation is required beyond a container engine.

### Shell Scripts

- `#!/usr/bin/env bash` shebang
- `set -euo pipefail` at the top
- Quote all variables to prevent word splitting
- UPPER_CASE for variable names
- Must pass shellcheck

### YAML

- 2-space indentation
- Quote strings containing special characters
- Must pass yamlfmt

### Ansible

- Follow existing role patterns in `deploy/openshift-clusters/roles/`
- Must pass ansible-lint (`.ansible-lint` defines the baseline)
- Do not add new entries to the `.ansible-lint` skip list — fix violations
  instead
- Playbooks must pass `ansible-playbook --syntax-check` (run automatically
  by `make ansible-lint`)

### Python (when applicable)

- PEP 8 compliance, must pass ruff (checked by CodeRabbit on PRs)
- Use f-strings for formatting

## Testing

- **Local:** `make verify` runs all linters (shellcheck, yamlfmt,
  ansible-lint).
- **Pre-commit:** The hook runs `make verify` automatically on every commit.
- **End-to-end:** Deployment changes require testing on an actual cluster
  (AWS hypervisor or Bring Your Own Server). Not everything in deployment
  automation is unit-testable — integration testing against real
  infrastructure is expected.
- **CI:** Prow jobs and CodeRabbit run on PRs. Both must pass before
  requesting human review.

## Security

- Never hardcode credentials, tokens, or secrets in code or commits.
- Use environment variables for sensitive data (`CI_TOKEN`, pull secrets).
- Pull secrets belong in `config/pull-secret.json` (gitignored).
- Verify that logs and command output do not leak credentials before
  committing.
- `.gitignore` already excludes sensitive config files — do not circumvent
  it.

## Documentation

- Update relevant READMEs when changing behavior.
- Professional, terse, customer-centric style — no emojis or marketing
  language.
- When adding new Make targets, update the Makefile help text.
- **CLAUDE.md maintenance:** If a change adds new paths, commands, roles,
  or configuration options, update `CLAUDE.md` at the repo root.
  AI-assisted contributors rely on it for accurate context. Treat it like
  any other documentation — it must reflect the current state of the repo.

## Commit Conventions

- **With Jira ticket:** `OCPEDGE-XXXX: description` (primary format)
- **Without ticket:** `type: description` where type is one of: feat, fix,
  docs, chore
- All commits **must be signed** (GPG or SSH). The repo has signature
  verification enabled — unsigned commits are rejected.
- Keep commits focused and atomic.

## Pull Requests

- Open PRs from your fork against `main`.
- PR title follows the same convention as commit messages.
- **CodeRabbit** runs automated review on all PRs.
- **Prow** jobs run additional CI checks.
- Review is handled by teams in OWNERS: **edge-enablement** and
  **team-dragonfly**.
- Address CodeRabbit feedback before requesting human review.
- Run `make verify` locally before pushing.
