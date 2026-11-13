# Lesson 14: Troubleshooting

**Time:** 60-90 minutes · **Goal:** a repeatable method for "it's broken", practised on seven
realistic support tickets.

Being calm and methodical when something is broken is the skill people notice most at work.
Kubernetes is very good at *telling* you what's wrong. You just need to know where to look.

## The method

Work **top-down** from what the user sees, or **bottom-up** from the Pods. Either way, you only
need a handful of commands:

```
1. kubectl get pods -n <ns>                        What state are the Pods in?
2. kubectl describe pod <pod> -n <ns>              WHY? Read "Events" at the bottom. Also "Last State".
3. kubectl logs <pod> -n <ns> [--previous]         What did the app say? (--previous = before the last crash)
4. kubectl get endpointslices -n <ns>              Does the Service have Pods behind it?
5. kubectl get events -n <ns> --sort-by=.lastTimestamp    Everything that happened recently, in order
```

### Pod status → where to look

| You see | It means | Look at |
|---|---|---|
| `Pending` | Not scheduled to a node | `describe pod` → Events: `FailedScheduling` (resources, taints, node selectors, PVC) |
| `ContainerCreating` (stuck) | Scheduled, can't start | `describe pod` → Events: volume mounts, Secrets/ConfigMaps missing, image pulling |
| `ErrImagePull` / `ImagePullBackOff` | Can't get the image | Typo in name/tag, private registry needs `imagePullSecrets`, rate limits, proxy |
| `CreateContainerConfigError` | Config reference broken | `describe pod`: missing ConfigMap/Secret **or key** |
| `CrashLoopBackOff` / `Error` | App starts then exits | `logs --previous`. It's usually the app's own error message |
| `OOMKilled` (exit 137) | Exceeded memory limit | Raise the limit or fix the leak (lesson 09) |
| `Running` but `0/1 READY` | Readiness probe failing | `describe pod` → `Unhealthy` events, probe path/port |
| `Running`, `1/1`, but unreachable | Networking | Service selector → endpoints → `targetPort` → NetworkPolicy → route |
| `Terminating` (stuck) | Finalizer waiting, or node gone | `kubectl get pod -o yaml` → `finalizers`; is the node `NotReady`? |

### Service not working? Walk the chain

```
Gateway/HTTPRoute ──► Service ──► EndpointSlice ──► Pod (Ready?) ──► container port
     │                   │              │                  │                │
 describe httproute   selector      empty? =        readiness        targetPort matches
 (Accepted? Resolved?) matches      selector or     probe passing?   what the app
                       Pod labels?  readiness                         listens on?
```

Test each hop from inside the cluster with the toolbox (`kubectl apply -f lessons/tools/toolbox.yaml`):

```bash
kubectl exec toolbox -- curl -s -m 3 http://<service>.<namespace>        # via the Service
kubectl exec toolbox -- curl -s -m 3 http://<pod-ip>:<port>              # straight to a Pod, skipping the Service
```

If the Pod IP works but the Service doesn't, the problem is the Service (selector or ports).
If neither works, it's the app or its port.

## The seven tickets

Deploy all seven broken apps into a namespace called `broken`:

```bash
kubectl apply -f lessons/14-troubleshooting/broken/00-namespace.yaml
kubectl apply -f lessons/14-troubleshooting/broken/
kubectl apply -f lessons/tools/toolbox.yaml
```

Give it 30 seconds, then:

```bash
kubectl get pods -n broken
```

