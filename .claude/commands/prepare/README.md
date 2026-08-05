# /prepare — Installation Preparation

Resolves an OpenShift release image, generates a dev-scripts config file, validates the environment, and prints the deployment command — without deploying.

## Usage

```
/prepare <topology> <method> <medium> <version> [options]
```

### Examples

```
# TNF fencing cluster, IPI on AWS, latest 4.21 GA
/prepare tnf ipi aws 4.21

# Arbiter cluster, agent method on external host, latest nightly
/prepare tna agent external 4.22 nightly

# SNO with specific version, forced overwrite
/prepare sno ipi aws 4.20.5 force=true

# Fencing on aarch64 Graviton instance
/prepare tnf ipi aws 4.21 arch=aarch64

# Using a dev-scripts fork for testing
/prepare tnf ipi aws 4.21 nightly ds-repo=https://github.com/user/dev-scripts ds-branch=fix/my-change
```

### Parameters

| Parameter | Values | Default |
|-----------|--------|---------|
| topology | `tna`/`arbiter`, `tnf`/`fencing`, `sno` | required |
| method | `ipi`, `agent` | required |
| medium | `aws`, `external` | required |
| version | `4.21`, `4.21 nightly`, `4.22 EC`, etc. | required |
| ip-stack | `v4`, `v6`, `v4v6` | `v4` |
| arch | `x86_64`, `aarch64` | auto-detected |
| force | `true` | `false` |
| ds-repo | fork URL | none |
| ds-branch | fork branch | none |

## What It Does

1. **Resolves** the version spec to a concrete release image (nightly from CI registry, or GA/EC/RC from quay.io)
2. **Pins by digest** when method=agent (agent installs require digest-pinned images)
3. **Generates** `config/config_<topology>.sh` from the example template with correct vars
4. **Validates** CI token, pull secret auth, and architecture constraints
5. **Runs** `make doctor <topology>-<method>` as a final gate
6. **Prints** the deployment command — but never runs it

## What It Does NOT Do

- Deploy a cluster (that's `make deploy` or `ansible-playbook`)
- Set up credentials or pull secrets (that's `/setup`)
- Manage kcli, assisted, or baremetal-adopt configs (dev-scripts only in v1)

## Helper Scripts

For scripted or CI use, call the helpers directly:

```bash
# Resolve a release image
helpers/resolve-release-image.sh --version 4.21-nightly --arch x86_64

# Generate config
helpers/prepare-config.sh --topology fencing --method ipi \
  --release-image <pullspec> --ci-token <token>
```

Run each script with `--help` for full usage.
