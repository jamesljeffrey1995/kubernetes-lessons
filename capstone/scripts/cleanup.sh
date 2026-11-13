#!/usr/bin/env bash
# Removes Pulse completely (including Redis data).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
kubectl delete -f k8s/load.yaml --ignore-not-found
helm uninstall pulse -n pulse
kubectl delete namespace pulse
