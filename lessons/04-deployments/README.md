# Lesson 04: Deployments: self-healing, scaling, zero-downtime updates

**Time:** 45 minutes · **Goal:** see the control loop from lesson 01 actually work, and do a
rolling update and a rollback.

## The hierarchy

```
Deployment "web"               you create and edit this
   └── ReplicaSet "web-6b85d…"  one per version of the Pod template; keeps N Pods alive
          ├── Pod web-6b85d…-66fvp
          ├── Pod web-6b85d…-qcr6l
          └── Pod web-6b85d…-xhtqc
```

You only ever touch the **Deployment**. It creates a **ReplicaSet** per version, and the
ReplicaSet creates Pods. You'll rarely interact with ReplicaSets directly, but seeing them
explains how rollbacks work.

## 1. Create it

Read [`deployment.yaml`](deployment.yaml), especially the comments about `selector` and `strategy`.

```bash
kubectl apply -f lessons/04-deployments/deployment.yaml
kubectl rollout status deploy/web
kubectl get deploy,rs,pods -o wide
```

Look at the `NODE` column: the scheduler spread the 3 Pods across your worker nodes. Notice the
Pod names: `<deployment>-<replicaset hash>-<random>`.

## 2. Self-healing

Open a **second terminal** and watch the Pods:

```bash
kubectl get pods -l app=web -w
```

In the first terminal, delete one Pod (copy a real name from the list):

```bash
kubectl delete pod web-6b85d48445-66fvp
```

Within a second, a replacement appears in the watch window. The ReplicaSet saw "2 running, 3
desired" and fixed it. Try deleting *all* of them:

```bash
kubectl delete pods -l app=web
```

Three new ones appear. This is what you get over a bare Pod.

> **Simulate a node failure (optional):** `docker stop lessons-worker2`. After about 1 minute the node
> goes `NotReady`, and Kubernetes evicts its Pods and recreates them on the remaining nodes
> (by default that takes ~5 minutes, the `node.kubernetes.io/unreachable` toleration). Bring it
> back with `docker start lessons-worker2`.

## 3. Scaling

```bash
kubectl scale deploy/web --replicas=5
kubectl get pods -l app=web
```

Now re-apply the file:

```bash
kubectl apply -f lessons/04-deployments/deployment.yaml
kubectl get pods -l app=web
```

Back to 3! The file says `replicas: 3` and `apply` makes reality match the file. **Imperative
changes (`scale`, `set image`, `edit`) drift from your files and get silently undone by the
next apply.** In real teams the YAML in Git is the source of truth: change the file, then apply.

## 4. Rolling update (zero downtime)

Keep the watch running in the second terminal. Now edit
[`deployment.yaml`](deployment.yaml) and change the image from `nginx:1.27-alpine` to
`nginx:1.29-alpine`. Save and apply:

```bash
kubectl apply -f lessons/04-deployments/deployment.yaml
kubectl rollout status deploy/web
```

Watch the second terminal. Because of `maxSurge: 1, maxUnavailable: 0`, Kubernetes:

1. creates **one** new Pod,
2. waits until it's **Ready**,
3. deletes **one** old Pod,
4. repeats until all are new.

At no point are fewer than 3 Pods serving. Then:

```bash
kubectl get rs
```

```
NAME                DESIRED   CURRENT   READY
web-6b85d48445   0         0         0      <- old version, kept (scaled to 0) for rollback
web-b494fb7c8    3         3         3      <- new version
```

## 5. A broken release and a rollback

Release a version that doesn't exist (simulates a bad build):

```bash
kubectl set image deploy/web nginx=nginx:9.9.9-alpine
kubectl rollout status deploy/web --timeout=30s
kubectl get pods -l app=web
```

```
web-95c9466d6-lrxzt   0/1     ImagePullBackOff   0          20s
web-b494fb7c8-bjdf7   1/1     Running            0          24s
web-b494fb7c8-v9swd   1/1     Running            0          25s
web-b494fb7c8-wnbnq   1/1     Running            0          24s
```

**The rollout is stuck, but your app is still up.** The new Pod never became Ready, so with
`maxUnavailable: 0` no old Pod was removed. This is why those two settings matter.

Roll back:

```bash
kubectl rollout history deploy/web
kubectl rollout undo deploy/web
kubectl rollout status deploy/web
```

`undo` scales the previous ReplicaSet back up. Also useful: `kubectl rollout undo deploy/web --to-revision=1`.

> **Real-world note:** `rollout undo` is the emergency lever. Afterwards your YAML file and
> the cluster disagree, and kubectl even warns you about it. In teams using Git as the source of
> truth, the "proper" rollback is reverting the commit and re-applying (or letting Argo CD/Flux
> do it). Also, the `CHANGE-CAUSE` column in history only shows the
> `kubernetes.io/change-cause` annotation, which nobody updates automatically, so most teams
> rely on Git history instead.

## 6. Restart all Pods (without changing anything)

Useful after changing a ConfigMap (lesson 06) or to clear a stuck state:

```bash
kubectl rollout restart deploy/web
```

It's a rolling restart, so there's no downtime.

## Clean up

Undo your edit to `deployment.yaml` (set the image back to `1.27-alpine`, or `git checkout lessons/04-deployments/deployment.yaml`), then:

```bash
kubectl delete -f lessons/04-deployments/deployment.yaml
```

## Exercises

1. Change `maxSurge` to `3` and `maxUnavailable` to `0`, then do a rolling update. How is it different to watch?
2. With `replicas: 3`, what do `maxSurge: 0, maxUnavailable: 1` mean? Is that zero downtime? When would you choose it?
3. Why does a Deployment's `selector` have to match the template's labels? What happens if you
   apply a Deployment where they don't match? (Try it.)
4. You run `kubectl delete rs <current-replicaset>`. Predict what happens, then try it.

<details>
<summary>Answers</summary>

1. All 3 new Pods are created at once (up to 6 total), then old ones are removed as new ones
   become ready. It's faster, but briefly needs double the resources.
2. Kubernetes removes one old Pod first (down to 2 serving), then starts a new one. It's
   still no outage, but there's *reduced capacity* during the rollout. Choose it when the cluster
   has no spare room for extra Pods, or when two versions must never exceed N total (e.g. licence limits).
3. The Deployment uses the selector to find "its" Pods. If the template's Pods wouldn't match,
   it could never see them and would create Pods forever. The API server rejects it:
   `selector does not match template labels`.
4. The Deployment notices its ReplicaSet is missing and creates a new one (same hash), which
   creates new Pods. The control loop again. Deleting the ReplicaSet also deletes its Pods,
   so there's a brief disruption.
</details>

---

**Next:** [Lesson 05: Services and networking](../05-services/README.md)
