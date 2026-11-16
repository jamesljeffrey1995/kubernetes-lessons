#!/usr/bin/env bash
# End-to-end check of the lessons: applies each lesson's manifests to the "lessons" cluster
# and verifies the behaviour the lesson describes actually happens. Used by CI; you can run it
# yourself after ./scripts/cluster-up.sh (it takes ~15 minutes and cleans up after itself).
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

if want 15; then
  step "15 kustomize"
  kubectl apply -k $L/15-kustomize/overlays/dev >/dev/null
  kubectl apply -k $L/15-kustomize/overlays/prod >/dev/null
  kubectl -n shop-dev rollout status deploy/whoami --timeout=120s >/dev/null
  kubectl -n shop-prod rollout status deploy/whoami --timeout=120s >/dev/null
  retry 30 "dev overlay: its own name, from a generated ConfigMap" sh -c "kubectl exec toolbox -- curl -sf http://whoami.shop-dev | grep -qx 'Name: dev'"
  retry 30 "prod overlay: its own name" sh -c "kubectl exec toolbox -- curl -sf http://whoami.shop-prod | grep -qx 'Name: prod'"
  if [ "$(kubectl -n shop-prod get deploy whoami -o jsonpath='{.spec.replicas}/{.spec.template.spec.containers[0].resources.limits.memory}')" = "3/64Mi" ]; then ok "prod overlay: 3 replicas and patched resources"; else die "prod overlay: 3 replicas and patched resources"; fi
  if kubectl -n shop-prod get deploy whoami -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}' | grep -qE '^whoami-config-[a-z0-9]{10}$'; then ok "ConfigMap name carries a content hash"; else die "ConfigMap name carries a content hash"; fi
  kubectl delete -k $L/15-kustomize/overlays/dev --wait=false >/dev/null
  kubectl delete -k $L/15-kustomize/overlays/prod --wait=false >/dev/null
fi

if want 16; then
  step "16 scheduling & node maintenance"
  on_node() { kubectl get pods -l "app=$1" --field-selector "spec.nodeName=$2,status.phase=Running" -o name | wc -l | tr -d ' '; }
  kubectl apply -f $L/16-scheduling/spread.yaml >/dev/null
  kubectl rollout status deploy/spread --timeout=120s >/dev/null
  if [ "$(on_node spread lessons-worker)/$(on_node spread lessons-worker2)" = "2/2" ]; then ok "topology spread: 2 Pods on each worker"; else kubectl get pods -l app=spread -o wide; die "topology spread: 2 Pods on each worker"; fi
  kubectl apply -f $L/16-scheduling/pinned.yaml >/dev/null
  retry 30 "nodeSelector without a matching node: Pending" sh -c "kubectl get events | grep -q \"didn't match Pod's node affinity/selector\""
  kubectl label node lessons-worker disktype=ssd --overwrite >/dev/null
  kubectl rollout status deploy/ssd-app --timeout=60s >/dev/null
  if [ "$(on_node ssd-app lessons-worker)" = "1" ]; then ok "labelling a node lets the Pod schedule there"; else die "labelling a node lets the Pod schedule there"; fi
  kubectl taint nodes lessons-worker2 dedicated=batch:NoSchedule --overwrite >/dev/null
  kubectl label node lessons-worker2 dedicated=batch --overwrite >/dev/null
  kubectl apply -f $L/16-scheduling/batch.yaml >/dev/null
  kubectl rollout status deploy/batch --timeout=60s >/dev/null
  if [ "$(on_node batch lessons-worker2)" = "2" ]; then ok "toleration + nodeSelector: batch runs on the tainted node"; else die "toleration + nodeSelector: batch runs on the tainted node"; fi
  kubectl delete -f $L/16-scheduling/batch.yaml -f $L/16-scheduling/pinned.yaml >/dev/null
  kubectl taint nodes lessons-worker2 dedicated=batch:NoSchedule- >/dev/null
  kubectl label node lessons-worker2 dedicated- >/dev/null
  kubectl label node lessons-worker disktype- >/dev/null
  kubectl apply -f $L/16-scheduling/pdb-too-strict.yaml >/dev/null
  if kubectl drain lessons-worker2 --ignore-daemonsets --delete-emptydir-data --force --timeout=20s >/dev/null 2>&1; then
    die "a PDB that allows no disruptions should block the drain"
  fi
  ok "PDB with minAvailable = replicas blocks the drain"
  kubectl apply -f $L/16-scheduling/pdb.yaml >/dev/null
  if kubectl drain lessons-worker2 --ignore-daemonsets --delete-emptydir-data --force --timeout=180s >/dev/null 2>&1; then ok "drain succeeds with a PDB that allows one disruption"; else kubectl get pods -o wide; die "drain succeeds with a PDB that allows one disruption"; fi
  retry 60 "all 4 Pods moved to the other worker" sh -c "[ \"\$(kubectl get pods -l app=spread --field-selector spec.nodeName=lessons-worker,status.phase=Running -o name | wc -l | tr -d ' ')\" = 4 ]"
  kubectl uncordon lessons-worker2 >/dev/null
  kubectl delete -f $L/16-scheduling/spread.yaml -f $L/16-scheduling/pdb.yaml >/dev/null
  # The drain used --force, which deletes bare Pods such as the toolbox.
  kubectl apply -f $L/tools/toolbox.yaml >/dev/null
  kubectl wait --for=condition=Ready pod/toolbox --timeout=120s >/dev/null
