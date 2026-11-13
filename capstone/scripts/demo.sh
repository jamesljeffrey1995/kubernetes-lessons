#!/usr/bin/env bash
# Guided live demo of Pulse. Open http://pulse.localhost:8080 in a browser next to this
# terminal before you start: every step is visible on the dashboard.
#
# Usage:  ./capstone/scripts/demo.sh            (pauses before each step - for presenting)
#         ./capstone/scripts/demo.sh --auto     (no pauses, checks each step - used by CI)
# Set STRICT_NETPOL=1 to fail if NetworkPolicies aren't enforced (CI does).
# Set SKIP_AUTOSCALE=1 to skip the autoscaling step (e.g. if metrics-server isn't working).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

AUTO=false
[ "${1:-}" = "--auto" ] && AUTO=true
NS=pulse

title() { printf '\n\033[1;35m━━━ %s ━━━\033[0m\n' "$*"; }
say()   { printf '\033[0;36m%s\033[0m\n' "$*"; }
run()   { printf '\033[1;33m$ %s\033[0m\n' "$1"; eval "$1"; }   # takes ONE string (may contain > redirects)
pause() { if ! $AUTO; then read -r -p "↵ Enter to continue..." _; fi; }
fail()  { printf '\033[1;31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# wait_for <timeout-seconds> <description> <command...>: retries until the command succeeds
wait_for() {
  local timeout=$1 desc=$2; shift 2
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    [ $SECONDS -ge $end ] && fail "timed out waiting for: $desc"
    sleep 3
  done
  say "✔ $desc"
}

ready_replicas() { kubectl get deploy pulse -n $NS -o jsonpath='{.status.readyReplicas}'; }
replicas_at_least() { [ "$(ready_replicas)" -ge "$1" ]; }
all_pods_version() {
  local want=$1
  local got
  got=$(kubectl get pods -n $NS -l app.kubernetes.io/component=web -o jsonpath='{.items[*].metadata.labels.app\.kubernetes\.io/version}')
  [ -n "$got" ] && [ "$(echo "$got" | tr ' ' '\n' | sort -u)" = "$want" ]
}

title "0. Starting point: Pulse v1, 3 replicas"
kubectl apply -f k8s/namespace.yaml >/dev/null
run "helm upgrade --install pulse chart/pulse -n $NS --wait --timeout 5m > /dev/null"
run "kubectl get pods -n $NS -o wide"
say "Dashboard: http://pulse.localhost:8080 - every tile is a Pod; the page polls ~3x per second."
pause

title "1. Scaling: 3 → 6 Pods"
say "One value change. New tiles appear on the dashboard within seconds."
run "helm upgrade pulse chart/pulse -n $NS --set replicaCount=6 --wait > /dev/null"
run "kubectl get pods -n $NS -l app.kubernetes.io/component=web -o wide"
wait_for 60 "6 Pods ready" replicas_at_least 6
pause

title "2. Self-healing"
say "2a. Kill ONE Pod (a crash, or a node failure taking out one replica)."
say "    Watch the 'failed' counter on the dashboard: it stays at 0, because the other Pods carry the traffic."
VICTIM=$(kubectl get pods -n $NS -l app.kubernetes.io/component=web -o jsonpath='{.items[0].metadata.name}')
run "kubectl delete pod $VICTIM -n $NS --wait=false"
wait_for 120 "Deployment replaced the Pod" replicas_at_least 6
pause
say "2b. Now the worst case: kill EVERY app Pod at the same time."
say "    Expect a few seconds of failed requests (nothing is Ready until replacements start),"
say "    then full recovery without anyone touching anything."
run "kubectl delete pods -n $NS -l app.kubernetes.io/component=web --wait=false"
run "kubectl get pods -n $NS -l app.kubernetes.io/component=web"
wait_for 120 "Deployment replaced all 6 Pods" replicas_at_least 6
say "The hit counter kept counting: state lives in Redis (a StatefulSet with its own disk), not in the Pods."
say "Real outages look like 2a far more often than 2b, and spreading replicas across nodes and zones keeps it that way."
pause

title "3. Zero-downtime rolling update: v1 (blue) → v2 (green)"
say "Tiles turn green one by one. Pods are replaced gradually, so: 0 failed requests."
run "helm upgrade pulse chart/pulse -n $NS -f values-v2.yaml --wait --timeout 5m > /dev/null"
wait_for 120 "all Pods on v2" all_pods_version v2
run "helm history pulse -n $NS"
pause

title "4. Rollback: back to v1 in one command"
run "helm rollback pulse -n $NS --wait > /dev/null"
wait_for 120 "all Pods back on v1" all_pods_version v1
pause

title "5. Node maintenance: drain a worker node"
REDIS_NODE=$(kubectl get pod pulse-redis-0 -n $NS -o jsonpath='{.spec.nodeName}')
NODE=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}' \
       | tr ' ' '\n' | grep -vx "$REDIS_NODE" | head -n 1)
