# Lesson 09: Health checks and resources

**Time:** 50 minutes · **Goal:** tell Kubernetes how to know your app is healthy and how much
CPU/memory it needs. These two things separate a demo from a production deployment.

## Part 1: Probes

Without probes, Kubernetes only knows "the process is running". It can't tell that your app is
deadlocked, still loading, or has lost its database connection. Probes fix that.

| Probe | Question | On failure |
|---|---|---|
| **readiness** | "Should this Pod get traffic right now?" | Removed from Service endpoints. **Not restarted.** Re-added when it passes again |
| **liveness** | "Is this process stuck beyond repair?" | Container is **killed and restarted** |
| **startup** | "Has it finished starting?" | Liveness/readiness wait until it passes; restarted if it never does |

Each probe can be `httpGet` (2xx/3xx = healthy), `tcpSocket` (port accepts connections),
`exec` (command exits 0) or `grpc`.

### 1. Readiness: take a Pod out of rotation without killing it

Read [`probes.yaml`](probes.yaml). `traefik/whoami` has a handy feature: POST a status code to
`/health` and it starts returning that code, which lets us simulate a sick Pod.

```bash
kubectl apply -f lessons/tools/toolbox.yaml
kubectl apply -f lessons/09-health-resources/probes.yaml
kubectl rollout status deploy/whoami
kubectl get pods -l app=whoami
```

Pick the first Pod's name and IP:

**bash:**
```bash
POD=$(kubectl get pod -l app=whoami -o jsonpath='{.items[0].metadata.name}')
POD_IP=$(kubectl get pod $POD -o jsonpath='{.status.podIP}')
```

**PowerShell:**
```powershell
$POD = kubectl get pod -l app=whoami -o jsonpath='{.items[0].metadata.name}'
$POD_IP = kubectl get pod $POD -o jsonpath='{.status.podIP}'
```

From here on the commands are identical. Make that Pod "sick":

```bash
kubectl exec toolbox -- curl -s -X POST -d 503 http://$POD_IP/health
kubectl get pods -l app=whoami
```

```
NAME                     READY   STATUS    RESTARTS   AGE
whoami-fdcb9db54-4x49k   0/1     Running   0          5s     <- not ready, still running, no restart
whoami-fdcb9db54-75fgp   1/1     Running   0          5s
whoami-fdcb9db54-kzczv   1/1     Running   0          5s
```

Send traffic through the Service:

```bash
kubectl exec toolbox -- sh -c 'for i in $(seq 1 9); do curl -s http://whoami | grep Hostname; done'
```

The sick Pod never answers. Kubernetes stopped routing to it. Make it healthy again, and it rejoins:

```bash
kubectl exec toolbox -- curl -s -X POST -d 200 http://$POD_IP/health
kubectl get pods -l app=whoami
```

**Where readiness matters most:**
- **During rolling updates.** A new Pod only gets traffic, and the rollout only continues, once it's
  Ready. Without a readiness probe, "Ready" just means "process started", and users hit Pods that are still warming up.
- **Temporary overload or a lost dependency.** The Pod steps out of rotation and recovers, without a pointless restart.

### 2. Liveness: restart a stuck container

[`liveness-demo.yaml`](liveness-demo.yaml) points liveness at `/health`:

```bash
kubectl apply -f lessons/09-health-resources/liveness-demo.yaml
kubectl wait --for=condition=Ready pod/liveness-demo
```

bash: `LIVE_IP=$(kubectl get pod liveness-demo -o jsonpath='{.status.podIP}')`
PowerShell: `$LIVE_IP = kubectl get pod liveness-demo -o jsonpath='{.status.podIP}'`

```bash
kubectl exec toolbox -- curl -s -X POST -d 500 http://$LIVE_IP/health
kubectl get pod liveness-demo -w
```

After 2 failed checks (~6 seconds) `RESTARTS` becomes `1`. The restart reset the app's
in-memory state, so it's healthy again. The events tell the story:

```bash
kubectl describe pod liveness-demo
```

```
Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 500
Normal   Killing    Container whoami failed liveness probe, will be restarted
```

### ⚠️ Probe mistakes that cause outages

These are real and common:

1. **Liveness checks a dependency** (database, other service). The DB has a blip → liveness fails
   on *every* Pod → Kubernetes restarts *all* of them at once → full outage, made worse by the
   restart storm. **Liveness should only check the process itself.** Put dependency checks in readiness, if anywhere.
2. **Liveness timeouts too tight.** Under load, a slow-but-fine app misses a probe and gets
   killed, which shifts load to the others, which then get killed... A cascading failure.