Each file in [`broken/`](broken/) starts with the ticket as a user would report it. For each one:
**diagnose with kubectl first** (don't just read the YAML!), then fix the YAML file and re-apply it.

| # | File | Ticket |
|---|---|---|
| 1 | `01-catalog.yaml` | "The catalog service never starts." |
| 2 | `02-orders.yaml` | "Orders keeps restarting." |
| 3 | `03-reports.yaml` | "Deployed an hour ago and there's still nothing running." |
| 4 | `04-cart.yaml` | "Pods are healthy, but nothing can reach `http://cart.broken`." |
| 5 | `05-search.yaml` | "`http://search.broken` gives 'connection refused', but Pods look fine and the Service has endpoints." |
| 6 | `06-payments.yaml` | "The rollout is stuck and new Pods say 0/1 READY." |
| 7 | `07-emails.yaml` | "Stuck in some config error state." |

Try them all before opening the hints. Open the hint before the answer.

<details>
<summary>Hint 1</summary>

`kubectl describe pod -n broken -l app=catalog` → Events. Read the image name very carefully.
</details>
<details>
<summary>Answer 1</summary>

`ImagePullBackOff`. The event says `failed to resolve reference "docker.io/library/ngnix:1.29-alpine"`.
**ngnix** is a typo for **nginx**. Fix the image name. Real-world variants: a tag that was never
pushed, a private registry without `imagePullSecrets`, or a registry blocked by a corporate proxy.
</details>

<details>
<summary>Hint 2</summary>

`kubectl logs -n broken deploy/orders`. If it already restarted, add `--previous`.
</details>
<details>
<summary>Answer 2</summary>

`CrashLoopBackOff`. The logs say `FATAL: DATABASE_URL is not set`. The Deployment sets
`DATABASE_HOST`, but the app reads `DATABASE_URL`. Kubernetes did its job: the container kept
exiting with code 1, and it kept restarting it with back-off. Rename the variable to `DATABASE_URL`
with a value like `postgres://postgres.broken.svc:5432/orders`. **Lesson: for CrashLoopBackOff, the answer is almost always in the logs.**
</details>

<details>
<summary>Hint 3</summary>

`kubectl describe pod -n broken -l app=reports` → `FailedScheduling`.
</details>
<details>
<summary>Answer 3</summary>

`Pending`: `0/3 nodes are available: ... 2 Insufficient memory`. It requests `64Gi` of memory
(probably meant `64Mi`). No node is that big, so it will never be scheduled. Fix the request.
</details>

<details>
<summary>Hint 4</summary>

`kubectl get endpointslices -n broken`. Compare `kubectl get svc cart -n broken -o yaml` (selector)
with `kubectl get pods -n broken --show-labels`.
</details>
<details>
<summary>Answer 4</summary>

The Service selects `app: cart`, but the Pods are labelled `app: cart-service`. The endpoint list
is empty. Change the Service's selector to `app: cart-service` (don't change the Deployment's
selector, which is immutable; you'd have to recreate the Deployment).
</details>

<details>
<summary>Hint 5</summary>

The Service has endpoints, so the selector is fine. Look at the **port numbers** on the endpoints, and what nginx listens on.
`kubectl exec toolbox -- curl -s -m 3 http://<one-pod-ip>:80` vs `:8080`.
</details>
<details>
<summary>Answer 5</summary>

The Service's `targetPort` is `8080`, but nginx listens on `80`. Traffic is sent to a port
nothing listens on, so it's refused. Set `targetPort: 80`. Better still, name the container
port (`name: http`) and use `targetPort: http`, so this mistake can't happen.
</details>

<details>
<summary>Hint 6</summary>

`kubectl describe pod -n broken -l app=payments` → `Unhealthy` events. What path does the probe use? Does nginx serve that path?
</details>
<details>
<summary>Answer 6</summary>

`Readiness probe failed: HTTP probe failed with statuscode: 404`. The probe checks `/healthz`,
which stock nginx doesn't have. The Pods run but never become Ready, so they get no traffic and the rollout
never completes. Point the probe at a path that exists (`/`), or add a real health endpoint to the app.
(In a real v1→v2 release, the v1 Pods would keep serving the whole time. Readiness
protected you from shipping a broken release.)
</details>

<details>
<summary>Hint 7</summary>

`kubectl describe pod -n broken -l app=emails`, then `kubectl get configmap emails-config -n broken -o yaml`.
</details>
<details>
<summary>Answer 7</summary>

`CreateContainerConfigError: couldn't find key SMTP_SERVER in ConfigMap broken/emails-config`.
The ConfigMap has `SMTP_HOST`, not `SMTP_SERVER`. Change the `key:` to `SMTP_HOST` (or add the
key to the ConfigMap). If a missing key should be tolerated, `configMapKeyRef` has `optional: true`.
</details>

Check you fixed everything:

```bash
kubectl get pods -n broken                          # all Running and READY
kubectl exec toolbox -- curl -s -o /dev/null -w "%{http_code}\n" http://cart.broken
kubectl exec toolbox -- curl -s -o /dev/null -w "%{http_code}\n" http://search.broken
```

Clean up: `kubectl delete namespace broken`.

## More tools for your belt

### Debug containers without a shell: `kubectl debug`

Good production images are minimal and often have **no shell** (the `cart` app is one):

```bash
kubectl exec -n broken deploy/cart -- sh
# exec: "sh": executable file not found in $PATH
```

`kubectl debug` attaches a temporary **ephemeral container** with your tools, sharing the Pod's
network and (with `--target`) its process list:

```bash
kubectl debug -it -n broken <cart-pod-name> --image=busybox:1.37 --target=web -- sh
```

Inside: `wget -qO- localhost:80`, `ps` (you'll see `/whoami` as PID 1), `netstat -tlnp`.

Debug a **node** (opens a shell with the node's filesystem at `/host`):

```bash
kubectl debug node/lessons-worker -it --image=busybox:1.37
```

### Watch things change

```bash
kubectl get pods -n <ns> -w
kubectl get events -A --watch
kubectl logs -f deploy/<name> --all-containers --prefix
kubectl logs -n <ns> -l app=<label> --prefix --tail=20    # logs from several Pods at once
```

### Know what changed

Most incidents follow a change. `kubectl rollout history deploy/<name>`, `helm history <release>`,
and your Git log are the first places to look.

### Real gotchas you'll eventually meet

- **Namespace stuck in `Terminating`.** Usually an *aggregated API* that's down (most often
  metrics-server): the namespace controller can't confirm everything was deleted.
  `kubectl get namespace <ns> -o yaml` → `status.conditions` names the culprit
  (`DiscoveryFailed ... metrics.k8s.io`). Fix that API and the namespace finishes deleting.
- **"It works with `kubectl port-forward` but not through the Gateway"**: `port-forward` skips
  Services, routes *and* NetworkPolicies, so it proves only that the Pod works.
- **Changes "not applied"**: you edited the wrong context/namespace. Check `kubectl config current-context`.
- **Image updated but Pods still run the old code**: you reused a tag (e.g. `:latest` or `:v1`) and
  nodes cached the old image. Use unique tags per build (e.g. the Git commit SHA).
- **Everything restarts at once when a dependency blips**: liveness probe checks a dependency (lesson 09).
- **Pod evicted** (`Evicted` status): the node ran low on memory or disk. `describe` says which. Set requests properly.

### Visual tools

- **[k9s](https://k9scli.io/)**: a terminal UI for Kubernetes. Hugely popular, works on Windows and Linux. Highly recommended once you know the kubectl basics.
- **[Headlamp](https://headlamp.dev/)**: a desktop/web UI (a Kubernetes SIG project).
- **Lens / FreeLens**: desktop IDEs for clusters.

---

**Next:** [Lesson 15: Capstone project](../../capstone/README.md)
