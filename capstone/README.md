# Lesson 15 / Capstone: Pulse, a production-style app you can demo at work

**Time:** 1-2 hours to build and understand, 15 minutes to present.

**Pulse** is a small web app built to make Kubernetes *visible*. Its dashboard polls the app
several times a second and shows which Pod, version and node served each request, a shared hit
counter stored in Redis, and a live count of failed requests. Scale it, break it, upgrade it,
drain a node, and everyone in the room can *see* what Kubernetes is doing.

```
 Browser ──► localhost:8080 ──► Traefik (Gateway API) ──► Service "pulse" ──► Pulse Pods (3+, spread over nodes)
                                                                                    │
                                                                                    ▼
                                                                    Redis StatefulSet + PersistentVolume
```

Everything in lessons 01-14 shows up here, put together the way a real team would:

| Feature | Where | Lesson |
|---|---|---|
| Stateless app in a Deployment, rolling updates with `maxUnavailable: 0` | `chart/pulse/templates/deployment.yaml` | 04 |
| Service + Gateway API `HTTPRoute` | `service.yaml`, `httproute.yaml` | 05, 10 |
| Config via ConfigMap; a config change auto-restarts Pods (checksum annotation) | `configmap.yaml` | 06 |
| Namespace enforcing the `restricted` Pod Security Standard | `k8s/namespace.yaml` | 07, 12 |
| Redis in a StatefulSet with a PersistentVolumeClaim | `redis.yaml` | 08 |
| Startup, readiness and liveness probes, done *correctly* | `deployment.yaml`, `app/main.go` | 09 |
| Requests/limits, no CPU limit on the app | `values.yaml` | 09 |
| Graceful shutdown for truly zero-downtime deploys | `app/main.go` | 09 |
| Packaged as a Helm chart with a values schema and `helm test` | `chart/pulse/` | 11 |
| Non-root, read-only filesystem, no capabilities, no API token | every template | 12 |
| NetworkPolicies: only the gateway reaches the app; only the app reaches Redis | `networkpolicy.yaml` | 12 |
| HorizontalPodAutoscaler (optional) | `hpa.yaml`, `values-autoscale.yaml` | 13 |
| PodDisruptionBudget, topology spread across nodes | `pdb.yaml`, `deployment.yaml` | 04, 13 |
| Multi-stage Docker build → ~15 MB distroless image, no shell | `app/Dockerfile` | - |
| CI: builds, deploys to a real cluster and proves zero downtime on every push | `.github/workflows/ci.yml` | - |

## 1. Build, deploy, open

Your cluster from lesson 00 must be running (`./scripts/cluster-up.sh` / `.\scripts\cluster-up.ps1`).

**bash:**
```bash
./capstone/scripts/build.sh      # docker build pulse:v1 and pulse:v2, kind load into the cluster
./capstone/scripts/deploy.sh     # namespace + helm upgrade --install + helm test
```

**PowerShell:**
```powershell
.\capstone\scripts\build.ps1
.\capstone\scripts\deploy.ps1
```

Open **<http://pulse.localhost:8080>**.

Each coloured tile is a Pod. The big panel shows which Pod answered the latest request, and the
"failed" counter is the number to watch in every step that follows.

Why `kind load`? kind's nodes are containers with their own image store; they can't see images
you built on your machine. On a real cluster you'd push to a registry (ECR, ACR, GHCR, Harbor)
instead, and the chart's `image.repository` would point there.

## 2. Run the guided demo

```bash
./capstone/scripts/demo.sh          # bash
.\capstone\scripts\demo.ps1         # PowerShell
```

Put the browser and the terminal side by side. The script shows each command before running
it and waits for **Enter** between steps:

