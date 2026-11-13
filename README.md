# Kubernetes, from zero to something you can show at work

A hands-on Kubernetes course that runs entirely on your laptop, on **Windows or Linux**
(macOS works too). It starts at "what is a container?" and ends with a production-style app,
packaged with Helm, secured, autoscaled, tested in CI, and with a live demo script you can
present to your team.

Everything here has been run against a real cluster, and CI re-runs every lesson and the
capstone demo on each change ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

## The path

| # | Lesson | You'll be able to... |
|---|---|---|
| 00 | [Set up your machine](lessons/00-setup/README.md) | Install Docker, kind, kubectl and Helm; create a 3-node cluster |
| 01 | [What Kubernetes actually is](lessons/01-concepts/README.md) | Explain desired state, control loops and the architecture |
| 02 | [kubectl basics](lessons/02-kubectl-basics/README.md) | Find out what's running and why: `get`, `describe`, `logs`, `explain` |
| 03 | [Pods](lessons/03-pods/README.md) | Run containers from YAML; exec, port-forward, sidecars, init containers |
| 04 | [Deployments](lessons/04-deployments/README.md) | Self-healing, scaling, zero-downtime rolling updates, rollbacks |
| 05 | [Services and networking](lessons/05-services/README.md) | Stable names and load balancing; cluster DNS; Service types |
| 06 | [ConfigMaps and Secrets](lessons/06-config-secrets/README.md) | Keep config out of images; what Secrets do and don't protect |
| 07 | [Namespaces, labels, quotas](lessons/07-namespaces/README.md) | Share a cluster safely between teams |
| 08 | [Storage and StatefulSets](lessons/08-storage/README.md) | Keep data across restarts; run Redis properly |
| 09 | [Health checks and resources](lessons/09-health-resources/README.md) | Probes that prevent outages (and the ones that cause them); requests/limits; OOMKilled |
| 10 | [Gateway API and Ingress](lessons/10-gateway-ingress/README.md) | Host/path/header routing; canary releases with traffic weights |
| 11 | [Helm](lessons/11-helm/README.md) | Package an app, deploy per environment, upgrade and roll back |
| 12 | [Security](lessons/12-security/README.md) | RBAC, Pod Security Standards, security contexts, NetworkPolicies |
| 13 | [Jobs, CronJobs, autoscaling](lessons/13-jobs-autoscaling/README.md) | Batch work, schedules, the HorizontalPodAutoscaler |
| 14 | [Troubleshooting](lessons/14-troubleshooting/README.md) | A repeatable method, practised on 7 realistic broken apps |
| 15 | [**Capstone: Pulse**](capstone/README.md) | Build, deploy and **present** a production-style app |

Budget roughly **12-16 hours** for lessons 00-14, at your own pace. Each lesson has exercises
with hidden answers. Try them before peeking.

## Quick start

```bash
git clone <this repo> && cd kubernetes-lessons
```

**Linux / macOS (bash):**
```bash
./scripts/check-prereqs.sh       # are the tools installed?
./scripts/cluster-up.sh          # create the cluster (about 2 minutes)
```

**Windows (PowerShell):**
```powershell
.\scripts\check-prereqs.ps1
.\scripts\cluster-up.ps1
```

Don't have the tools yet? Start at [lesson 00](lessons/00-setup/README.md).

## What you'll have at the end

**Pulse**, a demo app whose dashboard shows, live, which Pod and version answered each
request. Then you scale it, kill Pods, release v2, roll back and drain a node, while a
"failed requests" counter stays at **0**:

```
rolling update v1 -> v2              1833 requests, 0 failed
helm rollback v2 -> v1               1699 requests, 0 failed
one Pod deleted                      1703 requests, 0 failed
worker node drained                  1902 requests, 0 failed
```

It's built the way a real team would build it: a Helm chart with probes, a PodDisruptionBudget,
topology spread, NetworkPolicies, the `restricted` Pod Security Standard, an optional HPA, graceful
shutdown in the app, and CI that deploys it to a real cluster and checks all of the above. The
[capstone README](capstone/README.md) includes a 15-minute presentation outline and honest
answers to the questions colleagues tend to ask.

## How the course stays cross-platform

- **Every Kubernetes command is identical on Windows and Linux.** Manifests live in files, so you `kubectl apply -f` them instead of pasting YAML into shell-specific heredocs.
- When something needs a loop or a variable, it runs **inside the cluster** (`kubectl exec toolbox -- sh -c '...'`), where it's always Linux.
- When the host shell genuinely matters (base64, loops over curl), both **bash** and **PowerShell** versions are given.
- Every script comes in `.sh` and `.ps1` flavours, and CI runs both sets. The `.ps1` files are also checked under Windows PowerShell 5.1.
- `.gitattributes` keeps line endings correct for files that run inside Linux containers.

## Repository layout

```
lessons/            00-14, each with a README and the YAML it uses
lessons/tools/      the 'toolbox' Pod used to test things from inside the cluster
platform/           kind cluster config + pinned Gateway API CRDs, Traefik, metrics-server
scripts/            check-prereqs, cluster-up, cluster-down (.sh and .ps1)
capstone/           the Pulse app, its Helm chart, and demo scripts
tests/              end-to-end checks run by CI (lessons + zero-downtime proof)
```

## Versions used

| Component | Version | Notes |
|---|---|---|
| Kubernetes | 1.37 (kind v0.33.0 default node image) | |
| kubectl | 1.37 (any 1.36-1.38 works) | |
| Helm | 3.22 or 4.x | CI tests both |
| Gateway API | v1.6.3 standard channel | pinned to match Traefik 3.7 |
| Traefik | v3.7.18 | replaces ingress-nginx, which was retired in March 2026 |
| metrics-server | v0.9.1 | |

The platform manifests are vendored (copied into [`platform/`](platform/)) and pinned, so the course
doesn't break when upstream releases something new. To upgrade, replace those files deliberately.

## When something goes wrong

1. Check the troubleshooting table in [lesson 00](lessons/00-setup/README.md#things-that-go-wrong-at-work-and-fixes) (corporate proxies, VPNs, ports, rate limits).
2. Use the method from [lesson 14](lessons/14-troubleshooting/README.md).
3. Still stuck? Delete and recreate the cluster: `./scripts/cluster-down.sh && ./scripts/cluster-up.sh`. It takes two minutes and fixes more than you'd expect.
