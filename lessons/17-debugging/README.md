# Lesson 17: Debugging running workloads

**Time:** 45 minutes · **Goal:** investigate a container that has no shell, a container that
won't stay up, and a node, without changing the app or its image.

## Why this matters at work

Lesson 14 gave you a method, and in every exercise `kubectl exec ... -- sh` worked. At work it
often won't:

- **Production images have no shell.** Security teams push "distroless" images containing only the
  application: no `sh`, no `curl`, no `ps`. Fewer tools means fewer vulnerabilities to patch, and
  nothing for an attacker to use.
- **A crashing container can't be exec'd into.** It isn't running long enough.
- **You may not rebuild the image** just to add debugging tools, and you shouldn't in production.

`kubectl debug` solves all three. It has three modes, and this lesson uses each once.

```bash
kubectl apply -f lessons/17-debugging/apps.yaml
kubectl rollout status deploy/minimal
```

## 1. The problem

```bash
kubectl exec deploy/minimal -- sh
```

```
exec failed: unable to start container process: exec: "sh": executable file not found in $PATH
```

There's no shell in that image. Read [`apps.yaml`](apps.yaml) for the two apps you'll debug.

## 2. Mode one: an ephemeral container, for running Pods

An **ephemeral container** is a temporary extra container that Kubernetes adds to a Pod that's
*already running*. No restart, no change to the Deployment. You choose its image, so you bring
your own tools.

Get the Pod's name, then attach a busybox container to it:

```bash
kubectl get pods -l app=minimal
kubectl debug -it <pod-name> --image=busybox:1.37 --target=app
```

You get a shell *inside the Pod*. Try:

```sh
wget -qO- http://localhost:8080      # same network as the app: 'localhost' IS the app
ps                                   # --target=app shares its process list: you see /whoami as PID 1
ls /proc/1/root/                     # the app container's filesystem, through its process
cat /proc/1/environ | tr '\0' '\n'   # the environment the app really got
exit
```

What you just used:

| You can see | Because |
|---|---|
| The app on `localhost` | All containers in a Pod share one network namespace (lesson 03) |
| The app's processes | `--target=app` joins that container's process namespace |
| The app's files | `/proc/<pid>/root` is a view into another process's filesystem |

Things to know:

- An ephemeral container **can't be removed** and has no resource requests. It disappears when the
  Pod is deleted. For a Deployment's Pod, just `kubectl delete pod <pod-name>` when you're done.
- It needs the `pods/ephemeralcontainers` permission, which many companies grant more
  sparingly than `exec`. If you get `Forbidden`, that's RBAC (lesson 12), and the next mode may be allowed.
- For network problems, teams keep a tools image for this (`nicolaka/netshoot` is the well-known
  public one: `tcpdump`, `dig`, `curl`, `iperf`).

Without `-it` you can run a single command and read its output from the logs, which is how
scripts and CI do it:

```bash
kubectl debug <pod-name> --image=busybox:1.37 --target=app --container=probe -- wget -qO- http://localhost:8080
kubectl logs <pod-name> -c probe
```

## 3. Mode two: a copy of the Pod, for containers that crash

```bash
kubectl get pod crasher
kubectl logs crasher
kubectl logs crasher --previous
```

`CrashLoopBackOff`, and the log says it can't read a settings file. Suppose that isn't enough
and you want to look around inside. You can't exec into it. An ephemeral container doesn't help
much either, because the thing you want to inspect keeps dying.

So make a **copy** of the Pod in which the container runs a different command:

```bash
kubectl debug crasher -it --copy-to=crasher-debug --container=app -- sh
```

Same image, same volumes, same environment, same ServiceAccount, but the container runs `sh`
instead of the crashing program. Now look for what the app was missing:

```sh
ls /etc/app            # No such file or directory: the mount is missing
env
exit
```

The original Pod is untouched, and so is its crash loop, which is what you want while
investigating: the evidence stays in place.

Other useful forms of the same mode:

```bash
kubectl debug <pod> --copy-to=<name> --set-image=app=myapp:debug     # same Pod, an image with tools
kubectl debug <pod> -it --copy-to=<name> --image=busybox:1.37 --share-processes   # add a tools container to the copy
```

> **The copy is a real Pod.** If it keeps the original's labels, the Service will send it
> production traffic. `kubectl debug --copy-to` drops the labels by default for that reason. Leave it that way.

```bash
kubectl delete pod crasher-debug
```

## 4. Mode three: a node

Sometimes the problem is under the Pods: a full disk, a broken container runtime. Without SSH
access to nodes (normal in managed clouds) you can still get onto one:

