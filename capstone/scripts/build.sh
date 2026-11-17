#!/usr/bin/env bash
# Builds the Pulse image twice (v1 and v2) and makes it available to the cluster.
#
# Where the images go is chosen with PULSE_IMAGE:
#   unset (default)     copy both images into the kind cluster. No registry needed.
#   PULSE_IMAGE=REPO    push both images to a registry, e.g. PULSE_IMAGE=ghcr.io/you/pulse.
#                       deploy.sh must then be run with the same PULSE_IMAGE.
#                       For a private registry, log in first:  $CTR login ghcr.io
#
# kind nodes can't see images on your machine, so local images have to be loaded into each node.
#
# Works with Docker and Podman. It deliberately does NOT use 'kind load docker-image': that
# command always calls the 'docker' binary (even with the Podman provider), and can fail with
# Docker's containerd image store. Saving to a tar file and loading that works everywhere.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Sets CTR (docker or podman) and KIND_EXPERIMENTAL_PROVIDER when Podman is in use. With
# ENGINE_SUDO=1, '$CTR' and 'kind' below run as root: root's engine has its own image store, and
# that is the one the cluster's nodes live in.
# shellcheck source=scripts/engine.sh
source ../scripts/engine.sh

REPO="${PULSE_IMAGE:-}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for version in v1 v2; do
  # The full name matters with Podman, which would otherwise call the image 'localhost/pulse'.
  # Kubernetes reads 'pulse:v1' as 'docker.io/library/pulse:v1', so that's the default name.
  image="${REPO:-docker.io/library/pulse}:$version"
  echo "==> Building $image"
  "$CTR" build --build-arg VERSION="$version" -t "$image" app
  if [ -z "$REPO" ]; then
    "$CTR" save -o "$TMP/pulse-$version.tar" "$image"
  else
    echo "==> Pushing $image"
    "$CTR" push "$image" || {
      echo "Push failed. For a private registry, log in first: $CTR login ${REPO%%/*}" >&2
      exit 1
    }
  fi
done

if [ -z "$REPO" ]; then
  echo "==> Loading images into kind cluster 'lessons'"
  for version in v1 v2; do
    kind load image-archive "$TMP/pulse-$version.tar" --name lessons
  done
  echo "Done. Next: ./capstone/scripts/deploy.sh"
else
  echo "Done. Next: PULSE_IMAGE=$REPO ./capstone/scripts/deploy.sh"
fi