fi

if want 17; then
  step "17 debugging"
  kubectl apply -f $L/17-debugging/apps.yaml >/dev/null
  kubectl rollout status deploy/minimal --timeout=120s >/dev/null
  POD=$(kubectl get pod -l app=minimal -o jsonpath='{.items[0].metadata.name}')
  if kubectl exec "$POD" -- sh -c true >/dev/null 2>&1; then die "the minimal image should have no shell"; fi
  ok "exec fails: the image has no shell"
  kubectl debug "$POD" --image=busybox:1.37 --target=app --container=probe -- wget -qO- http://localhost:8080 >/dev/null
  retry 90 "ephemeral container reaches the app on localhost" sh -c "kubectl logs $POD -c probe | grep -q Hostname"
  kubectl debug "$POD" --image=busybox:1.37 --target=app --container=probe2 -- ls /proc/1/root/whoami >/dev/null
  retry 90 "ephemeral container sees the app's filesystem" sh -c "kubectl logs $POD -c probe2 | grep -q whoami"
  retry 90 "crasher logs why it crashes" sh -c "kubectl logs crasher 2>/dev/null | grep -q FATAL || kubectl logs crasher --previous 2>/dev/null | grep -q FATAL"
  kubectl debug crasher --copy-to=crasher-debug --container=app -- sleep 3600 >/dev/null
  if kubectl wait --for=condition=Ready pod/crasher-debug --timeout=90s >/dev/null; then ok "copy of the crashing Pod stays up with another command"; else die "copy of the crashing Pod stays up with another command"; fi
  kubectl debug node/lessons-worker --image=busybox:1.37 -- cat /host/etc/hostname >/dev/null
  retry 90 "node debug Pod reads the node's filesystem" sh -c "kubectl logs \$(kubectl get pods -o name | grep node-debugger | head -n 1) | grep -qx lessons-worker"
  kubectl get pods -o name | grep node-debugger | xargs -r kubectl delete --wait=false >/dev/null
  kubectl delete pod crasher-debug --wait=false >/dev/null
  kubectl delete -f $L/17-debugging/apps.yaml --wait=false >/dev/null
fi

if want 18; then
  step "18 shared clusters"
  kubectl apply -f $L/18-shared-clusters/team.yaml -f $L/18-shared-clusters/app.yaml >/dev/null
  kubectl -n team-payments rollout status deploy/api --timeout=120s >/dev/null
  TOKEN=$(kubectl create token developer -n team-payments --duration=1h)
  kubectl config set-credentials payments-dev --token="$TOKEN" >/dev/null
  kubectl config set-context payments-dev --cluster=kind-lessons --user=payments-dev --namespace=team-payments >/dev/null
  dev() { kubectl --context payments-dev "$@"; }
  if dev auth whoami | grep -q 'system:serviceaccount:team-payments:developer'; then ok "context switches identity"; else die "context switches identity"; fi
  if dev get pods >/dev/null; then ok "developer can list Pods in their namespace"; else die "developer can list Pods in their namespace"; fi
  if dev get secrets >/dev/null 2>&1; then die "developer must not read Secrets"; fi
  ok "developer cannot read Secrets"
  if dev get pods -n kube-system >/dev/null 2>&1; then die "developer must not see other namespaces"; fi
  ok "developer cannot see other namespaces"
  if command -v diff >/dev/null; then
    rc=0; dev diff -f $L/18-shared-clusters/app-change.yaml >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "1" ]; then ok "kubectl diff reports the pending change"; else die "kubectl diff should exit 1 (differences), got $rc"; fi
  fi
  OUT=$(dev apply --dry-run=server -f $L/18-shared-clusters/app-broken.yaml 2>&1 || true)
  if grep -q 'must be less than or equal to memory limit' <<<"$OUT" && grep -q 'Sometimes' <<<"$OUT"; then ok "server-side dry-run catches both mistakes"; else echo "$OUT"; die "server-side dry-run catches both mistakes"; fi
  dev apply -f $L/18-shared-clusters/app-change.yaml >/dev/null
  if dev rollout status deploy/api --timeout=120s >/dev/null; then ok "developer can deploy a change"; else die "developer can deploy a change"; fi
  dev scale deploy/api --replicas=8 >/dev/null
  retry 60 "ResourceQuota stops the namespace at 6 Pods" sh -c "kubectl get events -n team-payments | grep -q 'exceeded quota'"
  kubectl config delete-context payments-dev >/dev/null
  kubectl config unset users.payments-dev >/dev/null
  kubectl delete namespace team-payments --wait=false >/dev/null
