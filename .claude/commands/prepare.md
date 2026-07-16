---
description: Prepare a dev-scripts cluster config with a resolved OpenShift release image
---

You are preparing an OpenShift cluster configuration for deployment via dev-scripts. This skill resolves a release image, generates a config file, and validates the environment — but never deploys.

## Arguments

`/prepare <topology> <method> <medium> <version...> [key=value...]`

**Positional (required):**
- **topology**: `tna` / `arbiter`, `tnf` / `fencing`, or `sno`
- **method**: `ipi` or `agent`
- **medium**: `aws` or `external`
- **version**: free text mapped to a resolver spec (see below)

**Optional key=value overrides:**
- `ip-stack=v4|v6|v4v6` (default: v4)
- `arch=x86_64|aarch64` (override auto-detection)
- `force=true` (overwrite existing config)
- `ds-repo=URL` (dev-scripts fork URL)
- `ds-branch=BRANCH` (dev-scripts fork branch)

## Version Mapping

| User says | Resolver spec |
|-----------|---------------|
| `4.21 nightly` | `4.21-nightly` |
| `latest 4.22 EC/RC` | `4.22-prerelease` |
| `4.22 EC` | `4.22-ec` |
| `4.20` or `4.20 GA` | `4.20` |
| `4.20.5` | `4.20.5` |
| Contains `/` or `@sha256:` | `--pullspec` (explicit) |

## Non-Interactive Contract

When all positional arguments are present, **never prompt open-endedly**. If prerequisites are missing, emit one consolidated failure block listing each issue with its fix, then stop:

```
Missing prerequisites:
- pull-secret.json: run /setup dev-scripts
- CI Token: run /setup, CI Token section
- inventory.ini: run /setup external (for external medium)
```

Interactive prompting is only for humans invoking with missing arguments.

## Scope

**Dev-scripts only** (v1). No kcli, assisted, or baremetal-adopt. If the user asks for kcli or assisted, tell them it's out of scope and point to the relevant make targets.

## CI Token Sourcing

1. Check existing `config/config_*.sh` files for an active `export CI_TOKEN="..."` line (any topology)
2. If found and not a placeholder (`<PASTE`), reuse it silently
3. If not found: ask the human / fail the agent path with a pointer to `/setup`
4. **Never echo the token into chat output**

## Architecture Determination

1. `arch=` key wins if provided
2. medium=aws: read `EC2_INSTANCE_TYPE` from `config/instance.env` — Graviton families (`c7g`, `m7g`, `r7g`, `c6g`, `m6g`, `r6g`, etc.) → `aarch64`; otherwise `x86_64`
3. medium=external: default `x86_64` with a note that `arch=aarch64` can override

## Constraint Matrix

| Constraint | Effect |
|------------|--------|
| aarch64 + ip-stack != v4 | **Blocked** — IPv6/dual-stack unsupported on ARM |
| aarch64 + -multi image | **Blocked** — explicit aarch64 payload required |
| agent + ip-stack != v4 | **Warning** — scenario name must exist in dev-scripts e2e list |
| CI_TOKEN missing/placeholder | **Blocked** — always required |

These are enforced in the helper scripts. If the user hits one, explain why and what to change.

## Execution Steps

Run each step as a separate Bash call. Branch on exit codes.

### Step 1: Bootstrap worktree config (worktrees only)

```bash
helpers/sync-worktree-config.sh
```

The script auto-detects whether it is running in a worktree. If so, it copies essential config files (`pull-secret.json`, `instance.env`, `config_*.sh`) from the main checkout into the worktree's `config/` folder — picking the newer of `config/<file>` and the canonical sync destination when both exist. If not a worktree, it exits silently.

After this step, `config/pull-secret.json` must exist. If it is still missing, fail with the standard prerequisites block.

### Step 2: Resolve release image

```bash
helpers/resolve-release-image.sh \
  --version <spec> \
  --arch <arch> \
  $([ "<method>" = "agent" ] && echo "--digest") \
  --pull-secret config/pull-secret.json \
  --validate-access \
  $([ -n "<ci_token>" ] && echo "--ci-token <ci_token>")
```

Capture stdout (single-line pullspec). On failure:
- Exit 2: invalid version spec → show valid formats
- Exit 3: no matching release → suggest checking version number
- Exit 5: access denied → point to `/setup` for credentials

### Step 3: Ensure instance.env exists (medium=aws only)

Skip this step when medium is not `aws`.

Check if `config/instance.env` exists:
- **If present**: proceed silently (do not re-copy the template over user edits)
- **If missing**: copy the template and warn about defaults

```bash
cp config/instance.env.template config/instance.env
```

After copying, emit a warning (not a failure — the defaults are usable):
```
NOTE: Created config/instance.env from template with defaults:
  - EC2_INSTANCE_TYPE=c5n.metal (x86_64 Intel)
  - REGION=us-west-2
  - AWS_PROFILE=microshift-dev
Review and edit config/instance.env if these defaults are not suitable.
```

Do NOT prompt for edits when all positional args are present (non-interactive contract). Just warn and continue.

### Step 4: Generate config

```bash
helpers/prepare-config.sh \
  --topology <topology> \
  --method <method> \
  --release-image <pullspec from step 2> \
  --ci-token <ci_token> \
  --ip-stack <stack> \
  --arch <arch> \
  $([ "<force>" = "true" ] && echo "--force") \
  $([ -n "<ds_repo>" ] && echo "--ds-repo <ds_repo>") \
  $([ -n "<ds_branch>" ] && echo "--ds-branch <ds_branch>")
```

On failure:
- Exit 3: constraint violation → explain the specific constraint
- Exit 4: config exists → ask if they want `force=true` (human) or tell agent callers to pass `force=true`
- Exit 5: self-check failed → likely template drift, report verbatim

### Step 5: Run doctor

Before running Make, normalize the topology: if the user said `tnf`, use `fencing`; if `tna`, use `arbiter`. The `<topology>` below must be `arbiter`, `fencing`, or `sno`.

**medium=aws** (default — no AWS= override needed):
```bash
cd deploy && make sync-config && make doctor <topology>-<method>
```

**medium=external:**
```bash
cd deploy && make doctor AWS=0 <topology>-<method>
```

The `sync-config` call propagates `config/instance.env` to the canonical location (`deploy/aws-hypervisor/instance.env`) that doctor reads. `AWS=0` opts out of the instance.env requirement for external hosts.

Relay FAIL lines verbatim. Doctor is read-only — it won't break anything.

### Step 6: Print deployment commands (never run them)

**medium=aws:**
```
cd deploy && make deploy <topology>-<method>
```
Note: if an instance is already running (`make status`), `make <topology>-<method>` reuses it.

**medium=external:**
```
ansible-playbook deploy/openshift-clusters/setup.yml \
  -e "topology=<topology>" -e "interactive_mode=false" \
  $([ "<method>" = "agent" ] && echo '-e "method=agent"') \
  -i deploy/openshift-clusters/inventory.ini
```
Note for first-time external hosts: run `ansible-playbook deploy/openshift-clusters/init-host.yml -i deploy/openshift-clusters/inventory.ini` first.

## After Completion

Report what was done:
- Resolved image (tag or digest)
- Config file path written
- Doctor result (pass/fail)
- Deployment command to run

Do **not** offer to run the deployment. The user decides when to deploy.
