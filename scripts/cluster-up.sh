#!/usr/bin/env bash
# Creates the "lessons" kind cluster and installs the platform pieces:
#   - Gateway API CRDs (platform/gateway-api-crds.yaml)
#   - Traefik gateway/ingress controller (platform/traefik.yaml)
#   - metrics-server, for `kubectl top` and autoscaling (platform/metrics-server.yaml)
#
# Safe to re-run: if the cluster already exists it just (re)applies the platform.
#
# Usage:   ./scripts/cluster-up.sh
# Options: KIND_CONFIG=path/to/other-kind-config.yaml ./scripts/cluster-up.sh
#          SKIP_HOST_CHECKS=1 ./scripts/cluster-up.sh   (skip the pre-flight checks - not recommended)
set -euo pipefail

CLUSTER_NAME="lessons"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND_CONFIG="${KIND_CONFIG:-$ROOT/platform/kind-config.yaml}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

step "Checking this machine (tools, Docker, cgroups, rootless mode)"
if [ "${SKIP_HOST_CHECKS:-}" = "1" ]; then
  warn "SKIP_HOST_CHECKS=1 - skipping host checks"
else
  "$ROOT/scripts/check-prereqs.sh" --for-cluster || die "This machine isn't ready yet - see the ✘ items above."
fi

# If 'docker' is really Podman, kind must be told to use its Podman provider.
if grep -qi podman <<<"$(docker --version 2>/dev/null)" && [ -z "${KIND_EXPERIMENTAL_PROVIDER:-}" ]; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
fi

step "Creating kind cluster '$CLUSTER_NAME' (first time takes 1-3 minutes)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists - reusing it."
  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
else
  # Rootless Podman: kind's docs say some distros (RHEL among them) need kind started in its
  # own systemd scope with cgroup delegation, or it fails with 'requires setting systemd
  # property "Delegate=yes"'. https://kind.sigs.k8s.io/docs/user/rootless/
  CREATE=(kind create cluster --config "$KIND_CONFIG")
  if [ "${KIND_EXPERIMENTAL_PROVIDER:-}" = "podman" ] \
     && [ "$(docker info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ] \
     && command -v systemd-run >/dev/null 2>&1; then
    echo "Rootless Podman detected: starting kind in its own systemd scope (Delegate=yes)."
    CREATE=(systemd-run --scope --user -p "Delegate=yes" "${CREATE[@]}")
  fi
  LOG=$(mktemp)
  if ! "${CREATE[@]}" 2>&1 | tee "$LOG"; then
    echo
    if grep -q "could not find a log line" "$LOG"; then
      warn "Known rootless-Podman issue: kind can't see the node's boot log. Fix, then re-run:"
      warn "  mkdir -p ~/.config/containers"
      warn "  printf '[containers]\\nlog_driver = \"k8s-file\"\\n' >> ~/.config/containers/containers.conf"
    elif grep -q 'Delegate=yes' "$LOG"; then
      warn "cgroup delegation still isn't active for your user. Run ./scripts/check-prereqs.sh;"
      warn "after changing delegate.conf you must FULLY log out (every session - including VS Code"
      warn "remote/terminal sessions) or reboot. Check with: loginctl user-status \$USER"
    elif grep -q 'cgroup v2' "$LOG"; then
      warn "kind still sees cgroup v1. Check: stat -fc %T /sys/fs/cgroup  (must print cgroup2fs)"
    fi
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    rm -f "$LOG"
    die "kind could not create the cluster (full output above)."
  fi
  rm -f "$LOG"
fi
kubectl wait --for=condition=Ready nodes --all --timeout=180s

step "Installing Gateway API CRDs"
kubectl apply --server-side --force-conflicts -f "$ROOT/platform/gateway-api-crds.yaml" >/dev/null
kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null

step "Installing Traefik (the cluster's front door on http://localhost:8080)"
kubectl apply -f "$ROOT/platform/traefik.yaml"
kubectl -n traefik rollout status deploy/traefik --timeout=180s

step "Installing metrics-server (for 'kubectl top' and autoscaling)"
kubectl apply -f "$ROOT/platform/metrics-server.yaml" >/dev/null
if ! kubectl -n kube-system rollout status deploy/metrics-server --timeout=120s; then
  warn "metrics-server is not ready yet. Only lessons 09 and 13 need it; check later with:"
  warn "  kubectl -n kube-system get pods -l k8s-app=metrics-server"
fi

step "Done"
kubectl get nodes
echo
echo "Cluster is ready. kubectl context: kind-$CLUSTER_NAME"
echo "Delete it any time with: ./scripts/cluster-down.sh"
