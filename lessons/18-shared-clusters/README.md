# Lesson 18: Working on shared clusters

**Time:** 45 minutes · **Goal:** work the way you will on day one of a real job: with a
kubeconfig someone gave you, limited permissions, several clusters, and other people's workloads
next to yours.

## Why this matters at work

Until now you were `cluster-admin` on a cluster nobody else uses. At work it's the opposite:

- You get access to **one or a few namespaces**, not the cluster.
- There are **several clusters** (dev, staging, prod, maybe per region), and your kubectl can
  talk to all of them. The one it talks to *right now* is a line in a file.
- Most production accidents with kubectl are not exotic. They are the right command run against
  the wrong cluster or namespace.

## 1. What a kubeconfig is

```bash
kubectl config view --minify
kubectl config get-contexts
```

A kubeconfig file (`~/.kube/config` by default) has three lists and one pointer:

```
clusters:   where       an API server URL + the CA certificate to trust
users:      who         a credential: client certificate, token, or a login plugin (SSO)
contexts:   a named triple of  cluster + user + default namespace
current-context:        the one kubectl uses when you don't say otherwise
```

A context is only a shortcut. `kubectl --context X` beats `current-context`, and `-n` beats the
context's namespace.

When your company gives you "access to the cluster", you get one of: a kubeconfig file, a
command that writes one (`aws eks update-kubeconfig`, `az aks get-credentials`,
`gcloud container clusters get-credentials`), or a login plugin such as `kubelogin`. Several
files can be combined without merging them by hand:

```bash
# bash
export KUBECONFIG=~/.kube/config:~/.kube/work-prod.yaml
```
```powershell
# PowerShell (the separator is ; on Windows)
$env:KUBECONFIG = "$HOME\.kube\config;$HOME\.kube\work-prod.yaml"
```

## 2. Become a developer with limited access

Read [`team.yaml`](team.yaml): a namespace, an identity called `developer`, and a Role that
describes what the platform team allows it to do. Create it (as admin), and start the team's app:

```bash
kubectl apply -f lessons/18-shared-clusters/team.yaml
kubectl apply -f lessons/18-shared-clusters/app.yaml
```

Now build the kubeconfig entry a developer would be given: a short-lived token and a context.

**bash:**
```bash
TOKEN=$(kubectl create token developer -n team-payments --duration=8h)
kubectl config set-credentials payments-dev --token="$TOKEN"
kubectl config set-context payments-dev --cluster=kind-lessons --user=payments-dev --namespace=team-payments
```

**PowerShell:**
```powershell
$TOKEN = kubectl create token developer -n team-payments --duration=8h
kubectl config set-credentials payments-dev --token="$TOKEN"
kubectl config set-context payments-dev --cluster=kind-lessons --user=payments-dev --namespace=team-payments
```

Switch to it:

```bash
kubectl config use-context payments-dev
kubectl config get-contexts
kubectl auth whoami
```

`whoami` shows `system:serviceaccount:team-payments:developer`. From here until section 5,
**you are that developer.** (Real clusters use your company login instead of a ServiceAccount
token. Everything else is identical.)

## 3. Find out what you may do

```bash
kubectl get pods
kubectl get secrets
kubectl get pods -n kube-system
kubectl get nodes
```

The first works, and uses `team-payments` without `-n` because the context says so. The others fail like this:

```
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:team-payments:developer"
cannot list resource "secrets" in API group "" in the namespace "team-payments"
```

**Read that message as five facts**: *who* (the user), *verb* (list), *resource* (secrets),
*API group* (`""` = core) and *where* (namespace). It is exactly the line of a Role you're missing.
When you ask the platform team for access, paste the whole message. It saves a round trip.

Instead of trial and error:

```bash
kubectl auth can-i --list
kubectl auth can-i delete deployments
kubectl auth can-i create pods/exec
kubectl auth can-i get secrets
kubectl auth can-i get pods -n kube-system
```

`Forbidden` (HTTP 403) means *you're known, but not allowed*. `Unauthorized` (401) means *the
cluster doesn't know who you are*: an expired token or SSO session. Tokens made with
`kubectl create token` expire (here after 8 hours). Then every command fails with
`error: You must be logged in to the server (Unauthorized)`. Log in again; don't ask for more rights.

## 4. Change something without surprises

You want to go from 2 to 3 replicas and raise the memory limit. The change is in
[`app-change.yaml`](app-change.yaml). Before applying anything to a cluster other people use,
answer two questions.

**"What exactly will change?"**

```bash
kubectl diff -f lessons/18-shared-clusters/app-change.yaml
```

```diff
-  replicas: 2
+  replicas: 3
...
-            memory: 32Mi
+            memory: 48Mi
```

`diff` asks the server to work out the result and shows only the differences from what's
running now, including changes somebody else made by hand since your last deploy. (It needs a
`diff` program on your PATH. Linux and macOS have one; on Windows, Git Bash does. If it's
missing, use the next command with `-o yaml` instead.)

**"Will the cluster accept it?"**

