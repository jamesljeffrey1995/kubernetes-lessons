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

step "Creating kind cluster '$CLUSTER_NAME' (first time takes 1-3 minutes)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists - reusing it."
  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
else
  kind create cluster --config "$KIND_CONFIG"
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
