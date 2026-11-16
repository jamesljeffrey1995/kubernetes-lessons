#!/usr/bin/env bash
# Builds the Pulse image twice (v1 and v2) and copies both into the kind cluster.
# kind nodes can't see images on your machine, so they have to be loaded into each node.
#
# Works with Docker and Podman. It deliberately does NOT use 'kind load docker-image': that
# command always calls the 'docker' binary (even with the Podman provider), and can fail with
# Docker's containerd image store. Saving to a tar file and loading that works everywhere.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Sets CTR (docker or podman) and KIND_EXPERIMENTAL_PROVIDER when Podman is in use.
# shellcheck source=scripts/engine.sh
source ../scripts/engine.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for version in v1 v2; do
  # The full name matters with Podman, which would otherwise call the image 'localhost/pulse'.
  # Kubernetes reads 'pulse:v1' as 'docker.io/library/pulse:v1', so that's the name we build.
  image="docker.io/library/pulse:$version"
  echo "==> Building pulse:$version"
  "$CTR" build --build-arg VERSION="$version" -t "$image" app
  "$CTR" save -o "$TMP/pulse-$version.tar" "$image"
done

echo "==> Loading images into kind cluster 'lessons'"
for version in v1 v2; do
  kind load image-archive "$TMP/pulse-$version.tar" --name lessons
done
echo "Done. Next: ./capstone/scripts/deploy.sh"
