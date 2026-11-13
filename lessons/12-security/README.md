# Lesson 12: Security: RBAC, security contexts, network policies

**Time:** 60 minutes · **Goal:** know the four security controls every Kubernetes engineer is
expected to understand, and see each one block something.

| Control | Answers | Default if you do nothing |
|---|---|---|
| **RBAC** | *Who* can do *what* to the Kubernetes API? | Pods' ServiceAccounts can do (almost) nothing, which is good |
| **securityContext** | What may the *container process* do on the node? | Runs as whatever user the image says, often **root** |
| **Pod Security Admission** | Does the cluster *refuse* unsafe Pods? | Nothing is refused |
| **NetworkPolicy** | Which Pods may talk to which? | **Everything can talk to everything** |

## 1. Pod Security Admission + securityContext

[`namespace.yaml`](namespace.yaml) creates a namespace labelled
`pod-security.kubernetes.io/enforce: restricted`, the strictest built-in
[Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/).

```bash
kubectl apply -f lessons/12-security/namespace.yaml
kubectl apply -f lessons/12-security/insecure-pod.yaml
```

```
Error from server (Forbidden): ... violates PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false),
  unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]),
  runAsNonRoot != true ..., seccompProfile ...
```

The error tells you exactly what's missing. [`secure-app.yaml`](secure-app.yaml) fixes every point:

```bash
kubectl apply -f lessons/12-security/secure-app.yaml
kubectl rollout status deploy/backend -n secure
```

Read the `securityContext` blocks in that file; each line has a comment. Why each matters:

- **`runAsNonRoot`**: if an attacker breaks out of a root container, they're root on the node.
- **`readOnlyRootFilesystem`**: an attacker can't download tools or modify the app's files. (Apps
  that need to write get an `emptyDir` mounted at a specific path, e.g. `/tmp`.)
- **`capabilities: drop: ["ALL"]`** and **`allowPrivilegeEscalation: false`**: remove the root-like
  powers that are left.
- **`automountServiceAccountToken: false`**: the Pod gets no API credentials it doesn't need.

> Many official images (like `nginx`) run as root by default and won't work under `restricted`
> without changes. That's why "unprivileged" image variants exist (e.g. `nginxinc/nginx-unprivileged`).
> Checking whether an image runs as non-root is a normal part of choosing images at work.

Roll it out gently on existing clusters: label namespaces with `pod-security.kubernetes.io/warn: restricted`
first. Kubernetes then *warns* on violations without blocking, so you can find and fix them before enforcing.

## 2. RBAC: who can do what

Every request to the API server is checked: is **this identity** allowed to do **this verb**
on **this resource** in **this namespace**?

| Object | Meaning |
|---|---|
| **ServiceAccount** | An identity for *software* (Pods). Humans come from your company's identity provider |
| **Role** / **ClusterRole** | A list of allowed verbs on resources, in one namespace / cluster-wide |
| **RoleBinding** / **ClusterRoleBinding** | Grants a Role to a ServiceAccount, user or group |

Read [`rbac.yaml`](rbac.yaml): a `pod-reader` ServiceAccount that may read Pods and their logs
in `secure`, and nothing else. Plus a Pod running *as* that ServiceAccount.

```bash
kubectl apply -f lessons/12-security/rbac.yaml
kubectl wait --for=condition=Ready pod/api-client -n secure
```

Ask the API server what it would allow, impersonating the ServiceAccount:

```bash
kubectl auth can-i list pods    -n secure --as=system:serviceaccount:secure:pod-reader
kubectl auth can-i list secrets -n secure --as=system:serviceaccount:secure:pod-reader
kubectl auth can-i delete pods  -n secure --as=system:serviceaccount:secure:pod-reader
kubectl auth can-i --list       -n secure --as=system:serviceaccount:secure:pod-reader
```

Now for real: from inside the Pod, call the API with its own token (the script is mounted from a ConfigMap in `rbac.yaml`):

```bash
kubectl exec -n secure api-client -- sh /scripts/call-api.sh /api/v1/namespaces/secure/pods
kubectl exec -n secure api-client -- sh /scripts/call-api.sh /api/v1/namespaces/secure/secrets
kubectl exec -n secure api-client -- sh /scripts/call-api.sh /api/v1/namespaces/default/pods
```

`200`, `403`, `403`. Allowed exactly what the Role says, and nothing else.

**Principles to take to work:**
- **Least privilege.** Grant the narrowest verbs/resources/namespaces that work.
- **`cluster-admin` is root for the whole cluster.** Very few humans and almost no apps should have it.
- **Reading Secrets ≈ having every password in the namespace.** Treat `get secrets` as highly privileged.
- **Watch for "escalation" verbs:** `create pods` (run anything with any ServiceAccount in the namespace),
  `escalate`, `bind`, `impersonate`. They're more powerful than they look.
