#!/usr/bin/env bash
# Builds the Pulse image twice (v1 and v2) and loads both into the kind cluster.
# kind nodes can't see images on your machine; 'kind load' copies them in.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

for version in v1 v2; do
  echo "==> Building pulse:$version"
  docker build --build-arg VERSION="$version" -t "pulse:$version" app
done

echo "==> Loading images into kind cluster 'lessons'"
kind load docker-image pulse:v1 pulse:v2 --name lessons
echo "Done. Next: ./capstone/scripts/deploy.sh"
