# Lesson 02: Talking to the cluster with kubectl

**Time:** 30 minutes · **Goal:** get comfortable asking the cluster questions. Most of your
time with Kubernetes is spent *looking* at things, not creating them.

Make sure your cluster is running (`kubectl get nodes` shows 3 `Ready` nodes). If not, run
`./scripts/cluster-up.sh` or `.\scripts\cluster-up.ps1` from the repo root.

> **Every `kubectl` command in this course is identical on Windows and Linux.** Where the
> *surrounding* shell differs (loops, variables, base64), both versions are shown.

## 1. Which cluster am I talking to?

kubectl can know about many clusters (your laptop, dev, prod...). Each is a **context**.

```bash
kubectl config get-contexts
kubectl config current-context
```

```
CURRENT   NAME           CLUSTER        AUTHINFO       NAMESPACE
*         kind-lessons   kind-lessons   kind-lessons
```

The `*` marks the active one. These are stored in your **kubeconfig** file:
`~/.kube/config` on Linux, `%USERPROFILE%\.kube\config` on Windows.

> ⚠️ **Work habit worth forming now:** before running anything that changes things, check
> `kubectl config current-context`. People have deleted production resources because they
> thought they were pointed at their laptop. Many engineers show the context in their shell
> prompt for this reason.

To switch: `kubectl config use-context kind-lessons`.

## 2. The cluster and its nodes

```bash
kubectl cluster-info
kubectl get nodes
kubectl get nodes -o wide
```

`-o wide` adds columns (internal IP, OS, container runtime). Now look at one node in depth:

```bash
kubectl describe node lessons-worker
```

`describe` is your best friend. Scroll through and find:
- **Capacity / Allocatable:** how much CPU and memory the node offers.
- **Non-terminated Pods:** what's running on it.
- **Events** at the bottom: what happened recently. **This is the first place to look when something is wrong.**

## 3. The get / describe / logs pattern

Almost every investigation looks like this:

| Command | Answers |
|---|---|
| `kubectl get <type>` | What exists? Is it healthy? (summary table) |
| `kubectl describe <type> <name>` | Details + recent events: *why* is it in this state? |
| `kubectl logs <pod>` | What did the app itself say? |
| `kubectl get <type> <name> -o yaml` | The full object exactly as Kubernetes stores it |

Try them on what's already running. Kubernetes runs its *own* components as Pods too:

```bash
kubectl get pods -A
```

`-A` means "all namespaces". You'll see `kube-system` (Kubernetes' own parts: DNS, proxy,
API server...), `traefik` (our front door, used in lesson 10) and `local-path-storage` (disks,
lesson 08). Namespaces get a whole lesson later. For now, treat them as folders.

```bash
kubectl get pods -n kube-system
kubectl describe pod -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=5
```

`-l k8s-app=kube-dns` selects by **label**. Labels are how Kubernetes groups things (lesson 05).

## 4. Your first Pod (the quick, imperative way)

```bash
kubectl run first --image=nginx:1.29-alpine
kubectl get pods
```

Run `kubectl get pods` a few times. You'll see `ContainerCreating` → `Running`. Add
`-w` to *watch* changes live (press **Ctrl+C** to stop watching):

```bash
kubectl get pods -w
```

Now the useful variants:

```bash
kubectl get pod first -o wide        # which node did the scheduler pick?
kubectl describe pod first           # read the Events: Scheduled → Pulling → Pulled → Created → Started
kubectl get pod first -o yaml        # the full object, including everything Kubernetes filled in
```

Look at the YAML output. You only gave a name and an image, yet there are dozens of fields.
Kubernetes filled in defaults (`restartPolicy: Always`, `dnsPolicy`, ...) and a `status:`
section that shows the *actual* state. **`spec` = desired state, `status` = actual state.**
Every object has this shape.

Pull out a single field with JSONPath (works the same in bash and PowerShell because of the single quotes):

```bash
kubectl get pod first -o jsonpath='{.spec.nodeName}'
kubectl get pod first -o jsonpath='{.status.podIP}'
```

Clean up:

```bash
kubectl delete pod first
```

## 5. Built-in documentation: `kubectl explain`

You don't need to memorise YAML fields. Ask the cluster:

```bash
kubectl explain pod
kubectl explain pod.spec.containers
kubectl explain pod.spec.containers.image
kubectl explain deployment.spec.strategy --recursive
```

And to list every object type the cluster knows (including short names like `po`, `svc`, `deploy`):

```bash
kubectl api-resources
```

## 6. Imperative vs declarative

What you did above (`kubectl run`) is **imperative**: "do this now". Fine for experiments.

From the next lesson on, you'll work **declaratively**: write YAML files, `kubectl apply -f`
them, and keep them in Git. That's how real teams work, because:

- the files *are* the documentation of what's running,
- changes go through code review,
- you can recreate everything from scratch (disaster recovery, new environments) with one command,
- tools like Argo CD/Flux can keep a cluster in sync with Git automatically ("GitOps").

## Cheat sheet

```bash
kubectl get pods                       # list (current namespace)
kubectl get pods -A                    # list across all namespaces
kubectl get pods -o wide               # more columns
kubectl get pods -w                    # watch live (Ctrl+C to stop)
kubectl get all                        # common types at once
kubectl describe pod <name>            # details + events
kubectl logs <pod> [-f] [--previous]   # app output (-f follows; --previous = before last crash)
kubectl explain <type.field>           # docs
kubectl delete <type> <name>           # remove
```

## Exercises

1. How many CPUs does `lessons-worker2` report as allocatable?
2. Which node is the CoreDNS pod (`k8s-app=kube-dns`) running on?
3. What is the short name for `deployments`? For `services`?
4. Run a pod named `test` from image `busybox:1.37` with no command. What status does it end up in, and why? (Hint: `describe` and `logs`.) Delete it afterwards.

<details>
<summary>Answers</summary>

1. `kubectl describe node lessons-worker2` → see `Allocatable: cpu:` (it equals your machine's CPU count, since kind nodes share your machine).
2. `kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide` → `NODE` column (usually the control-plane node).
3. `deploy` and `svc` (`kubectl api-resources | grep -i -E "deploy|service"`, or in PowerShell `kubectl api-resources | Select-String deploy,service`).
4. It cycles through `Completed`, `Running` and `CrashLoopBackOff`, with the `RESTARTS` count climbing. busybox's default command is a shell, which exits immediately when there's no terminal attached. Pods restart containers by default (`restartPolicy: Always`), so it exits, restarts, exits... and Kubernetes backs off with increasing delays. **A container must keep a foreground process running**. You'll see this again in the troubleshooting lesson. `kubectl delete pod test`.
</details>

---

**Next:** [Lesson 03: Pods](../03-pods/README.md)
