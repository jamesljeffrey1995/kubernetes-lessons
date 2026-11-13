# Lesson 03: Pods

**Time:** 45 minutes · **Goal:** create Pods from YAML, look inside them, and understand what
a Pod will and won't do for you.

Run all commands from the **repo root** (the folder containing `README.md`), so paths like
`lessons/03-pods/pod.yaml` work. Windows accepts forward slashes in these paths too.

## What a Pod is

A **Pod** is the smallest thing Kubernetes runs. It wraps **one or more containers** that:

- always run on the **same node**,
- share **one IP address** (they can talk via `localhost`),
- can share **volumes** (directories).

Most Pods have exactly one container. You add a second only when two processes are tightly
coupled (a "sidecar", e.g. a log shipper or proxy next to your app).

## 1. Your first Pod from YAML

Open [`pod.yaml`](pod.yaml) and read the comments. Every Kubernetes object has the same four top-level parts:
`apiVersion`, `kind`, `metadata`, `spec`.

```bash
kubectl apply -f lessons/03-pods/pod.yaml
kubectl get pods -w
```

Press Ctrl+C once it shows `Running`.

`apply` means "make the cluster match this file". Run it again and you'll get `pod/web unchanged`.
That's desired state in action: nothing to do.

## 2. Look inside

```bash
kubectl logs web                     # what nginx printed on startup
kubectl exec web -- nginx -v         # run one command inside the container
kubectl exec -it web -- sh           # open a shell inside it (type 'exit' to leave)
```

Inside the shell, try `hostname`, `cat /etc/os-release`, `wget -qO- localhost`. You're inside
the container's own little filesystem and network.

> **Windows note:** `kubectl exec -it` works in Windows Terminal / PowerShell 7. In very old
> consoles (or Git Bash's mintty) you may need `winpty kubectl exec -it web -- sh`.

## 3. Reach it from your machine: port-forward

Pods have IPs that only exist *inside* the cluster. For quick debugging, tunnel a local port to it:

```bash
kubectl port-forward pod/web 8081:80
```

Open <http://localhost:8081> and you'll see the nginx page. Press Ctrl+C in the terminal to stop the tunnel.

`port-forward` is a developer tool, not how you expose apps for real. Lessons 05 and 10 cover that.

## 4. Labels

Our Pod has labels `app=web` and `tier=frontend`:

```bash
kubectl get pods --show-labels
kubectl get pods -l tier=frontend
kubectl get pods -l 'app in (web, api)'
kubectl label pod web owner=me          # add a label
kubectl get pods -L owner               # show a label as a column
```

Labels look trivial but **they're the glue of Kubernetes**: Deployments find their Pods by
label, Services route traffic by label, NetworkPolicies allow traffic by label.

## 5. Restart vs replace: what a bare Pod will and won't do

Kill the main process inside the container:

```bash
kubectl exec web -- kill 1
kubectl get pod web
```

`RESTARTS` goes to `1`. The **kubelet** restarted the *container* inside the same Pod. See what
the previous container printed before it died:

```bash
kubectl logs web --previous
```

Now delete the *Pod*:

```bash
kubectl delete pod web
kubectl get pods
```

It's **gone for good**. Nothing recreates it. A bare Pod is like a single `docker run`: if
its node dies or someone deletes it, that's the end. **This is why you almost never create
bare Pods in real life.** You create a *Deployment* that creates Pods for you (next lesson).

## 6. Multi-container Pod (sidecar)

Read [`sidecar.yaml`](sidecar.yaml): a busybox container writes an HTML file every 5 seconds
into a shared `emptyDir` volume, and nginx serves it.

```bash
kubectl apply -f lessons/03-pods/sidecar.yaml
kubectl get pod web-with-sidecar           # READY shows 2/2: two containers
kubectl port-forward pod/web-with-sidecar 8081:80
```

Refresh <http://localhost:8081> a few times; the time changes. With more than one container,
pick which one with `-c`:

```bash
kubectl logs web-with-sidecar -c nginx
kubectl exec web-with-sidecar -c content -- cat /html/index.html
```

## 7. Init containers

Read [`init-container.yaml`](init-container.yaml). Init containers run to completion **before** the app starts.

```bash
kubectl apply -f lessons/03-pods/init-container.yaml
kubectl get pod web-with-init -w
```

You'll see `Init:0/1` → `PodInitializing` → `Running`, about 5 seconds apart.

```bash
kubectl exec web-with-init -- cat /usr/share/nginx/html/index.html
```

## 8. Pod lifecycle phases

| Phase / status | Meaning |
|---|---|
| `Pending` | Accepted, but not running yet: waiting to be scheduled, or pulling the image |
| `ContainerCreating` | Scheduled to a node; image pulling / container starting |
| `Running` | At least one container is running |
| `Succeeded` / `Completed` | All containers exited with code 0 and won't restart |
| `Failed` / `Error` | Containers exited with non-zero codes and won't restart |
| `CrashLoopBackOff` | Container keeps crashing; kubelet waits longer between each restart |
| `ImagePullBackOff` | Can't pull the image (typo, no access, no network) |

## Clean up

```bash
kubectl delete -f lessons/03-pods/
```

(`-f` on a folder applies/deletes every YAML file in it. If some are already deleted you'll see harmless "not found" messages.)

## Exercises

1. Write your own `my-pod.yaml` running `traefik/whoami:v1.11.0` (a tiny web server that
   prints details about the request and the Pod) with labels `app=whoami`, `env=dev`.
   Apply it, port-forward to its port 80, and open it in your browser.
2. Using only `kubectl`, find out which node it runs on and its Pod IP.
3. Change the `env` label to `test` *by editing your YAML and re-applying*. Confirm with `--show-labels`.
4. Try changing the `image` in your YAML to `nginx:1.29-alpine` and re-apply. Most Pod
   fields can't be changed after creation. What does Kubernetes say? What does that tell you?

<details>
<summary>Answers</summary>

1. ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: whoami
     labels:
       app: whoami
       env: dev
   spec:
     containers:
       - name: whoami
         image: traefik/whoami:v1.11.0
         ports:
           - containerPort: 80
   ```
   `kubectl apply -f my-pod.yaml` then `kubectl port-forward pod/whoami 8082:80` → <http://localhost:8082>.
2. `kubectl get pod whoami -o wide`, or `kubectl get pod whoami -o jsonpath='{.spec.nodeName} {.status.podIP}'`.
3. Edit `env: test`, `kubectl apply -f my-pod.yaml`, `kubectl get pod whoami --show-labels`. Labels *are* changeable.
4. Changing `image` on a Pod is actually one of the few allowed in-place changes. It works, and
   the container restarts with the new image (`RESTARTS` goes up). But try changing `ports` or
   adding an `env` var and you get `Forbidden: pod updates may not change fields other than...`.
   Lesson: Pods are designed to be **replaced, not edited**. Deployments do the replacing for you.
</details>

---

**Next:** [Lesson 04: Deployments](../04-deployments/README.md)
