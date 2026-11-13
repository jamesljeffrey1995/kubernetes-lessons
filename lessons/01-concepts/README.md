# Lesson 01: What Kubernetes actually is

**Time:** 20 minutes · **Hands-on:** a little · **Goal:** understand *why* Kubernetes exists before typing commands, so the commands make sense.

## Start from the problem

Say you have a web app. To run it in production you need to:

1. Run several copies, so one crash doesn't take the site down.
2. Restart copies that crash, at 3am, without a human.
3. Spread copies across several servers, so one dead server doesn't take the site down.
4. Send traffic only to copies that are healthy.
5. Release a new version without downtime, and roll back if it's broken.
6. Add copies when traffic spikes, and remove them when it drops.
7. Give the app its config and passwords without baking them into the code.

You *can* do all of that with scripts, load balancers and on-call engineers. **Kubernetes is a
system that does all of it for you**, the same way on any cloud or on your laptop.

## Containers in one paragraph

A **container image** is your app plus everything it needs to run (runtime, libraries, config
defaults), packaged into one file-like thing with a name such as `nginx:1.29-alpine`. A
**container** is a running instance of an image. It starts in milliseconds and behaves the same
on every machine. Docker is the most common tool for building and running them.

Try it (same command on Windows and Linux):

```bash
docker run --rm -d -p 9999:80 --name hello nginx:1.29-alpine
```

Open <http://localhost:9999>. You'll see the nginx welcome page, served from a container. Stop it with:

```bash
docker stop hello
```

That's one container on one machine. If it crashes, nothing restarts it. If your laptop dies, it's gone.
Kubernetes is the layer that takes care of containers across *many* machines.

## The single most important idea: desired state

With scripts, you give **instructions**: "start 3 copies".
With Kubernetes, you declare **desired state**: "there should *always be* 3 copies".

You write that down in a YAML file and hand it to Kubernetes. From then on, Kubernetes runs
**control loops** that continuously compare *what is* to *what should be* and fix any
difference:

```
          ┌──────────────────────────────────────────┐
          │                                          │
          ▼                                          │
   Observe actual state ──► Compare with desired ──► Act to close the gap
   ("2 copies running")     ("should be 3")          ("start 1 more")
```

A copy crashes? Actual (2) ≠ desired (3) → start one. A node dies? Its copies vanish → started
elsewhere. You change the YAML to say version 2? → copies are replaced one by one.

**If you remember one thing from this course, make it this.** Almost every Kubernetes behaviour
you'll see is a control loop closing the gap between desired and actual state.

## The architecture

```
                     You
                      │  kubectl apply -f app.yaml
                      ▼
┌─────────────────── CONTROL PLANE (the brain) ───────────────────┐
│                                                                  │
│  API server ◄──── the ONLY front door. Everything talks to it.   │
│      │                                                           │
│  etcd         ◄── database holding all desired + actual state    │
│  scheduler    ◄── decides WHICH node each new Pod runs on        │
│  controller-  ◄── the control loops (Deployments, ReplicaSets,   │
│  manager          Jobs, Nodes...) that close gaps                │
└──────────────────────────────────────────────────────────────────┘
                      │
       ┌──────────────┼──────────────┐
       ▼              ▼              ▼
┌─── NODE ───┐  ┌─── NODE ───┐  ┌─── NODE ───┐   (worker machines)
│ kubelet    │  │ kubelet    │  │ kubelet    │ ◄── agent: "make the Pods assigned
│ container  │  │ container  │  │ container  │      to me actually run"
│  runtime   │  │  runtime   │  │  runtime   │ ◄── containerd: runs containers
│ kube-proxy │  │ kube-proxy │  │ kube-proxy │ ◄── wires up Service networking
│ [Pod][Pod] │  │ [Pod]      │  │ [Pod][Pod] │
└────────────┘  └────────────┘  └────────────┘
```

In your kind cluster, `lessons-control-plane` runs the brain, and `lessons-worker` and
`lessons-worker2` are the worker nodes. In a managed cloud cluster (EKS/AKS/GKE) the
cloud provider runs the control plane for you and you only see the workers.

## The vocabulary you'll meet (in lesson order)

| Object | One-line meaning | Lesson |
|---|---|---|
| **Pod** | The smallest unit: one or more containers that run together on one node | 03 |
| **Deployment** | "Keep N identical Pods running, and roll out new versions safely" | 04 |
| **Service** | A stable name + IP that load-balances to a changing set of Pods | 05 |
| **ConfigMap / Secret** | Configuration and sensitive values, injected into Pods | 06 |
| **Namespace** | A folder for objects, used to separate teams/apps/environments | 07 |
| **PersistentVolumeClaim** | "I need X GB of disk that survives Pod restarts" | 08 |
| **StatefulSet** | Like a Deployment, but for databases: stable names + own disk per Pod | 08 |
| **Probes, requests/limits** | How Kubernetes knows a Pod is healthy and how much CPU/RAM it gets | 09 |
| **Gateway / HTTPRoute / Ingress** | Getting HTTP traffic from outside into Services | 10 |
| **Helm chart** | A packaged, configurable bundle of all the above | 11 |
| **ServiceAccount / Role / NetworkPolicy** | Who can do what, and who can talk to whom | 12 |
| **Job / CronJob / HPA** | Run-to-completion tasks, schedules, autoscaling | 13 |

## Is Kubernetes always the right answer? No.

Being able to say this at work is a sign you actually understand it:

- **It adds real complexity.** For one small app with steady traffic, a managed platform
  (Azure App Service, AWS App Runner/ECS, Google Cloud Run, Heroku-style PaaS) is often cheaper
  and simpler.
- **It shines when** you have many services, several teams, need portability across clouds or
  on-prem, need fine control over rollouts/scaling/networking, or already have a platform team
  running it.
- **"We run Kubernetes" is not free.** Someone must upgrade it (a new minor version roughly every
  4 months, each supported for about 14 months), patch it, secure it and monitor it. Managed
  services (EKS/AKS/GKE) reduce, but don't remove, that work.

## Check your understanding

1. In your own words, what is "desired state"?
2. You `docker run` a container on a server and it crashes. What restarts it? What would restart it in Kubernetes?
3. Which control-plane component decides which node a Pod runs on?
4. Which component on each node actually starts the containers?

<details>
<summary>Answers</summary>

1. A declaration of what *should* exist (e.g. "3 copies of version 2"). Kubernetes continuously works to make reality match it.
2. Nothing (unless you set a Docker restart policy, and even then not if the server dies). In Kubernetes, the kubelet restarts crashed containers, and the Deployment/ReplicaSet controller replaces Pods that disappear, on another node if needed.
3. The scheduler.
4. The kubelet, which tells the container runtime (containerd) what to run.
</details>

---

**Next:** [Lesson 02: Talking to the cluster with kubectl](../02-kubectl-basics/README.md)
