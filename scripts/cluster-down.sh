#!/usr/bin/env bash
# Deletes the "lessons" kind cluster. Everything inside it is gone; your files are not touched.
set -euo pipefail
# shellcheck source=scripts/engine.sh
source "$(dirname "${BASH_SOURCE[0]}")/engine.sh"     # picks Docker or Podman (and sudo), like cluster-up
kind delete cluster --name lessons
engine_kubeconfig_forget lessons                     # ENGINE_SUDO only: kind cleaned root's kubeconfig, not yours