3. **Using liveness `initialDelaySeconds` for slow starts.** Use a `startupProbe` instead.
4. **Same endpoint and thresholds for readiness and liveness.** Then readiness can never act
   before liveness kills the Pod. Make liveness more tolerant than readiness.

## Part 2: Resources

### requests vs limits

```yaml
resources:
  requests:        # RESERVATION: used by the scheduler to pick a node with enough room
    cpu: 50m       # 1000m = 1 CPU core
    memory: 32Mi
  limits:          # CEILING: enforced at runtime by the kernel
    memory: 64Mi
```

| | CPU | Memory |
|---|---|---|
| **Over the limit** | **Throttled** (slowed down). Never killed for CPU | **OOMKilled**: the container is killed and restarted |
| Why the difference | CPU is "compressible": you can give less of it | Memory isn't: you can't take back RAM a process holds |

### 3. Watch an OOMKill

[`oom.yaml`](oom.yaml) tries to use 250 MB with a 100Mi limit:

```bash
kubectl apply -f lessons/09-health-resources/oom.yaml
kubectl get pod memory-hog -w
```

```
memory-hog   0/1     OOMKilled          1 (6s ago)   7s
memory-hog   0/1     CrashLoopBackOff   1 (8s ago)   9s
```

```bash
kubectl describe pod memory-hog
```

Under `Last State: Terminated`, `Reason: OOMKilled`, `Exit Code: 137` (137 = 128 + signal 9, SIGKILL).
**At work, exit code 137 + OOMKilled = "raise the memory limit or fix the memory leak".**

### 4. Watch CPU throttling (needs metrics-server)

```bash
kubectl apply -f lessons/09-health-resources/cpu.yaml
kubectl top pod cpu-hog          # wait ~1 minute for the first metrics
kubectl top nodes
```

`cpu-hog` wants a whole core but sits at about `200m`, its limit. It's still running, just slow.

If `kubectl top` says `Metrics API not available`, check that metrics-server is running:
`kubectl -n kube-system get pods -l k8s-app=metrics-server` (re-run `cluster-up` if it's missing).

### Should you set CPU limits?

This is a genuine debate, and you'll hear both sides at work:

- **Common recommendation now:** set CPU *requests* on everything, **no CPU limits** for most apps,
  and **always** set memory limits (usually equal to memory requests). CPU limits cause throttling
  even when the node has idle CPU, which shows up as mysterious latency spikes.
- **Counter-argument:** on shared multi-tenant clusters, CPU limits stop one noisy app from
  hurting others, and make performance predictable (what you test is what you get).

`probes.yaml` follows the first approach. Either way: **never deploy without requests.** Without
them the scheduler is guessing, and nodes get overpacked.

### QoS classes: who gets killed first when a node runs out of memory

| Class | When | Eviction order |
|---|---|---|
| `Guaranteed` | requests = limits for CPU *and* memory, on every container | Last |
| `Burstable` | Some requests/limits set, but not Guaranteed | Middle |
| `BestEffort` | Nothing set at all | **First** |

```bash
kubectl get pods -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass
```

The `toolbox` Pod is `BestEffort` (no resources); `whoami` is `Burstable`.

## Clean up

```bash
kubectl delete -f lessons/09-health-resources/
```

## Exercises

1. Change `probes.yaml`'s readiness probe path to `/nope` and apply. What happens to the
   rollout? Is the app down? Revert it afterwards.
2. Give the `memory-hog` 300Mi limit. Does it run now?
3. Request `cpu: 50` (fifty *cores*) in a Pod. What status does it get, and what does `describe` say?

<details>
<summary>Answers</summary>

1. The new Pod never becomes Ready (`/nope` returns 404), so the rollout stalls with the old Pods
   still serving. **No outage**, thanks to readiness + the default rolling update. `kubectl rollout undo deploy/whoami` or fix the file.
2. Yes. 250 MB fits under 300Mi (~314 MB). It runs until you delete it.
3. `Pending` forever. Events show `0/3 nodes are available: 1 node(s) had untolerated taint(s),
   2 Insufficient cpu`. (The taint is the control-plane node refusing normal workloads.) The scheduler
   only places Pods where the *requests* fit. This is also what you'll see when a real cluster is full.
   (On a cloud cluster with an autoscaler, this is what triggers adding a node.)
</details>

---

**Next:** [Lesson 10: Getting traffic in (Gateway API and Ingress)](../10-gateway-ingress/README.md)
