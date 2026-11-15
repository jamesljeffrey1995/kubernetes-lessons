# Lesson 16: Scheduling and node maintenance

**Time:** 50 minutes · **Goal:** control *where* Pods run, and keep an app up while the
platform team patches or upgrades the nodes under it.

## Why this matters at work

Two things happen on every real cluster, and both land on application teams:

- **"Why is my Pod Pending?" / "Why are all my replicas on one node?"** The scheduler followed
  rules: yours, or ones somebody else put on the nodes.
- **Nodes get replaced all the time.** Kubernetes upgrades, OS patches, autoscaling and spot
  instances all *drain* nodes: every Pod on them is evicted and recreated elsewhere. Whether
  users notice is decided by your manifests, not by the platform team.

## How the scheduler picks a node

For every new Pod, in two steps:

```
1. FILTER  remove nodes that can't run it   not enough free CPU/memory (requests, lesson 09)
                                            nodeSelector / required affinity doesn't match
                                            a taint the Pod doesn't tolerate
                                            a hard topology spread rule would be broken
2. SCORE   rank the nodes that are left     emptier nodes, preferred affinity, soft spread rules
```

No node left after step 1 means `Pending`, and `kubectl describe pod` says which filter removed
how many nodes. You'll read that message a lot:

```
0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
2 node(s) didn't match Pod's node affinity/selector.
```

## 1. Spread replicas across nodes

Three replicas on one node is one node failure away from an outage. Read
[`spread.yaml`](spread.yaml), especially the comments on `topologySpreadConstraints`.

```bash
kubectl apply -f lessons/16-scheduling/spread.yaml
kubectl rollout status deploy/spread
kubectl get pods -l app=spread -o wide
```

Two Pods on `lessons-worker`, two on `lessons-worker2`. None on the control plane, because of
this:

```bash
kubectl describe node lessons-control-plane
```

Look for `Taints: node-role.kubernetes.io/control-plane:NoSchedule`. That's the next topic.

## 2. Attract Pods to nodes: labels and `nodeSelector`

[`pinned.yaml`](pinned.yaml) only runs on nodes labelled `disktype=ssd`. No node has that label:

```bash
kubectl apply -f lessons/16-scheduling/pinned.yaml
kubectl get pods -l app=ssd-app
kubectl describe pod -l app=ssd-app
```

`Pending`, and the last lines of `describe` say why (`didn't match Pod's node affinity/selector`).
Label a node, and the scheduler places the Pod within seconds:

```bash
kubectl label node lessons-worker disktype=ssd
kubectl get pods -l app=ssd-app -o wide
kubectl get nodes --show-labels
```

At work the labels already exist: instance type, zone, architecture, GPU. **Node affinity** is the
same idea with more expressive rules (`In`, `NotIn`, "preferred" instead of "required").

## 3. Repel Pods from nodes: taints and tolerations

A label on a node attracts Pods that ask for it. A **taint** does the reverse: it keeps away
every Pod that doesn't explicitly **tolerate** it. That's how control-plane nodes stay free of
your apps, and how teams reserve expensive nodes (GPUs, big-memory) for the workloads that need them.

Reserve `lessons-worker2` for batch work:

```bash
kubectl taint nodes lessons-worker2 dedicated=batch:NoSchedule
kubectl label node lessons-worker2 dedicated=batch
kubectl apply -f lessons/16-scheduling/batch.yaml
kubectl get pods -l app=batch -o wide
```

Both `batch` Pods run on `lessons-worker2`. Read [`batch.yaml`](batch.yaml): it needs the
toleration (permission to be there) **and** the nodeSelector (the wish to be there).

The two `spread` Pods already on that node are still running. `NoSchedule` only affects *new*
Pods. The three effects:

| Effect | New Pods without a toleration | Pods already running |
|---|---|---|
| `NoSchedule` | Not scheduled here | Stay |
| `PreferNoSchedule` | Avoided if possible | Stay |
| `NoExecute` | Not scheduled here | **Evicted** |

Kubernetes uses taints itself: a node that stops responding gets
`node.kubernetes.io/unreachable:NoExecute`, and that's what moves your Pods away after 5 minutes.

Undo the reservation before the next part:

```bash
kubectl delete -f lessons/16-scheduling/batch.yaml -f lessons/16-scheduling/pinned.yaml
kubectl taint nodes lessons-worker2 dedicated=batch:NoSchedule-
kubectl label node lessons-worker2 dedicated-
kubectl label node lessons-worker disktype-
```

(The trailing `-` removes a taint or label.)

## 4. Node maintenance: cordon, drain, and PodDisruptionBudgets

This is what the platform team, or the cloud provider's upgrade process, does to each node:

```
kubectl cordon <node>    mark it unschedulable: nothing new lands here
kubectl drain <node>     cordon + evict every Pod, politely
   ... patch / upgrade / replace the machine ...
kubectl uncordon <node>  allow scheduling again
```

An eviction is a polite delete: the Pod gets its normal graceful shutdown, and its Deployment
creates a replacement on another node. The one thing that can refuse an eviction is a
**PodDisruptionBudget (PDB)**: your statement of how many Pods the app can afford to lose at once.

### 4a. A PDB that blocks everything

