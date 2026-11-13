# Lesson 08: Storage and StatefulSets

**Time:** 45 minutes · **Goal:** keep data when Pods are replaced, and run something stateful (Redis) properly.

## The problem

A container's filesystem is thrown away when the container is replaced. `emptyDir` (lesson 03)
survives container *restarts* but is deleted with the *Pod*. For a database you need storage
that outlives Pods.

## The three objects

```
  You write:  PersistentVolumeClaim  "I need 1Gi, ReadWriteOnce"
                       │
                       ▼   the StorageClass's provisioner creates a disk automatically
              PersistentVolume       the actual disk (a cloud disk, NFS share, local dir...)
                       ▲
  StorageClass  "standard": how to create disks (which provisioner, which disk type)
```

```bash
kubectl get storageclass
```

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

On kind, "disks" are directories on the node container. On AKS/EKS/GKE the default class
creates real cloud disks. **Your YAML stays the same**, and that portability is the point of the PVC abstraction.

## 1. A PVC that survives Pod replacement

Read [`pvc.yaml`](pvc.yaml).

```bash
kubectl apply -f lessons/08-storage/pvc.yaml
kubectl get pvc
```

The PVC is `Pending` at first. `WaitForFirstConsumer` means the disk is only created once a
Pod using it is scheduled (so the disk lands in the same zone/node as the Pod). Seconds later:

```bash
kubectl get pvc,pv
kubectl exec deploy/notes -- tail -3 /data/notes.txt
```

Now kill the Pod and let the Deployment replace it:

```bash
kubectl delete pod -l app=notes
kubectl rollout status deploy/notes
kubectl exec deploy/notes -- grep -- "---" /data/notes.txt
```

```
--- notes-5544fb76f5-wvznk started at ...
--- notes-5544fb76f5-8qfmh started at ...
```

Two different Pods wrote to the same file. **The data outlived the Pod.**

### Access modes

| Mode | Meaning | Typical backing |
|---|---|---|
| `ReadWriteOnce` (RWO) | One *node* mounts read-write | Cloud block disks (EBS, Azure Disk, PD). The most common |
| `ReadWriteOncePod` | One *Pod* mounts read-write | Same, but stricter |
| `ReadOnlyMany` (ROX) | Many nodes, read-only | |
| `ReadWriteMany` (RWX) | Many nodes, read-write | Network file systems (EFS, Azure Files, NFS) |

That's why `pvc.yaml` uses `strategy: Recreate`: with an RWO disk, a rolling update's new Pod
might land on a different node and be unable to mount the disk while the old Pod still holds it.

## 2. StatefulSets

Deployments treat Pods as interchangeable cattle with random names. Databases need:

- **stable identity**: `redis-0` is always `redis-0`, with a stable DNS name,
- **their own disk each**, re-attached to the same identity after a restart,
- **ordered** start-up (0, then 1, then 2) and shutdown.

That's a **StatefulSet**. Read [`redis-statefulset.yaml`](redis-statefulset.yaml), especially the
headless Service and `volumeClaimTemplates`.

```bash
kubectl apply -f lessons/08-storage/redis-statefulset.yaml
kubectl rollout status sts/redis
kubectl get pods -l app=redis
kubectl get pvc
```

Pod `redis-0` with its own PVC `data-redis-0`. Write some data, then delete the Pod:

```bash
kubectl exec redis-0 -- redis-cli SET greeting "hello from before the crash"
kubectl delete pod redis-0
kubectl wait --for=condition=Ready pod/redis-0
kubectl exec redis-0 -- redis-cli GET greeting
```

Same name, same disk, same data. Each Pod has a stable DNS name via the headless Service:

```bash
kubectl apply -f lessons/tools/toolbox.yaml
kubectl exec toolbox -- nslookup redis-0.redis.default.svc.cluster.local
```

Scale up and watch the **ordered** creation (`redis-1` only starts after `redis-0` is Ready):

```bash
kubectl scale sts/redis --replicas=3
kubectl get pods -l app=redis -w
kubectl get pvc
```

> ⚠️ These are now **three independent Redis servers**, not a replicated cluster. A
> StatefulSet gives you identity and storage. *Replication* is the database's job, and needs
> configuration (or an **operator**, see below).

Scale back down and delete the StatefulSet:

```bash
kubectl scale sts/redis --replicas=1
kubectl delete -f lessons/08-storage/redis-statefulset.yaml
kubectl get pvc
```

**The PVCs are still there.** Kubernetes deliberately doesn't delete StatefulSet data when you
delete or scale down the StatefulSet. Re-apply the file and `redis-0` gets its old data back.

## 3. Reclaim policy: what happens to the disk when the PVC is deleted

- `Delete` (default for dynamic provisioning): the disk is destroyed. **Data gone.**
- `Retain`: the PV and disk stay around for an admin to recover or reuse manually.

For important data on a real cluster, use a StorageClass with `reclaimPolicy: Retain`, and
**back up** (e.g. [Velero](https://velero.io/), or cloud disk snapshots).

## Should you run databases on Kubernetes at work?

An honest answer:

- **For learning, dev and test environments: yes**, it's quick and cheap.
- **For production: often better not to**, unless your team has the skills. A managed
  database (RDS, Azure Database, Cloud SQL) gives you backups, failover, patching and
  point-in-time restore without effort.
- If you do run them in-cluster, use an **operator** (e.g. CloudNativePG for Postgres, or the
  operator for your database). An operator is a controller that encodes a DBA's runbook:
  replication, failover, backups, upgrades. Don't hand-roll a StatefulSet for production Postgres.

## Clean up

```bash
kubectl delete -f lessons/08-storage/pvc.yaml
kubectl delete pvc -l app=redis
kubectl get pvc
```

(The StatefulSet's PVCs inherit the Pod template's labels, which is why `-l app=redis` works.)

## Exercises

1. Scale `sts/redis` from 3 to 1 and back to 3. Do `redis-1` and `redis-2` get their old data back?
2. Change the `notes` Deployment to `replicas: 2` and apply. On a multi-node cluster, can both
   Pods start? Why or why not? (Try it, and check `kubectl get pods -o wide` and `describe`.)
3. Why might a PVC stay `Pending` forever? Name two reasons.

<details>
<summary>Answers</summary>

1. Yes. Scaling down keeps the PVCs `data-redis-1`/`data-redis-2`; scaling up re-attaches them by name.
2. It depends where the scheduler puts them. With RWO, both Pods must be on the **same node** as
   the disk. On kind with local-path storage the volume is pinned to one node (via node affinity),
   so the second Pod is scheduled onto that node too, and both run. On a cloud cluster with a
   block disk, a second Pod on another node gets stuck in `ContainerCreating` with `Multi-Attach
   error`. Lesson: RWO volumes and multiple replicas don't mix; use RWX storage or a StatefulSet (one disk per Pod).
3. Any of: no default StorageClass and none specified; `WaitForFirstConsumer` with no Pod
   using it yet (that's normal!); requested size or access mode the provisioner can't provide
   (e.g. RWX on a block-disk class); quota exceeded; the provisioner itself is broken.
   `kubectl describe pvc <name>` shows which.
</details>

---

**Next:** [Lesson 09: Health checks and resources](../09-health-resources/README.md)
