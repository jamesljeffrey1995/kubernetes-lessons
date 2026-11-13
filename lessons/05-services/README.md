# Lesson 05: Services and networking

**Time:** 45 minutes · **Goal:** give a changing set of Pods one stable address, understand
cluster DNS, and know the Service types.

## The problem Services solve

Pods are temporary. Every time one is replaced (crash, rollout, scaling) it gets a **new IP**.
So how does a frontend find the backend?

A **Service** is a stable virtual IP + DNS name that load-balances to **whichever Pods
currently match a label selector and are Ready**:

```
                       Service "whoami"  (10.96.71.255, DNS: whoami)
                        selector: app=whoami
                  ┌──────────────┼──────────────┐
                  ▼              ▼              ▼
             Pod 10.244.1.13  Pod 10.244.2.10  Pod 10.244.2.11     (labels: app=whoami)
```

Pods come and go; the Service IP and name stay the same.

## 1. Set up

We need something *inside* the cluster to make requests from. [`../tools/toolbox.yaml`](../tools/toolbox.yaml)
is a small Pod with `curl` and `nslookup`. Running commands through `kubectl exec toolbox -- ...`
keeps them identical on Windows and Linux.

```bash
kubectl apply -f lessons/tools/toolbox.yaml
kubectl apply -f lessons/05-services/app.yaml
kubectl rollout status deploy/whoami
kubectl get svc whoami
```

```
NAME     TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
whoami   ClusterIP   10.96.71.255   <none>        80/TCP    5s
```

## 2. Load balancing

[`traefik/whoami`](https://github.com/traefik/whoami) replies with details about the Pod that served the request:

```bash
kubectl exec toolbox -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://whoami | grep Hostname; done'
```

```
Hostname: whoami-7c67c4c578-kxmnc
Hostname: whoami-7c67c4c578-b5cbl
Hostname: whoami-7c67c4c578-kxmnc
Hostname: whoami-7c67c4c578-rmkcw
...
```

Different Pods answer. (The `sh -c '...'` part runs *inside* the toolbox container, which is
Linux, so the loop syntax is the same no matter what your laptop runs. If you get no output the
first time, wait two seconds and retry; the Service may still be learning about the Pods.)

## 3. How does the Service know which Pods? EndpointSlices

```bash
kubectl get endpointslices -l kubernetes.io/service-name=whoami
kubectl get pods -l app=whoami -o wide
```

The ENDPOINTS IPs are exactly the Pod IPs. A controller keeps this list up to date as Pods come,
go, or become (un)Ready. Scale and watch it change:

```bash
kubectl scale deploy/whoami --replicas=5
kubectl get endpointslices -l kubernetes.io/service-name=whoami
kubectl scale deploy/whoami --replicas=3
```

> **#1 cause of "my Service doesn't work":** the Service `selector` doesn't match the Pod
> labels (typo, or different label). Then the endpoints list is **empty** and connections fail.
> Always check endpoints first.

## 4. DNS

Every Service gets a DNS name, served by CoreDNS inside the cluster:

| From | Name that works |
|---|---|
| Same namespace | `whoami` |
| Any namespace | `whoami.default` (`<service>.<namespace>`) |
| Fully qualified | `whoami.default.svc.cluster.local` |

```bash
kubectl exec toolbox -- cat /etc/resolv.conf
kubectl exec toolbox -- nslookup whoami.default.svc.cluster.local
kubectl exec toolbox -- curl -s http://whoami.default.svc.cluster.local
```

The `search` line in `resolv.conf` is why short names like `whoami` work for normal programs
(curl, your app). The busybox `nslookup` tool ignores search domains, so give it the full name.

## 5. The `port` / `targetPort` / `containerPort` triangle

```yaml
# Service                         # Pod
ports:                            containers:
  - port: 80        ◄── clients     - ports:
    targetPort: http ──────────────►    - name: http
                                          containerPort: 80
```

- `port`: what clients connect to on the Service.
- `targetPort`: where the Service sends traffic on the Pod. Referring to it **by name**
  (`http`) means you can change the container's port number without touching the Service.

## 6. Service types

| Type | Reachable from | Typical use |
|---|---|---|
| `ClusterIP` (default) | Inside the cluster only | Almost everything: backends, databases, internal APIs |
| `NodePort` | `<any node IP>:30000-32767` | Bare-metal / quick tests |
| `LoadBalancer` | A cloud load balancer's public IP | Exposing a TCP service directly on AWS/Azure/GCP |
| `ExternalName` | n/a, just a DNS alias (CNAME) | Pointing an in-cluster name at an external host |
| Headless (`clusterIP: None`) | DNS returns every Pod IP | StatefulSets / databases (lesson 08) |

Try NodePort ([`nodeport.yaml`](nodeport.yaml)):

```bash
kubectl apply -f lessons/05-services/nodeport.yaml
kubectl get svc whoami-nodeport
kubectl exec toolbox -- curl -s http://lessons-worker:30080
```

Port 30080 is now open on *every* node. With kind, your "nodes" are Docker containers, so this
port is **not** reachable from your browser unless it's mapped in `kind-config.yaml` (we only
mapped 8080 for the gateway). On a real cluster of VMs you'd hit `http://<node-ip>:30080`.

`LoadBalancer` on kind stays `<pending>` because there's no cloud to create one. On AKS/EKS/GKE it
gets a real public IP within a minute. For HTTP apps you'll normally use a **Gateway** instead
(lesson 10): one load balancer for many apps, with host/path routing and TLS.

## 7. Reaching a Service from your laptop: port-forward

```bash
kubectl port-forward svc/whoami 8081:80
```

Open <http://localhost:8081>. Unlike the Pod port-forward in lesson 03, this targets the
Service (it picks one Pod and sticks with it for the session).

## Clean up

```bash
kubectl delete -f lessons/05-services/
```

Leave the `toolbox` Pod running; later lessons use it.

## Exercises

1. Create a Service named `broken` with selector `app: who-am-i` (note the typo) on port 80.
   What do `kubectl get endpointslices -l kubernetes.io/service-name=broken` and
   `kubectl exec toolbox -- curl -s -m 3 http://broken` show? Fix it **without** deleting the Service.
2. Create a namespace `other` (`kubectl create namespace other`). From a Pod in `other`, what
   name reaches the `whoami` Service in `default`? (Hint: `kubectl run -n other tmp --image=curlimages/curl:8.17.0 --command -- sleep infinity`, then exec into it.)
3. Delete all whoami Pods while running the curl loop from section 2 a few times. Do any requests fail? Why or why not?

<details>
<summary>Answers</summary>

1. Endpoints are empty, and curl fails (connection refused or a timeout, depending on the network plugin).
   Fix: `kubectl edit svc broken` and correct the selector (or fix your YAML and re-apply). Endpoints
   appear immediately. `kubectl describe svc broken` also shows an empty `Endpoints:` line.
2. `whoami.default` (or the full `whoami.default.svc.cluster.local`). Plain `whoami` would look for
   a Service called `whoami` in `other`. Clean up: `kubectl delete namespace other`.
3. Some may fail briefly. Deleting all Pods at once means for a moment nothing is Ready (a
   Deployment replaces them, but not instantly). Rolling updates avoid this because they keep
   Ready Pods at all times. Readiness probes (lesson 09) make that safer still.
</details>

---

**Next:** [Lesson 06: ConfigMaps and Secrets](../06-config-secrets/README.md)
