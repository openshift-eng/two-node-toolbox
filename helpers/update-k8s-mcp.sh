#!/usr/bin/env bash
# Point the user-scope kubernetes-mcp-server (Claude Code) at a deployed cluster.
#
# Usage: helpers/update-k8s-mcp.sh [PROXY_ENV_OR_DIR]
#   Default: deploy/openshift-clusters/proxy.env in this checkout.
#
# Reads KUBECONFIG and the proxy settings from proxy.env, so the MCP server
# reaches the cluster the same way `source proxy.env && oc ...` does.
# Env: K8S_MCP_CONFIG overrides the server TOML (default
# ~/.config/kubernetes-mcp-server.toml, created read-only if missing).
set -euo pipefail

NAME=kubernetes-mcp-server
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${K8S_MCP_CONFIG:-$HOME/.config/kubernetes-mcp-server.toml}

command -v claude >/dev/null || { echo "claude CLI not found in PATH" >&2; exit 1; }

target=${1:-$REPO_ROOT/deploy/openshift-clusters/proxy.env}
[[ -d $target ]] && target=$target/proxy.env
[[ -f $target ]] || { echo "proxy.env not found: $target" >&2; exit 1; }
target=$(realpath "$target")

# proxy.env exports KUBECONFIG and the proxy vars; read them in a subshell.
eval "$(
  # shellcheck disable=SC1090
  source "$target" >/dev/null
  printf 'KUBECONFIG_PATH=%q CLUSTER_PROXY=%q MCP_NO_PROXY=%q\n' "$KUBECONFIG" "$HTTPS_PROXY" "$NO_PROXY"
)"
[[ -f $KUBECONFIG_PATH ]] || { echo "kubeconfig missing: $KUBECONFIG_PATH" >&2; exit 1; }

mkdir -p "$(dirname "$CONFIG")"
if [[ ! -f $CONFIG ]]; then
  echo 'read_only = true' > "$CONFIG"
fi

# A user-scope entry resolves this path from Claude's working directory, not this shell's.
CONFIG=$(realpath "$CONFIG")

# A 'kubeconfig' key in the TOML overrides the KUBECONFIG env var set below.
if grep -qE '^[[:space:]]*kubeconfig[[:space:]]*=' "$CONFIG"; then
  echo "$CONFIG sets 'kubeconfig', which overrides KUBECONFIG=$KUBECONFIG_PATH" >&2
  exit 1
fi

# npx must reach the npm registry directly; the cluster proxy returns 403 for it.
MCP_NO_PROXY="$MCP_NO_PROXY,npmjs.org,registry.npmjs.org"

claude mcp remove "$NAME" -s user >/dev/null 2>&1 || true
claude mcp add "$NAME" -s user \
  -e KUBECONFIG="$KUBECONFIG_PATH" \
  -e HTTP_PROXY="$CLUSTER_PROXY" -e HTTPS_PROXY="$CLUSTER_PROXY" \
  -e http_proxy="$CLUSTER_PROXY" -e https_proxy="$CLUSTER_PROXY" \
  -e NO_PROXY="$MCP_NO_PROXY" -e no_proxy="$MCP_NO_PROXY" \
  -- npx -y kubernetes-mcp-server@latest --config "$CONFIG" >/dev/null

# A local- or project-scope entry takes precedence over this user-scope one.
if ! claude mcp get "$NAME" 2>/dev/null | grep -q 'Scope: User config'; then
  echo "warning: a local or project scope '$NAME' entry overrides the user-scope entry" >&2
  echo "         remove it with 'claude mcp remove $NAME -s local|project' and re-run" >&2
fi

echo "KUBECONFIG=$KUBECONFIG_PATH"
claude mcp get "$NAME" | grep Status
echo "Run /mcp in your Claude Code session to reconnect."
