#!/usr/bin/env bash
# End-to-end check of the lessons: applies each lesson's manifests to the "lessons" cluster
# and verifies the behaviour the lesson describes actually happens. Used by CI; you can run it
# yourself after ./scripts/cluster-up.sh (it takes ~10 minutes and cleans up after itself).
#
# Options (env vars):  ONLY="05 10"     run only these lessons
#                      SKIP_NETPOL=1    skip NetworkPolicy enforcement checks
#                      SKIP_HPA=1       skip autoscaling checks (need metrics-server)
#                      SKIP_PODINFO=1   skip installing the public podinfo chart (needs ghcr.io)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

L=lessons
PASS=0
step() { printf '\n\033[1;34m=== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔ %s\033[0m\n' "$*"; PASS=$((PASS + 1)); }
die()  { printf '  \033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }
want() { [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $1 "* ]]; }
curl_gw() { curl --noproxy '*' -s -m 5 "$@"; }

# retry <seconds> <description> <cmd...>
retry() {
  local t=$1 d=$2; shift 2
  local end=$((SECONDS + t))
  until "$@" >/dev/null 2>&1; do
    [ $SECONDS -ge $end ] && die "timed out: $d"
    sleep 2
  done
  ok "$d"
}

kubectl apply -f $L/tools/toolbox.yaml >/dev/null
kubectl wait --for=condition=Ready pod/toolbox --timeout=120s >/dev/null

if want 03; then
  step "03 pods"
  kubectl apply -f $L/03-pods/ >/dev/null
  kubectl wait --for=condition=Ready pod/web pod/web-with-sidecar pod/web-with-init --timeout=120s >/dev/null
  if kubectl exec web-with-init -- cat /usr/share/nginx/html/index.html | grep -q "init container"; then ok "init container prepared content"; else die "init container prepared content"; fi
  retry 30 "sidecar writes the page" sh -c "kubectl exec web-with-sidecar -c nginx -- cat /usr/share/nginx/html/index.html | grep -q Hello"
  kubectl delete -f $L/03-pods/ --wait=false >/dev/null
fi

if want 04; then
  step "04 deployments"
  kubectl apply -f $L/04-deployments/deployment.yaml >/dev/null
  if kubectl rollout status deploy/web --timeout=120s >/dev/null; then ok "3 replicas rolled out"; else die "3 replicas rolled out"; fi
  kubectl set image deploy/web nginx=nginx:1.29-alpine >/dev/null
  if kubectl rollout status deploy/web --timeout=120s >/dev/null; then ok "rolling update to 1.29"; else die "rolling update to 1.29"; fi
  kubectl rollout undo deploy/web >/dev/null 2>&1
  if kubectl rollout status deploy/web --timeout=120s >/dev/null; then ok "rollback"; else die "rollback"; fi
  kubectl delete -f $L/04-deployments/deployment.yaml >/dev/null
fi

if want 05; then
  step "05 services"
  kubectl apply -f $L/05-services/ >/dev/null
  kubectl rollout status deploy/whoami --timeout=120s >/dev/null
  retry 30 "ClusterIP Service reachable by DNS name" kubectl exec toolbox -- sh -c "curl -sf http://whoami | grep -q Hostname"
  retry 30 "NodePort reachable on a node" kubectl exec toolbox -- sh -c "curl -sf http://lessons-worker:30080 | grep -q Hostname"
  kubectl delete -f $L/05-services/ >/dev/null
fi

if want 06; then
  step "06 config & secrets"
  kubectl apply -f $L/06-config-secrets/ >/dev/null
  kubectl rollout status deploy/config-demo --timeout=120s >/dev/null
  if [ "$(kubectl exec deploy/config-demo -- printenv GREETING)" = "Hello from a ConfigMap" ]; then ok "ConfigMap env var"; else die "ConfigMap env var"; fi
  if [ "$(kubectl exec deploy/config-demo -- cat /etc/app-secrets/DB_PASSWORD)" = "s3cr3t-for-lessons-only" ]; then ok "Secret mounted as file"; else die "Secret mounted as file"; fi
  if kubectl exec deploy/config-demo -- cat /usr/share/nginx/html/index.html | grep -q "lives in a ConfigMap"; then ok "ConfigMap file mounted"; else die "ConfigMap file mounted"; fi
  kubectl delete -f $L/06-config-secrets/ >/dev/null
fi

if want 07; then
  step "07 namespaces & quotas"
  kubectl apply -f $L/07-namespaces/team-a.yaml -f $L/07-namespaces/app.yaml >/dev/null
  kubectl -n team-a rollout status deploy/web --timeout=120s >/dev/null
  OUT=$(kubectl apply -f $L/07-namespaces/too-big.yaml 2>&1 || true)
  if grep -q "maximum memory usage per Container" <<<"$OUT"; then ok "LimitRange rejects too-big Pod"; else die "LimitRange rejects too-big Pod"; fi
  kubectl -n team-a scale deploy/web --replicas=8 >/dev/null
  retry 30 "ResourceQuota caps Pods at 5" sh -c "kubectl get events -n team-a | grep -q 'exceeded quota'"
  kubectl delete namespace team-a --wait=false >/dev/null
fi

if want 08; then
  step "08 storage"
  kubectl apply -f $L/08-storage/redis-statefulset.yaml >/dev/null
  kubectl rollout status sts/redis --timeout=180s >/dev/null
  retry 60 "Redis accepts writes" sh -c "kubectl exec redis-0 -- redis-cli SET greeting persisted | grep -q OK"
  kubectl delete pod redis-0 >/dev/null
  kubectl wait --for=condition=Ready pod/redis-0 --timeout=120s >/dev/null
  retry 60 "data survives Pod deletion" sh -c "kubectl exec redis-0 -- redis-cli GET greeting | grep -qx persisted"
  kubectl delete -f $L/08-storage/redis-statefulset.yaml >/dev/null
  kubectl delete pvc -l app=redis >/dev/null
fi

if want 09; then
  step "09 health & resources"
  kubectl apply -f $L/09-health-resources/probes.yaml >/dev/null
  kubectl rollout status deploy/whoami --timeout=120s >/dev/null
  POD=$(kubectl get pod -l app=whoami -o jsonpath='{.items[0].metadata.name}')
  IP=$(kubectl get pod "$POD" -o jsonpath='{.status.podIP}')
  kubectl exec toolbox -- curl -s -X POST -d 503 "http://$IP/health" >/dev/null
  if kubectl wait --for=condition=Ready=false "pod/$POD" --timeout=30s >/dev/null; then ok "failing readiness marks Pod unready"; else die "failing readiness marks Pod unready"; fi
  if [ "$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}')" = "0" ]; then ok "...without restarting it"; else die "...without restarting it"; fi
  kubectl apply -f $L/09-health-resources/oom.yaml >/dev/null
  retry 90 "memory hog is OOMKilled" sh -c "kubectl get pod memory-hog -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' | grep -q OOMKilled"
  kubectl delete -f $L/09-health-resources/ --wait=false >/dev/null 2>&1 || true
fi

if want 10; then
  step "10 gateway & ingress"
  kubectl apply -f $L/10-gateway-ingress/ >/dev/null
  kubectl rollout status deploy/blue --timeout=120s >/dev/null
  kubectl rollout status deploy/green --timeout=120s >/dev/null
  retry 30 "host routing (blue.localhost)" sh -c "curl --noproxy '*' -s -m 5 -H 'Host: blue.localhost' http://127.0.0.1:8080 | grep -q BLUE"
  retry 30 "path routing (shop.localhost/green)" sh -c "curl --noproxy '*' -s -m 5 -H 'Host: shop.localhost' http://127.0.0.1:8080/green | grep -q GREEN"
  retry 30 "header routing (x-version: green)" sh -c "curl --noproxy '*' -s -m 5 -H 'Host: shop.localhost' -H 'x-version: green' http://127.0.0.1:8080/ | grep -q GREEN"
  retry 30 "legacy Ingress" sh -c "curl --noproxy '*' -s -m 5 -H 'Host: legacy.localhost' http://127.0.0.1:8080 | grep -q GREEN"
  GREEN=$(for _ in $(seq 1 100); do curl_gw -H 'Host: canary.localhost' http://127.0.0.1:8080; done | grep -c GREEN || true)
  if [ "$GREEN" -ge 2 ] && [ "$GREEN" -le 25 ]; then
    ok "canary weights ~10% green (got $GREEN/100)"
  else
    die "canary split looks wrong: $GREEN/100 green"
  fi
  kubectl delete -f $L/10-gateway-ingress/ >/dev/null
fi

if want 11; then
  step "11 helm"
  if helm lint $L/11-helm/hello >/dev/null; then ok "helm lint"; else die "helm lint"; fi
  helm upgrade --install hello-dev $L/11-helm/hello -n dev --create-namespace -f $L/11-helm/values-dev.yaml --wait >/dev/null
  retry 30 "chart reachable at hello-dev.localhost" sh -c "curl --noproxy '*' -s -m 5 -H 'Host: hello-dev.localhost' http://127.0.0.1:8080 | grep -q hello-DEV"
  if helm upgrade hello-dev $L/11-helm/hello -n dev -f $L/11-helm/values-dev.yaml --set image.tag=v9.9.9 --wait --timeout 30s >/dev/null 2>&1; then
    die "upgrade to a missing image should fail"
  fi
  ok "broken upgrade fails"
  if helm rollback hello-dev 1 -n dev --wait >/dev/null; then ok "helm rollback"; else die "helm rollback"; fi
  helm uninstall hello-dev -n dev >/dev/null
  kubectl delete namespace dev --wait=false >/dev/null
  if [ "${SKIP_PODINFO:-}" != "1" ]; then
    if helm install podinfo oci://ghcr.io/stefanprodan/charts/podinfo -n podinfo --create-namespace --set replicaCount=2 --wait >/dev/null; then ok "public OCI chart (podinfo) installs"; else die "public OCI chart (podinfo) installs"; fi
    helm uninstall podinfo -n podinfo >/dev/null
    kubectl delete namespace podinfo --wait=false >/dev/null
  fi
fi

if want 12; then
  step "12 security"
  kubectl apply -f $L/12-security/namespace.yaml >/dev/null
  OUT=$(kubectl apply -f $L/12-security/insecure-pod.yaml 2>&1 || true)
  if grep -q 'violates PodSecurity' <<<"$OUT"; then ok "restricted namespace rejects root Pod"; else die "restricted namespace rejects root Pod"; fi
  kubectl apply -f $L/12-security/secure-app.yaml >/dev/null
  if kubectl -n secure rollout status deploy/backend --timeout=120s >/dev/null; then ok "hardened app runs under 'restricted'"; else die "hardened app runs under 'restricted'"; fi
  kubectl apply -f $L/12-security/rbac.yaml -f $L/12-security/clients.yaml >/dev/null
  kubectl wait --for=condition=Ready pod/api-client -n secure --timeout=120s >/dev/null
  kubectl wait --for=condition=Ready pod/frontend pod/intruder --timeout=120s >/dev/null
  if [ "$(kubectl exec -n secure api-client -- sh /scripts/call-api.sh /api/v1/namespaces/secure/pods)" = "200" ]; then ok "RBAC allows reading pods"; else die "RBAC allows reading pods"; fi
  if [ "$(kubectl exec -n secure api-client -- sh /scripts/call-api.sh /api/v1/namespaces/secure/secrets)" = "403" ]; then ok "RBAC forbids reading secrets"; else die "RBAC forbids reading secrets"; fi
  if [ "${SKIP_NETPOL:-}" != "1" ]; then
    retry 30 "intruder reaches backend before policy" kubectl exec intruder -- curl -sf -m 3 http://backend.secure
    kubectl apply -f $L/12-security/netpol.yaml >/dev/null
    retry 30 "NetworkPolicy blocks intruder" sh -c "! kubectl exec intruder -- curl -sf -m 3 http://backend.secure"
    retry 30 "NetworkPolicy allows frontend" kubectl exec frontend -- curl -sf -m 3 http://backend.secure
  fi
  kubectl delete -f $L/12-security/clients.yaml --wait=false >/dev/null
  kubectl delete namespace secure --wait=false >/dev/null
fi

if want 13; then
  step "13 jobs & autoscaling"
  kubectl apply -f $L/13-jobs-autoscaling/job.yaml -f $L/13-jobs-autoscaling/failing-job.yaml >/dev/null
  if kubectl wait --for=condition=Complete job/process-items --timeout=180s >/dev/null; then ok "indexed Job completes 6/6"; else die "indexed Job completes 6/6"; fi
  if kubectl wait --for=condition=Failed job/always-fails --timeout=180s >/dev/null; then ok "failing Job hits backoffLimit"; else die "failing Job hits backoffLimit"; fi
  kubectl apply -f $L/13-jobs-autoscaling/cronjob.yaml >/dev/null
  kubectl create job --from=cronjob/report report-manual >/dev/null
  if kubectl wait --for=condition=Complete job/report-manual --timeout=90s >/dev/null; then ok "manual run of a CronJob"; else die "manual run of a CronJob"; fi
  if [ "${SKIP_HPA:-}" != "1" ]; then
    kubectl apply -f $L/13-jobs-autoscaling/autoscale.yaml >/dev/null
    kubectl rollout status deploy/cpu-app --timeout=120s >/dev/null
    kubectl apply -f $L/13-jobs-autoscaling/load.yaml >/dev/null
    retry 300 "HPA scales cpu-app above 1 replica" sh -c "[ \"\$(kubectl get hpa cpu-app -o jsonpath='{.status.desiredReplicas}')\" -gt 1 ]"
  fi
  kubectl delete -f $L/13-jobs-autoscaling/ --wait=false >/dev/null 2>&1 || true
  kubectl delete job report-manual --ignore-not-found --wait=false >/dev/null
fi

if want 14; then
  step "14 troubleshooting (each ticket is broken in the documented way)"
  kubectl apply -f $L/14-troubleshooting/broken/00-namespace.yaml >/dev/null
  kubectl apply -f $L/14-troubleshooting/broken/ >/dev/null
  retry 120 "#1 catalog: image pull error" sh -c "kubectl get pods -n broken -l app=catalog -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' | grep -qE 'ErrImagePull|ImagePullBackOff'"
  retry 120 "#2 orders: crash loop" sh -c "kubectl logs -n broken deploy/orders 2>/dev/null | grep -q 'DATABASE_URL is not set'"
  retry 60 "#3 reports: Pending (insufficient memory)" sh -c "kubectl get events -n broken | grep -q 'Insufficient memory'"
  retry 60 "#4 cart: Service has no endpoints" sh -c "! kubectl exec toolbox -- curl -sf -m 3 http://cart.broken"
  retry 60 "#5 search: connection refused" sh -c "! kubectl exec toolbox -- curl -sf -m 3 http://search.broken"
  retry 60 "#6 payments: readiness 404" sh -c "kubectl get events -n broken | grep -q 'statuscode: 404'"
  retry 60 "#7 emails: missing ConfigMap key" sh -c "kubectl get events -n broken | grep -q 'couldn.t find key SMTP_SERVER'"
  kubectl delete namespace broken --wait=false >/dev/null
fi

printf '\n\033[1;32mAll lesson checks passed (%d checks).\033[0m\n' "$PASS"
