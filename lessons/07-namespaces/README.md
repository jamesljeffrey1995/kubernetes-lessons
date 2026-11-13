# Lesson 07: Namespaces, labels and quotas

**Time:** 30 minutes · **Goal:** organise a cluster shared by several apps or teams, and stop
one of them from eating all the resources.

## Namespaces

A **namespace** is a folder for objects. Names only need to be unique *within* a namespace,
so `team-a/web` and `team-b/web` can coexist. Common ways to split:

- per **team** (`payments`, `search`),
- per **app** (`shop`, `blog`),
- per **environment** on a shared non-prod cluster (`dev`, `test`). Production usually gets
  its *own cluster*, because namespaces are not a strong security boundary on their own.

```bash
kubectl get namespaces
```

Things that are **namespaced**: Pods, Deployments, Services, ConfigMaps, Secrets...
Things that are **cluster-wide**: Nodes, Namespaces themselves, StorageClasses, ClusterRoles...
(`kubectl api-resources --namespaced=false` lists them.)

## 1. A namespace with guard rails

Read [`team-a.yaml`](team-a.yaml): a namespace, a **ResourceQuota** (budget for the whole
namespace) and a **LimitRange** (defaults and caps per container).

```bash
kubectl apply -f lessons/07-namespaces/team-a.yaml
kubectl apply -f lessons/07-namespaces/app.yaml
```

Everything you do in another namespace needs `-n` (or `--namespace`):

```bash
kubectl get pods                 # default namespace: nothing from team-a
kubectl get pods -n team-a
kubectl get pods -A              # all namespaces
```

### Defaults filled in by the LimitRange

[`app.yaml`](app.yaml) sets no CPU/memory on its container. Look what it got anyway:

```bash
kubectl get pods -n team-a -o jsonpath='{.items[0].spec.containers[0].resources}'
```

```json
{"limits":{"memory":"128Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}
```

### The quota in action

```bash
kubectl describe quota budget -n team-a
```

```
Resource            Used   Hard
--------            ----   ----
limits.memory       256Mi  2Gi
pods                2      5
requests.cpu        200m   1
...
```

Now try to go over budget:

```bash
kubectl scale deploy/web -n team-a --replicas=8
kubectl get deploy,rs -n team-a
```

The ReplicaSet wants 8 but only has 5. Why?

```bash
kubectl describe rs -n team-a
```

```
Warning  FailedCreate  ...  pods "web-..." is forbidden: exceeded quota: budget, requested: pods=1, used: pods=5, limited: pods=5
```

> Note where the error appears: **not** on `kubectl scale` (that succeeded; it only changed
> the desired number), but on the ReplicaSet, when the controller tries to create Pods.
> When "nothing happens", look at the events of the object one level down.

And the per-container cap. [`too-big.yaml`](too-big.yaml) asks for 1Gi:

```bash
kubectl apply -f lessons/07-namespaces/too-big.yaml
```

```
Error from server (Forbidden): ... maximum memory usage per Container is 512Mi, but limit is 1Gi
```

## 2. Stop typing `-n` all the time

Set a default namespace for your current context:

```bash
kubectl config set-context --current --namespace=team-a
kubectl get pods                       # now shows team-a
kubectl config set-context --current --namespace=default   # switch back
```

Many people install [kubectx + kubens](https://github.com/ahmetb/kubectx) for quicker switching
between clusters and namespaces (see its README for Windows and Linux install options).

## 3. Labels: use the recommended ones

Kubernetes suggests a [standard set of labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/)
that tools (Helm, dashboards, cost tools) understand:

| Label | Example |
|---|---|
| `app.kubernetes.io/name` | `web` |
| `app.kubernetes.io/instance` | `web-prod` |
| `app.kubernetes.io/version` | `1.29` |
| `app.kubernetes.io/component` | `frontend` |
| `app.kubernetes.io/part-of` | `shop` |
| `app.kubernetes.io/managed-by` | `Helm` |

Select across namespaces with them:

```bash
kubectl get deploy -A -l app.kubernetes.io/part-of=shop
kubectl get pods -n team-a -L app.kubernetes.io/component
```

**Labels vs annotations:** labels are short, used for *selecting* (by Services, Deployments,
`-l`). Annotations hold longer free text for humans and tools (owner, runbook link, build ID)
and can't be selected on. See both on the Deployment in `app.yaml`.

## 4. Deleting a namespace deletes everything in it

```bash
kubectl delete namespace team-a
```

All its Deployments, Pods, Services, Secrets: gone. That's very handy for cleanup, and very
dangerous on a shared cluster. **Many teams protect important namespaces with RBAC so most
people can't delete them** (lesson 12).

## Exercises

1. Create `team-b.yaml` with a namespace `team-b` and a quota of max 2 Pods. Deploy
   `lessons/07-namespaces/app.yaml` into it *without editing the file*. (Hint: the file
   hard-codes `namespace: team-a`. What does `kubectl apply -n team-b -f` do then?)
2. With a ResourceQuota on `requests.cpu` but **no** LimitRange, what happens to a Pod that
   specifies no CPU request at all?
3. Is a Service in `team-a` reachable from a Pod in `team-b` by default? (Think back to lesson 05's DNS names.)

<details>
<summary>Answers</summary>

1. kubectl refuses: `the namespace from the provided object "team-a" does not match the namespace "team-b"`.
   If the file names a namespace, `-n` must agree with it. That's why reusable manifests
   usually **leave `namespace:` out** and let `-n` (or Helm/Kustomize) decide. Copy the file,
   delete the `namespace:` line, then `kubectl apply -n team-b -f app-copy.yaml`. With the
   2-Pod quota, the second replica fits and you see both running; scale to 3 and watch it fail.
2. It's **rejected**: `must specify requests.cpu`. Once a namespace has a quota on a resource,
   every Pod must declare it. That's why a quota usually comes with a LimitRange that supplies defaults.
3. Yes, as `<service>.team-a`. Namespaces separate *names*, not *network traffic*. To block
   cross-namespace traffic you need NetworkPolicies (lesson 12).
</details>

---

**Next:** [Lesson 08: Storage and StatefulSets](../08-storage/README.md)
