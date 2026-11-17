#!/usr/bin/env bash
# Installs (or resets) Pulse v1 into the 'pulse' namespace and runs its self-test.
#
# Where the cluster pulls Pulse from is chosen with environment variables:
#   unset (default)     the local images that build.sh loaded into kind
#   PULSE_IMAGE=REPO    a registry build.sh pushed to, e.g. PULSE_IMAGE=ghcr.io/you/pulse
#   PULSE_REGISTRY_USER + PULSE_REGISTRY_TOKEN
#                       only for a PRIVATE registry: creates the 'pulse-registry' pull secret.
#                       The token is read from your environment and is never written to the repo.
#                       GHCR: a personal access token with the read:packages scope.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PULSE_IMAGE="${PULSE_IMAGE:-}"
HELM_ARGS=()

if [ -n "$PULSE_IMAGE" ]; then
  HELM_ARGS+=(--set-string "image.repository=$PULSE_IMAGE")
fi

echo "==> Namespace (enforces the 'restricted' Pod Security Standard)"
kubectl apply -f k8s/namespace.yaml

if [ -n "$PULSE_IMAGE" ] && [ -n "${PULSE_REGISTRY_USER:-}" ]; then
  [ -n "${PULSE_REGISTRY_TOKEN:-}" ] || { echo "PULSE_REGISTRY_USER is set but PULSE_REGISTRY_TOKEN is not." >&2; exit 1; }
  # The registry host is the first part of the image name. Names without a dot, colon or
  # 'localhost' belong to Docker Hub.
  server="${PULSE_IMAGE%%/*}"
  case "$server" in
    *.*|*:*|localhost) ;;
    *) server="https://index.docker.io/v1/" ;;
  esac
  echo "==> Registry pull secret 'pulse-registry' for $server"
  cfg=$(mktemp)
  trap 'rm -f "$cfg"' EXIT
  auth=$(printf '%s:%s' "$PULSE_REGISTRY_USER" "$PULSE_REGISTRY_TOKEN" | base64 | tr -d '\n')
  printf '{"auths":{"%s":{"auth":"%s"}}}' "$server" "$auth" > "$cfg"
  kubectl -n pulse create secret generic pulse-registry \
    --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson="$cfg" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$cfg"
  HELM_ARGS+=(--set "imagePullSecrets[0].name=pulse-registry")
fi

echo "==> helm upgrade --install pulse"
helm upgrade --install pulse chart/pulse -n pulse --wait --timeout 5m ${HELM_ARGS[@]+"${HELM_ARGS[@]}"}

echo "==> helm test"
helm test pulse -n pulse --logs

echo
echo "Pulse is running. Open http://pulse.localhost:8080"
echo "(or: curl -H 'Host: pulse.localhost' http://127.0.0.1:8080)"
