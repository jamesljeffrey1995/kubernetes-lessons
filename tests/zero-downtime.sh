#!/usr/bin/env bash
# Proves the capstone's zero-downtime claims: sends requests through the gateway non-stop
# while doing a rolling update, a rollback, a Pod failure and a node drain, and fails if a
# single request fails. Requires Pulse to be deployed (capstone/scripts/deploy.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
NS=pulse
URL=http://127.0.0.1:8080/api/info
LOG=$(mktemp)

# Request loop in the background: one line per request, "200" or the failure code.
hammer() {
  while :; do
    curl --noproxy '*' -s -m 3 -o /dev/null -w '%{http_code}\n' -H 'Host: pulse.localhost' "$URL" || echo "curl-error"
  done >> "$LOG"
}

measure() {
  local name=$1; shift
  : > "$LOG"
  hammer & local pid=$!
  sleep 2
  "$@" >/dev/null 2>&1
  sleep 5
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  local total fails
  total=$(wc -l < "$LOG")
  fails=$(grep -cvx 200 "$LOG" || true)
  printf '%-34s %6d requests, %d failed\n' "$name" "$total" "$fails"
  if [ "$fails" -ne 0 ] || [ "$total" -lt 50 ]; then
    sort "$LOG" | uniq -c
    echo "FAIL: $name"
    exit 1
  fi
}

delete_one_pod() {
  kubectl delete -n $NS "$(kubectl get pods -n $NS -l app.kubernetes.io/component=web -o name | sed -n 1p)"
  kubectl rollout status deploy/pulse -n $NS --timeout=120s
}

drain_worker() {
  local redis_node node
  redis_node=$(kubectl get pod pulse-redis-0 -n $NS -o jsonpath='{.spec.nodeName}')
  node=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}' \
         | tr ' ' '\n' | grep -vx "$redis_node" | sed -n 1p)
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=180s
  kubectl rollout status deploy/pulse -n $NS --timeout=120s
  kubectl uncordon "$node"
}

helm upgrade pulse capstone/chart/pulse -n $NS --wait >/dev/null
measure "rolling update v1 -> v2"   helm upgrade pulse capstone/chart/pulse -n $NS -f capstone/values-v2.yaml --wait --timeout 5m
measure "helm rollback v2 -> v1"    helm rollback pulse -n $NS --wait --timeout 5m
measure "one Pod deleted"           delete_one_pod
measure "worker node drained"       drain_worker
rm -f "$LOG"
echo "PASS: zero failed requests in every scenario"
