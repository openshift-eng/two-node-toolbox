## Custom OCP Payload with Operator Overrides

Build custom operator images and create an OCP payload with those overrides for testing.

## Prerequisites

- **Required Tools**: `bash`, `git`, `podman`, `oc`
- **Registry Access**: 
  - Read access to `registry.ci.openshift.org` (OCP CI builds)
  - Write access to your target registry (e.g., `quay.io/<your-namespace>`)
- **Credentials**: Valid `REGISTRY_AUTH_FILE` with both CI and target registry credentials
- **Operator Repositories**: Local clones of operators you want to build

## Quick Start

```bash
# 0. Setup configuration (first time only)
cp profile.env.template profile.env
cp operators.conf.template operators.conf
# Edit both files with your settings

# 1. Build operator images
./build-operators.sh ceo

# 2. Create custom payload with overrides
./ocp-create-payload ceo -b registry.ci.openshift.org/ocp/release-5:5.0.0-0.nightly-YYYY-MM-DD-HHMMSS

# 3. Deploy cluster with custom payload
# (see "Using the Custom Payload" section)
```

## Workflow

### Step 0: Setup Configuration (First Time)

Copy template files and customize for your environment:

```bash
# Copy templates
cp profile.env.template profile.env
cp operators.conf.template operators.conf

# Edit profile.env - set your quay.io namespace
vi profile.env

# Edit operators.conf - set paths to your operator repos
vi operators.conf
```

### Step 1: Configure Operator Profiles

Edit `operators.conf` to define your operators:

```ini
[ceo]
name=cluster-etcd-operator
repo=/path/to/your/cluster-etcd-operator
dockerfile=Dockerfile.ocp

[cno]
name=cluster-network-operator
repo=/path/to/your/cluster-network-operator
dockerfile=Dockerfile
```

By default a build uses whatever branch each repo currently has checked out. Add an
optional `default_branch=<branch>` to a profile to pin it, or override per-build with
`build-operators.sh <profile>:<branch>`.

### Step 2: Configure Registry Settings

Edit `profile.env` with your settings:

```bash
# Registry namespace for built images (REQUIRED)
QUAY_NAMESPACE="quay.io/<your-namespace>"

# Image tag
IMAGE_TAG=latest

# Target custom payload image
TARGET_IMAGE="quay.io/<your-namespace>/custom-ocp-payload:5.0-test"

# Pull secret location
export REGISTRY_AUTH_FILE=~/.config/containers/auth.json
```

### Step 3: Build Operator Images

Build one or more operators:

```bash
# Build single operator
./build-operators.sh ceo

# Build multiple operators
./build-operators.sh ceo cno

# Override namespace/tag
./build-operators.sh ceo -n quay.io/myrepo -t dev

# Verbose mode
./build-operators.sh ceo -v
```

The script will:
1. Check registry access to `registry.ci.openshift.org`
2. Build each operator image using podman
3. Tag images to your registry namespace
4. Push images to registry

### Step 4: Create Custom Payload

Generate a custom OCP payload with your operator overrides:

```bash
# Specify base release (required if OCP_VERSION not set in profile.env)
./ocp-create-payload ceo -b registry.ci.openshift.org/ocp/release-5:5.0.0-0.nightly-2026-07-01-125918

# Use built images from operators.conf (base release comes from OCP_VERSION in profile.env)
./ocp-create-payload ceo

# Override target payload image
./ocp-create-payload ceo -o quay.io/myrepo/custom:test

# Override namespace/tag for operator images
./ocp-create-payload ceo cno -n quay.io/myrepo -t dev
```

The script will:
1. Look up image names for each profile in `operators.conf`
2. Generate image override arguments
3. Resolve base OCP release from `OCP_VERSION` in `profile.env` or the `-b` flag
4. Create custom payload with `oc adm release new`

### Step 5: Using the Custom Payload

#### Option A: Update SNO Config

Edit `../../deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_sno.sh`:

```bash
export OPENSHIFT_RELEASE_IMAGE=quay.io/<your-namespace>/custom-ocp-payload:5.0-test
```

Then deploy normally with dev-scripts.

#### Option B: Extract oc Client

```bash
# Extract oc CLI from custom payload
oc adm release extract --tools quay.io/<your-namespace>/custom-ocp-payload:5.0-test

# Or just the oc command
oc adm release extract --command=oc --to=/usr/local/bin quay.io/<your-namespace>/custom-ocp-payload:5.0-test
```

## Registry Configuration

### Configure quay.io Credentials

On your quay.io account (legacy UI):

1. Click _your name > Account Settings_
2. Click _Generate encrypted password_ and enter password
3. Go to _Docker Configuration_ tab
4. Click _View \<username\>-auth.json_
5. Copy the `"quay.io": { "auth": ... }` block
6. Add to your pull-secret as `"quay.io/username"` (avoids conflict with main quay.io entry)

### Configure CI Registry Access

For OCP nightly builds from `registry.ci.openshift.org`:

1. Login to [CI cluster](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/)
2. Get token and login with podman:
   ```bash
   oc whoami -t | podman login -u=$(oc whoami) --password-stdin \
     registry.ci.openshift.org --authfile=$REGISTRY_AUTH_FILE
   ```

See [CI Registry Access](https://docs.ci.openshift.org/docs/how-tos/use-registries-in-build-farm/#how-do-i-gain-access-to-qci)

## Advanced Usage

### Custom Operator Branches

Builds use each repo's currently checked-out branch by default. To build a specific
branch instead (checks it out, then restores the original ref afterward):

```bash
./build-operators.sh ceo:my-feature-branch
```

### Verify Payload Contents

```bash
# List images in payload
oc adm release info quay.io/<your-namespace>/custom-ocp-payload:5.0-test

# Extract specific image
oc adm release extract quay.io/<your-namespace>/custom-ocp-payload:5.0-test \
  --file=image-references > images.json
```

## Troubleshooting

### Registry Authentication

If build fails with registry auth errors:

```bash
# Check CI registry access
./build-operators.sh ceo
# The script will provide instructions if authentication fails
```

### Image Name Mapping

The payload image name comes from the `name=` field in `operators.conf`:
- `name=cluster-config-operator` → payload image `cluster-config-operator`
- `name=cli` → payload image `cli`

Verify with: `oc adm release info <base-release> | grep <name>`