```bash
kubectl apply --dry-run=server -f lessons/18-shared-clusters/app-broken.yaml
```

```
The Deployment "api" is invalid:
* spec.template.spec.containers[0].imagePullPolicy: Unsupported value: "Sometimes"...
* spec.template.spec.containers[0].resources.requests: Invalid value: "64Mi": must be less than or equal to memory limit of 48Mi
```

`--dry-run=server` sends the object through the real API server (validation, admission
policies, quotas, your permissions) and stops just before saving it. `--dry-run=client` only
checks that the YAML has the right shape, and would miss these errors. Read
[`app-broken.yaml`](app-broken.yaml) to see how plausible both mistakes look.

Now make the real change and watch it:

```bash
kubectl apply -f lessons/18-shared-clusters/app-change.yaml
kubectl rollout status deploy/api
```

### Guard rails you'll run into

The namespace has a ResourceQuota of 6 Pods (lesson 07). Try to exceed it:

```bash
kubectl scale deploy/api --replicas=8
kubectl get deploy api
kubectl events --types=Warning
kubectl describe resourcequota
```

The command succeeds, but only 6 Pods exist, and the events say `exceeded quota`. A Deployment
that silently stays below its replica count is how quotas show up in real life. Check events
before you assume the cluster is broken.

```bash
kubectl scale deploy/api --replicas=3
```

## 5. Habits that prevent accidents

Switch back to your admin context first:

```bash
kubectl config use-context kind-lessons
```

| Habit | How |
|---|---|
| **Always know where you are** | `kubectl config current-context`. Better: put context and namespace in your shell prompt (`kube-ps1`, Starship, oh-my-posh all do it) |
| **Name the context for anything destructive** | `kubectl --context prod -n payments delete pod ...`. It reads as a sentence and can't hit the wrong cluster |
| **Don't keep prod as your current context** | Switch to it for a task, switch back after. Some teams keep prod in a separate kubeconfig file that isn't loaded by default |
| **Make prod look different** | A red prompt or terminal profile for production contexts |
| **Delete by file or label, never from memory** | `kubectl delete -f app.yaml` removes what that file created. Typing names, or `--all`, removes whatever happens to match |
| **`diff` and `--dry-run=server` before `apply`** | Section 4 |
| **Read-only by default** | Ask for a read-only role for daily use and a separate, deliberate step for write access to prod. Many companies enforce this |
| **Let the pipeline deploy** | In a healthy setup humans don't `kubectl apply` to production at all. A CI/CD pipeline or a GitOps tool (Argo CD, Flux) applies what's in Git. Your kubectl is for looking and for emergencies |

Tools people actually use: **kubectx / kubens** (switch context and namespace quickly), **k9s**
(a terminal UI), and `kubectl config set-context --current --namespace=<ns>` (stay in a namespace
without typing `-n`).

For admins: `kubectl --as=system:serviceaccount:team-payments:developer get secrets` runs a
command as someone else, without their credentials. It's the quickest way to answer "can they
really not do that?"

## Clean up

```bash
kubectl config use-context kind-lessons
kubectl config delete-context payments-dev
kubectl config unset users.payments-dev
kubectl delete namespace team-payments
```

## Exercises

1. As the developer, try `kubectl exec` into an `api` Pod and `kubectl delete pod` on one. Which
   lines of the Role allow each? Why might a company allow `delete pod` but not `exec`?
2. As the developer, try to give yourself more rights:
   `kubectl create rolebinding me-admin --clusterrole=admin --serviceaccount=team-payments:developer`. What happens, and why does that matter?
3. As admin, use `--as` to check whether the developer can read ConfigMaps in `team-payments`
   and in `default`.
4. Your token expired while you were at lunch. What does the error look like, and what's the fix?
5. A colleague says: "the Role lets developers `get` pods but they still can't see Pod logs."
   What's missing?

<details>
<summary>Answers</summary>

1. `pods/exec` with verb `create` allows exec, and `pods` with verb `delete` allows deleting.
   Deleting a Pod of a Deployment is harmless (it's recreated) and is the standard "restart
   it" move. Exec gives a shell inside a production container, with its Secrets, database
   credentials and network access, so it's often restricted or audited.
2. `Forbidden`: the Role has no rights on `rolebindings`. Kubernetes also refuses to let anyone
   grant permissions they don't hold themselves (*privilege escalation prevention*), so even
   with rights on `rolebindings` a developer couldn't bind `admin`.
3. `kubectl auth can-i get configmaps -n team-payments --as=system:serviceaccount:team-payments:developer`
   → `yes`; the same with `-n default` → `no`. A Role only ever applies inside its own namespace.
4. `error: You must be logged in to the server (Unauthorized)`. Get a new token (here:
   `kubectl create token ...` and `set-credentials` again, as admin; at work: log in again via SSO).
5. `pods/log` is a separate *subresource*. It must be listed in `resources` next to `pods`.
   The same goes for `pods/exec`, `pods/portforward` and `deployments/scale`.
</details>

---

**Next:** [Lesson 19: Observability with Prometheus](../19-observability/README.md)
