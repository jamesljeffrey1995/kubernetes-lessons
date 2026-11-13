#!/usr/bin/env bash
# Installs (or resets) Pulse v1 into the 'pulse' namespace and runs its self-test.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "==> Namespace (enforces the 'restricted' Pod Security Standard)"
kubectl apply -f k8s/namespace.yaml

echo "==> helm upgrade --install pulse"
helm upgrade --install pulse chart/pulse -n pulse --wait --timeout 5m

echo "==> helm test"
helm test pulse -n pulse --logs

echo
echo "Pulse is running. Open http://pulse.localhost:8080"
echo "(or: curl -H 'Host: pulse.localhost' http://127.0.0.1:8080)"