fi

if want 19; then
  step "19 observability"
  prom_has() { kubectl exec toolbox -- curl -s -m 5 -G --data-urlencode "query=$1" http://prometheus.monitoring:9090/api/v1/query | grep -q -- "$2"; }
  kubectl apply -f $L/19-observability/prometheus.yaml >/dev/null
  kubectl apply -f $L/19-observability/app.yaml -f $L/19-observability/traffic.yaml >/dev/null
  kubectl -n monitoring rollout status deploy/prometheus --timeout=180s >/dev/null
  kubectl rollout status deploy/shop --timeout=120s >/dev/null
  retry 120 "Prometheus discovers both annotated Pods" prom_has 'count(up{job="pods",app="shop"} == 1)' '"2"\]'
  retry 120 "kubelet container metrics for all 3 nodes" prom_has 'count(up{job="containers"} == 1)' '"3"\]'
  retry 120 "request rate is measured" prom_has 'sum(rate(http_request_duration_seconds_count{app="shop",status="200"}[1m])) > 1' '"result":\[{'
  retry 120 "memory per container is measured" prom_has 'count(container_memory_working_set_bytes{namespace="default",container="podinfo"})' '"2"\]'
  retry 60 "UI reachable through the gateway" sh -c "curl --noproxy '*' -s -m 5 -H 'Host: prometheus.localhost' http://127.0.0.1:8080/-/ready | grep -q Ready"
  if prom_has 'ALERTS{alertname="HighErrorRate",alertstate="firing"}' '"result":\[{'; then die "alert must not fire before the incident"; fi
  kubectl apply -f $L/19-observability/errors.yaml >/dev/null
  retry 240 "HighErrorRate alert fires during the incident" prom_has 'ALERTS{alertname="HighErrorRate",alertstate="firing"}' '"result":\[{'
  kubectl delete -f $L/19-observability/errors.yaml -f $L/19-observability/traffic.yaml -f $L/19-observability/app.yaml --wait=false >/dev/null
  kubectl delete -f $L/19-observability/prometheus.yaml --wait=false >/dev/null
fi

if want 20; then
  step "20 CRDs, operators & policies"
  kubectl apply -f $L/20-extending/crd.yaml >/dev/null
  kubectl wait --for=condition=Established crd/websites.lessons.example.com --timeout=60s >/dev/null
  OUT=$(kubectl apply -f $L/20-extending/website-invalid.yaml 2>&1 || true)
  if grep -q 'less than or equal to 5' <<<"$OUT"; then ok "CRD schema rejects an invalid Website"; else echo "$OUT"; die "CRD schema rejects an invalid Website"; fi
  kubectl apply -f $L/20-extending/website.yaml >/dev/null
  if [ -z "$(kubectl get deploy -l app=website -o name)" ]; then ok "without a controller, a Website is only data"; else die "without a controller, a Website is only data"; fi
  kubectl apply -f $L/20-extending/operator.yaml >/dev/null
  kubectl -n website-operator rollout status deploy/website-operator --timeout=180s >/dev/null
  retry 120 "operator creates the Deployment" kubectl rollout status deploy/site-hello --timeout=5s
  retry 60 "the site serves the Website's title" sh -c "kubectl exec toolbox -- curl -sf http://site-hello | grep -q 'Hello from a custom resource'"
  retry 60 "operator reports status on the Website" sh -c "[ \"\$(kubectl get website hello -o jsonpath='{.status.readyReplicas}')\" = 2 ]"
  kubectl delete deployment site-hello >/dev/null
  retry 60 "operator recreates a deleted Deployment" kubectl get deployment site-hello
  kubectl delete website hello >/dev/null
  retry 60 "deleting the Website garbage-collects what it owned" sh -c "! kubectl get deployment site-hello"
  kubectl apply -f $L/20-extending/policy.yaml >/dev/null
  retry 60 "admission policy denies an unlabelled Deployment" sh -c "kubectl apply --dry-run=server -f $L/20-extending/deploy-unlabelled.yaml 2>&1 | grep -q 'must have a .team. label'"
  if kubectl apply -f $L/20-extending/deploy-labelled.yaml >/dev/null; then ok "labelled Deployment is admitted"; else die "labelled Deployment is admitted"; fi
  kubectl delete namespace strict-team --wait=false >/dev/null
  kubectl delete validatingadmissionpolicybinding require-team-label >/dev/null
  kubectl delete validatingadmissionpolicy require-team-label >/dev/null
  kubectl delete -f $L/20-extending/operator.yaml --wait=false >/dev/null
  kubectl delete -f $L/20-extending/crd.yaml --wait=false >/dev/null
fi

printf '\n\033[1;32mAll lesson checks passed (%d checks).\033[0m\n' "$PASS"