- **Humans** normally get access through groups from your identity provider (Entra ID, Okta,
  AWS IAM), bound to ClusterRoles like the built-in `view` and `edit`.

## 3. NetworkPolicies: who can talk to whom

By default, **any Pod can connect to any other Pod in the cluster**. If one app is compromised,
the attacker can reach your databases directly. NetworkPolicies are firewall rules, selected by labels.

[`clients.yaml`](clients.yaml) creates two identical Pods; only their `role` label differs.

```bash
kubectl apply -f lessons/12-security/clients.yaml
kubectl wait --for=condition=Ready pod/frontend pod/intruder
```

Before any policy, both can reach the backend:

```bash
kubectl exec frontend -- curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://backend.secure
kubectl exec intruder -- curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://backend.secure
```

Apply [`netpol.yaml`](netpol.yaml): default-deny for the namespace, plus an allow rule for `role=frontend` on port 80:

```bash
kubectl apply -f lessons/12-security/netpol.yaml
kubectl exec frontend -- curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://backend.secure
kubectl exec intruder -- curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://backend.secure
```

`frontend` gets `200`. `intruder` times out (`000` and `exit code 28`), because its packets are silently dropped.

> **NetworkPolicies need a network plugin that enforces them.** kind's default plugin
> (kindnet) does. Some setups silently ignore policies: you apply them, nothing errors, and
> nothing is blocked. **Always test a policy like we just did.** On cloud clusters, check that
> policy enforcement is enabled (e.g. Calico/Cilium on AKS/EKS, Dataplane V2 on GKE).

Things that trip people up:

- Policies are **allow-lists that add up**. Once any policy selects a Pod for `Ingress`,
  everything not explicitly allowed is denied.
- In `from:`, `namespaceSelector` and `podSelector` **in the same list item** mean AND (as in our
  file). As **two separate items** (two `-` dashes) they mean OR, which is a much wider rule. One dash makes all the difference.
- **Egress** policies (outgoing traffic) must also allow DNS (UDP/TCP 53 to `kube-system`), or nothing can resolve names.

## 4. Other things to know exist

- **Image supply chain:** pin images by version (or digest), scan them (Trivy, Grype), use
  trusted registries, sign them (Sigstore/cosign).
- **Policy engines** (Kyverno, OPA Gatekeeper, or the built-in ValidatingAdmissionPolicy) enforce
  your own rules, e.g. "every Deployment must have resource limits" or "images only from our registry".
- **Secrets management**: see lesson 06.
- **Audit logs** on the API server record who did what. Managed clouds can ship them to your SIEM.
- [Kubernetes security checklist](https://kubernetes.io/docs/concepts/security/security-checklist/) (official, short, worth reading).

## Clean up

```bash
kubectl delete -f lessons/12-security/clients.yaml
kubectl delete namespace secure
```

## Exercises

1. Remove `readOnlyRootFilesystem: true` from `secure-app.yaml` and apply. Is it still allowed in a
   `restricted` namespace? What does that tell you about Pod Security Standards vs best practice?
2. Give `pod-reader` permission to also read **Services**, and verify with `kubectl auth can-i`.
3. Allow the `intruder` Pod too, **without** editing `netpol.yaml` (Hint: labels.) What does that
   suggest about who should be allowed to set labels on Pods?
4. Change `netpol.yaml` so `namespaceSelector` and `podSelector` are two separate list items. Which Pods can reach the backend now?

<details>
<summary>Answers</summary>

1. Yes, it's allowed. The `restricted` standard doesn't require a read-only root filesystem; it's
   recommended practice, not part of the standard. Pod Security Standards are a baseline, not the whole of hardening.
2. Add `"services"` to the Role's `resources` list (or add a second rule), apply, then
   `kubectl auth can-i list services -n secure --as=system:serviceaccount:secure:pod-reader` → `yes`.
3. `kubectl label pod intruder role=frontend --overwrite`, and now it's allowed. Policies trust
   labels, so **anyone who can create or label Pods can grant themselves network access**. That's
   one more reason to restrict `create pods`/`patch pods` via RBAC, and to use namespace-scoped rules where possible.
4. `- namespaceSelector: {}` alone matches **every Pod in every namespace**, and it's ORed with the podSelector
   item, so both `frontend` and `intruder` (and everything else) get in. The policy is effectively open.
</details>

---

**Next:** [Lesson 13: Jobs, CronJobs and autoscaling](../13-jobs-autoscaling/README.md)