say "Draining $NODE (the node without Redis: kind's local disks can't move between nodes)."
say "Pods are evicted gracefully and rescheduled; the PodDisruptionBudget keeps at least 1 running."
say "(--force also removes unmanaged Pods, like the lessons' 'toolbox' Pod, from that node.)"
run "kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --force --timeout=180s"
run "kubectl get pods -n $NS -o wide"
wait_for 120 "app still fully available" replicas_at_least 3
run "kubectl uncordon $NODE"
pause

title "6. Security: the namespace rejects unsafe Pods"
say "The 'pulse' namespace enforces the 'restricted' Pod Security Standard. A plain nginx Pod (runs as root):"
ERR_FILE=$(mktemp)
if kubectl run root-test -n $NS --image=nginx:1.29-alpine 2>"$ERR_FILE"; then
  kubectl delete pod root-test -n $NS --wait=false >/dev/null
  fail "an insecure Pod was admitted"
fi
printf '\033[0;31m%s\033[0m\n' "$(cut -c1-220 "$ERR_FILE")"
rm -f "$ERR_FILE"
say "✔ Rejected. Every Pod in the chart passes these rules (non-root, read-only filesystem, no capabilities)."
say ""
say "NetworkPolicies: only the gateway and Pods in this namespace may reach the app; only the app may reach Redis."
say "Trying to reach Redis directly from the 'default' namespace:"
kubectl delete pod netpol-test -n default --ignore-not-found >/dev/null
kubectl run netpol-test -n default --restart=Never --image=busybox:1.37 \
  --command -- sh -c "nc -w 3 pulse-redis-0.pulse-redis.$NS.svc.cluster.local 6379 </dev/null && echo CONNECTED || echo BLOCKED" >/dev/null
wait_for 60 "test Pod finished" sh -c "kubectl get pod netpol-test -n default -o jsonpath='{.status.phase}' | grep -qE 'Succeeded|Failed'"
RESULT=$(kubectl logs netpol-test -n default 2>/dev/null | tail -n 1)
kubectl delete pod netpol-test -n default --wait=false >/dev/null
if [ "$RESULT" = "BLOCKED" ]; then
  say "✔ BLOCKED, as intended."
elif [ "${STRICT_NETPOL:-}" = "1" ]; then
  fail "NetworkPolicy not enforced (got '$RESULT')"
else
  printf '\033[1;33m%s\033[0m\n' "⚠ Got '$RESULT'. Your network plugin may not enforce NetworkPolicies (see lesson 12)."
fi
pause

if [ "${SKIP_AUTOSCALE:-}" = "1" ]; then
  say "Skipping step 7 (autoscaling) because SKIP_AUTOSCALE=1"
else
title "7. Autoscaling: let the HPA decide the replica count"
run "helm upgrade pulse chart/pulse -n $NS -f values-autoscale.yaml --wait > /dev/null"
run "kubectl get hpa -n $NS"
say "Starting a load generator (3 Pods hammering /api/work, which burns CPU)..."
run "kubectl apply -f k8s/load.yaml"
say "Within 1-2 minutes CPU passes the 50% target and the HPA adds Pods (watch new tiles appear)."
wait_for 300 "HPA scaled above 2 replicas" sh -c "[ \"\$(kubectl get hpa pulse -n $NS -o jsonpath='{.status.desiredReplicas}')\" -gt 2 ]"
run "kubectl get hpa -n $NS"
run "kubectl delete -f k8s/load.yaml"
say "Load stopped. The HPA scales back down after its 60s stabilization window."
pause
fi

title "Done"
say "Reset to the starting point any time with: ./capstone/scripts/deploy.sh"
helm upgrade pulse chart/pulse -n $NS --wait > /dev/null
say "(Already reset: v1, 3 replicas, no autoscaling.)"