| Step | What you do | What the room sees |
|---|---|---|
| 1. Scale | `helm upgrade --set replicaCount=6` | 3 new tiles appear, spread across nodes |
| 2a. Self-heal | Delete one Pod | A tile vanishes, a new one appears. **0 failed requests** |
| 2b. Worst case | Delete *every* Pod at once | ~2-4 s of failures, then full recovery with nobody touching anything. Hit counter intact (Redis) |
| 3. Release v2 | `helm upgrade -f values-v2.yaml` | Tiles turn blue → green one at a time. **0 failed requests** |
| 4. Rollback | `helm rollback` | Back to blue in seconds. **0 failed requests** |
| 5. Node maintenance | `kubectl drain <node>` | Pods move off the node. **0 failed requests** |
| 6. Security | Try to run a root Pod; reach Redis from another namespace | Both **blocked** |
| 7. Autoscaling | Turn on the HPA, start a load generator | Tiles multiply as CPU rises |

Run `./capstone/scripts/demo.sh --auto` for a non-stop run (that's what CI does), or
`SKIP_AUTOSCALE=1` / `-SkipAutoscale` if metrics-server isn't available.

### These claims are tested, not hoped for

[`tests/zero-downtime.sh`](../tests/zero-downtime.sh) fires requests through the gateway
non-stop during each scenario and fails on a single error. A run while writing this course:

```
rolling update v1 -> v2              1833 requests, 0 failed
helm rollback v2 -> v1               1699 requests, 0 failed
one Pod deleted                      1703 requests, 0 failed
worker node drained                  1902 requests, 0 failed
PASS: zero failed requests in every scenario
```

CI runs this on every push.

## 3. How the zero downtime actually works

This is the part that impresses experienced engineers, because most demos skip it and get errors.
When a Pod is deleted, two things happen **at the same time**:

1. the kubelet sends the container `SIGTERM`,
2. the endpoint controller starts removing the Pod from the Service. That change takes a moment
   to reach every node and the gateway.

If the app exits immediately on `SIGTERM`, requests still routed to it in that window fail.
Pulse ([`app/main.go`](app/main.go)) handles it properly:

- on `SIGTERM` it starts failing `/readyz`, but **keeps serving** for `shutdownDelay` (5s),
- then it stops accepting new connections and finishes in-flight requests (`http.Server.Shutdown`),
- `terminationGracePeriodSeconds: 30` gives it room to do all of that.

Add `maxUnavailable: 0` (never fewer ready Pods than desired) and a readiness probe (traffic only
reaches Pods that are ready), and rolling updates, rollbacks and drains lose nothing.

And **why step 2b fails briefly**: deleting *every* Pod marks them all as terminating at once.
Kubernetes stops routing to terminating Pods, and the replacements need a second or two to start.
For those seconds nothing is Ready. That's honest behaviour. It's why real setups spread replicas
across nodes and zones (so one failure never takes all of them), and why `PodDisruptionBudgets`
stop maintenance from evicting too many at once.

### Probe design (lesson 09 applied)

| Probe | Endpoint | Checks | Why |
|---|---|---|---|
| startup | `/healthz` | process answers | Holds off the other probes during start-up |
| readiness | `/readyz` | not shutting down | Removes the Pod from traffic during shutdown |
| liveness | `/healthz` | process answers | Restarts a hung process |

Neither checks Redis. If Redis goes down, Pulse keeps serving and shows "Redis unavailable" on
the dashboard. Had readiness checked Redis, a Redis blip would mark *every* Pod unready, which
turns a degraded feature into a full outage. Try it:

```bash
kubectl scale statefulset pulse-redis -n pulse --replicas=0     # dashboard: Redis unavailable, app still up
kubectl scale statefulset pulse-redis -n pulse --replicas=1     # counter continues where it left off
```

## 4. Things to explore on your own

```bash
helm test pulse -n pulse --logs                                    # the chart's built-in self-test
kubectl get all,pdb,networkpolicy,httproute,pvc -n pulse           # everything the chart created
helm get manifest pulse -n pulse                                   # the exact YAML applied
kubectl exec -n pulse deploy/pulse -- sh                           # fails: distroless image has no shell
kubectl port-forward -n pulse svc/pulse 8081:80                    # then open http://localhost:8081/metrics
helm upgrade pulse capstone/chart/pulse -n pulse --set app.color=purple   # rejected by values.schema.json
helm upgrade pulse capstone/chart/pulse -n pulse --set app.color="#9333ea" --set app.message="Live demo!"
```

The last one changes only the ConfigMap, yet triggers a rolling restart, because of the
`checksum/config` annotation on the Pod template.

## 5. Presenting it at work

A 15-minute structure that works:

1. **The problem (2 min).** "Running an app is easy. Keeping it running through crashes,
   releases, traffic spikes and server maintenance is the hard part. Here's how Kubernetes does it."
2. **The picture (1 min).** The architecture diagram at the top of this file: browser → gateway → Service → Pods → Redis.
3. **Live demo (8 min).** `demo.sh`, steps 1-5. Keep pointing at the **failed requests counter**.
   Step 2b is worth keeping: showing the one case that *does* blip, and explaining why, builds more
   trust than pretending nothing ever fails.
4. **How it's built (3 min).** Open `chart/pulse/templates/deployment.yaml`: probes, `maxUnavailable: 0`,
   security context, topology spread. Then the graceful shutdown in `main.go`. Then the CI workflow:
   "every change is deployed to a real cluster and tested for downtime automatically."
5. **What it would take for real (1 min):** see the next section.

**Before you present:** run `./capstone/scripts/deploy.sh` to reset, open the dashboard, set the
browser zoom so the tiles are visible from the back of the room, and close other heavy apps
(the cluster needs ~3 GB of RAM). Have a backup screen recording in case the VPN, Wi-Fi or laptop misbehaves.

**Questions you're likely to get, with honest answers:**

- *"Would we run Redis/our database like this in production?"* Probably not. A managed service
  (ElastiCache, Azure Cache, Memorystore, RDS...) or an operator gives you backups, failover and
  patching. The StatefulSet here shows the concepts.
- *"How would this run on EKS/AKS/GKE?"* The chart is unchanged. Differences: push the image to
  a registry, use the cloud's Gateway implementation (or install Traefik/Envoy Gateway), add TLS
  via cert-manager, use a cloud StorageClass, and turn on cluster autoscaling.
- *"What about monitoring?"* Pulse exposes Prometheus metrics at `/metrics`. Next step: install
  kube-prometheus-stack and add a `ServiceMonitor`.
- *"How do deployments happen?"* Here, CI runs `helm upgrade`. Many teams use GitOps instead:
  Argo CD or Flux sync the cluster from Git, and every change is a pull request.
- *"Is Kubernetes worth it for us?"* See lesson 01's honest answer. It depends on the number of
  services, teams and the operational skills available.

## 6. Make it yours (ideas that also make great portfolio pieces)

1. **Push to a registry** (GitHub Container Registry is free) and change `image.repository`.
2. **Add Prometheus + Grafana** (`kube-prometheus-stack` Helm chart), scrape `/metrics`, and graph
   request rate and errors during a rolling update.
3. **GitOps**: install Argo CD, point it at this repo's chart, and deploy by merging pull requests.
4. **Canary release** with weighted `HTTPRoute` backends (lesson 10): run v1 and v2 as two releases and shift traffic 90/10 → 50/50 → 0/100.
5. **Run it on a real cloud**: a small AKS/EKS/GKE cluster for an afternoon costs a few dollars. Delete it afterwards!
6. **Replace Redis with a managed service** via `--set redis.enabled=false --set redis.externalAddr=host:6379`.

## Clean up

```bash
./capstone/scripts/cleanup.sh       # bash
.\capstone\scripts\cleanup.ps1      # PowerShell
```

## Files

```
capstone/
├── app/                    Go source (standard library only), Dockerfile, unit tests
├── chart/pulse/            Helm chart (templates, values.yaml, values.schema.json, helm test)
├── k8s/                    namespace (Pod Security), load generator
├── values-v2.yaml          "release 2": new image tag + colour
├── values-autoscale.yaml   switch on the HPA
└── scripts/                build / deploy / demo / cleanup, in .sh and .ps1
```