Start with the mistake. [`pdb-too-strict.yaml`](pdb-too-strict.yaml) demands 4 of 4 Pods available:

```bash
kubectl apply -f lessons/16-scheduling/pdb-too-strict.yaml
kubectl get pdb spread
kubectl drain lessons-worker2 --ignore-daemonsets --delete-emptydir-data --force --timeout=30s
```

`ALLOWED DISRUPTIONS` is `0`, and the drain keeps printing

```
error when evicting pods/"spread-..." (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

until it times out. On a real cluster this is a ticket from the platform team: *"your PDB is
blocking the node upgrade."* The same happens with a single-replica Deployment and
`minAvailable: 1`.

(The flags: DaemonSet Pods can't move and are skipped; `emptyDir` data is lost on eviction and you
must say you accept that; `--force` also deletes bare Pods that no controller will recreate,
such as the toolbox.)

### 4b. A PDB that protects the app and lets work proceed

[`pdb.yaml`](pdb.yaml) asks for 3 of 4. Watch the Pods in a second terminal:

```bash
kubectl get pods -l app=spread -o wide -w
```

```bash
kubectl apply -f lessons/16-scheduling/pdb.yaml
kubectl drain lessons-worker2 --ignore-daemonsets --delete-emptydir-data --force --timeout=180s
```

The drain evicts **one** `spread` Pod, has to wait until its replacement is `Ready` on
`lessons-worker` (the readiness probe from lesson 09 matters here), and only then evicts the
second. The app never drops below 3 ready Pods.

```bash
kubectl get nodes
kubectl get pods -l app=spread -o wide
```

`lessons-worker2` shows `Ready,SchedulingDisabled`, and all four Pods are on `lessons-worker`.
Bring the node back:

```bash
kubectl uncordon lessons-worker2
kubectl get pods -l app=spread -o wide
```

**The Pods don't move back.** Kubernetes never rebalances running Pods on its own. They spread
out again at the next rollout (`kubectl rollout restart deploy/spread`). Teams that want
continuous rebalancing run the *descheduler* add-on.

## What makes an app survive a drain: the checklist

| You need | Why | Lesson |
|---|---|---|
| 2+ replicas | With one replica, every eviction is an outage | 04 |
| Spread across nodes (and zones) | Or one drain takes all replicas at once | this one |
| A PDB that allows at least 1 disruption | Protects you without blocking maintenance | this one |
| A readiness probe | Tells the drain when the replacement is really serving | 09 |
| Graceful shutdown on `SIGTERM` | In-flight requests finish before the Pod exits | capstone |
| CPU/memory requests | So the replacement fits somewhere, and the scheduler knows it | 09 |

The capstone does all six, and proves it by draining a node under load with zero failed requests.

Also worth knowing by name: **PriorityClass** (when the cluster is full, higher-priority Pods
*preempt* lower ones; give batch jobs a low priority), **pod anti-affinity** (the older way to
keep replicas apart), and **Karpenter / Cluster Autoscaler** (add nodes when Pods are Pending for
lack of room, and drain nodes to save money, which is one more reason to get PDBs right).

## Clean up

```bash
kubectl uncordon lessons-worker2
kubectl delete -f lessons/16-scheduling/spread.yaml -f lessons/16-scheduling/pdb.yaml
kubectl apply -f lessons/tools/toolbox.yaml
```

## Exercises

1. Scale `spread` to 5 with `lessons-worker2` cordoned. Where does the fifth Pod go? Now remove
   `nodeTaintsPolicy: Honor` from `spread.yaml`, apply, and look at the new Pods. What happened, and why?
2. Taint `lessons-worker2` with `dedicated=batch:NoExecute` (instead of `NoSchedule`) while
   `spread` Pods are running on it. What happens to them? Remove the taint afterwards.
3. Write the PDB from 4b using `maxUnavailable` instead of `minAvailable`. Which form survives
   someone changing `replicas` from 4 to 10?
4. A Deployment has 1 replica and its PDB says `minAvailable: 1`. The platform team needs to
   upgrade the node. Name two ways out, and which one you'd choose.

<details>
<summary>Answers</summary>

1. It goes to `lessons-worker`: with `Honor`, the cordoned node and the control plane aren't
   counted, so there's only one node to spread over. Without that line both count as nodes
   holding zero Pods. The emptiest node then has 0, so no other node may hold more than 1
   (`maxSkew: 1`), and the new Pods stay `Pending` with `didn't match pod topology spread
   constraints`. This is a common cause of mysterious Pending Pods.
2. They're evicted immediately and recreated on the other node. `NoExecute` also removes running Pods that don't tolerate it.
3. `maxUnavailable: 1`. It keeps meaning "one at a time" at any replica count, while
   `minAvailable: 3` with 10 replicas would allow 7 Pods to be evicted at once. Prefer
   `maxUnavailable` (or a percentage) for that reason.
4. Scale to 2 replicas (then the PDB allows one eviction), or delete the PDB and accept a short
   outage. Scaling up is the real fix: a single replica can't be highly available, and the PDB
   was only hiding that.
</details>

---

**Next:** [Lesson 17: Debugging running workloads](../17-debugging/README.md)