```bash
kubectl debug node/lessons-worker -it --image=busybox:1.37
```

This starts a Pod on that node using the node's network and process namespaces, with the node's
entire filesystem mounted at `/host`:

```sh
cat /host/etc/os-release
df -h /host/var/lib/containerd       # is the node's disk full?
ls /host/var/log/pods                # the raw log files 'kubectl logs' reads from
exit
```

That is root-level read access to the machine: every Secret mounted into any Pod on that node is
readable from here. This is why node debugging is restricted to cluster admins almost everywhere,
and why "can create privileged Pods" is equivalent to "is admin of the node" (lesson 12).

Node debug Pods are left behind as `Completed`. Find and remove them:

```bash
kubectl get pods
kubectl delete pod <node-debugger-lessons-worker-...>
```

## 5. The rest of the toolkit

Commands from earlier lessons, collected with the flags that matter under pressure:

| Question | Command |
|---|---|
| What happened to this Pod, in order? | `kubectl events --for pod/<name>` (add `--watch`) |
| What happened in this namespace recently? | `kubectl events --types=Warning` |
| Why did the *previous* container die? | `kubectl logs <pod> --previous` |
| Logs of all replicas at once, labelled | `kubectl logs -l app=web --prefix --tail=20 -f` |
| Logs since an incident started | `kubectl logs <pod> --since=15m --timestamps` |
| What exit code, how many restarts? | `kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState}'` |
| Who's using the CPU/memory? | `kubectl top pods --sort-by=memory` / `kubectl top pods --containers` |
| Reach a Pod's port from my laptop | `kubectl port-forward pod/<name> 8080:8080` |
| Copy a file out (image needs `tar`) | `kubectl cp <pod>:/path/file ./file` |
| What YAML is *actually* running? | `kubectl get pod <pod> -o yaml` (compare with what you think you deployed) |
| Am I even allowed to do this? | `kubectl auth can-i create pods/ephemeralcontainers` |

Exit codes worth memorising: **137** = killed with SIGKILL (usually `OOMKilled`, lesson 09),
**143** = SIGTERM (normal shutdown), **1/2** = the app's own error, **127** = command not found
(wrong `command:` or image), **126** = found but not executable.

## Debugging in production: the etiquette

- **Look first, change last.** `get`, `describe`, `logs`, `events` and `top` change nothing.
- **Prefer a copy over the real Pod** when you need to poke at something.
- **Say what you're doing** in the incident channel before you exec into or debug a production Pod. Many companies audit-log it anyway.
- **Never fix production by hand** (`kubectl edit`, `kubectl set image`). The next deploy silently undoes it, and nobody knows why it broke again. Fix it in Git.
- **Delete your debug Pods.** They hold a copy of the app's Secrets.

## Clean up

```bash
kubectl delete -f lessons/17-debugging/apps.yaml
kubectl delete pod crasher-debug --ignore-not-found
```

## Exercises

1. Using an ephemeral container, find the value of the `KUBERNETES_SERVICE_HOST` variable that the `minimal` app sees.
2. In the copy of `crasher`, create `/etc/app/settings.conf` by hand and run the original startup command. Does it stay up? What's the *real* fix?
3. Use `kubectl debug node/...` to find the log file of the `minimal` Pod on its node's disk.
4. Why does `kubectl debug <pod> --image=busybox:1.37` **without** `--target` not show the app's processes in `ps`?

<details>
<summary>Answers</summary>

1. `kubectl debug -it <pod> --image=busybox:1.37 --target=app`, then
   `cat /proc/1/environ | tr '\0' '\n' | grep KUBERNETES_SERVICE_HOST`. Plain `env` shows the
   debug container's own environment, which here happens to contain the same variable, but for
   app-specific variables only `/proc/1/environ` tells the truth.
2. `mkdir -p /etc/app && echo ok > /etc/app/settings.conf`, then run the script from `apps.yaml`:
   it prints the file and sleeps. That proves the diagnosis, but it fixes nothing: the file exists
   only in this copy. The real fix is in the manifest: a ConfigMap with `settings.conf`, mounted at `/etc/app` (lesson 06).
3. Find the node with `kubectl get pod -l app=minimal -o wide`, debug that node, then
   `ls /host/var/log/pods/` and look for `default_minimal-...`. The log is `app/0.log` inside it.
4. Each container has its own process namespace unless told otherwise. `--target=<container>`
   makes the ephemeral container join that container's namespace. (A Pod can also set
   `shareProcessNamespace: true` for all its containers.)
</details>

---

**Next:** [Lesson 18: Working on shared clusters](../18-shared-clusters/README.md)
