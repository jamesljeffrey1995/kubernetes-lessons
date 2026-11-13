#!/usr/bin/env bash
# Checks that the tools this course needs are installed and Docker is running.
set -uo pipefail

ok=0
check() {
  local name=$1; shift
  if out=$("$@" 2>/dev/null | head -n 1) && [ -n "$out" ]; then
    printf '  \033[32m✔\033[0m %-8s %s\n' "$name" "$out"
  else
    printf '  \033[31m✘\033[0m %-8s not found or not working\n' "$name"
    ok=1
  fi
}

echo "Checking prerequisites..."
check docker  docker --version
check kind    kind version
check kubectl kubectl version --client
check helm    helm version --short
check git     git --version

if docker info >/dev/null 2>&1; then
  printf '  \033[32m✔\033[0m %-8s %s\n' "daemon" "Docker is running"
else
  printf '  \033[31m✘\033[0m %-8s %s\n' "daemon" "Docker is not running (start Docker Desktop, or: sudo systemctl start docker)"
  ok=1
fi

echo
if [ $ok -eq 0 ]; then
  echo "All good. Next: ./scripts/cluster-up.sh"
else
  echo "Fix the items marked ✘ (see lessons/00-setup/README.md), then re-run this script."
fi
exit $ok
