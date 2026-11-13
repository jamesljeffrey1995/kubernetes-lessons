# Lesson 06: ConfigMaps and Secrets

**Time:** 40 minutes · **Goal:** keep configuration out of your container images, and know
what Secrets do and (importantly) don't protect.

## Why

Build **one** image and run it in dev, test and prod with different settings. The image
contains code; the environment supplies the config. (This is factor III of the
"[twelve-factor app](https://12factor.net/config)", a phrase worth knowing at work.)

- **ConfigMap**: non-sensitive settings (log level, feature flags, URLs, whole config files).
- **Secret**: sensitive values (passwords, API keys, TLS certificates).

## 1. Apply and inspect

Read [`config.yaml`](config.yaml) and [`deployment.yaml`](deployment.yaml). The deployment shows
the four common ways to inject config (numbered in the comments).

```bash
kubectl apply -f lessons/06-config-secrets/
kubectl rollout status deploy/config-demo
```

Environment variables inside the container:

```bash
kubectl exec deploy/config-demo -- env
```

(`deploy/config-demo` means "any Pod of that Deployment", which saves copying Pod names.)
Find `GREETING`, `LOG_LEVEL`, `APP_LOG_LEVEL`, `DB_PASSWORD`, `ENVIRONMENT` and `POD_NAME`.

Files:

```bash
kubectl exec deploy/config-demo -- cat /usr/share/nginx/html/index.html
kubectl exec deploy/config-demo -- ls /etc/app-secrets
kubectl exec deploy/config-demo -- cat /etc/app-secrets/DB_PASSWORD
```

See the page: `kubectl port-forward deploy/config-demo 8081:80` → <http://localhost:8081>.

## 2. Changing config: files update, env vars don't

Edit [`config.yaml`](config.yaml): change the `<h1>` text **and** `GREETING`. Apply:

```bash
kubectl apply -f lessons/06-config-secrets/config.yaml
```

- **Mounted file:** refresh the page (or re-run the `cat`). Within **about 60 seconds** it shows
  the new text, with no restart. The kubelet syncs mounted ConfigMaps periodically.
- **Env var:** `kubectl exec deploy/config-demo -- printenv GREETING` still shows the **old**
  value. Environment variables are fixed when a process starts.

To pick up env changes, restart the Pods (rolling, zero downtime):

```bash
kubectl rollout restart deploy/config-demo
kubectl rollout status deploy/config-demo
kubectl exec deploy/config-demo -- printenv GREETING
```

> **Gotchas:**
> - Files mounted with `subPath` **never** update. A common surprise.
> - Many apps read their config file only at startup, so an updated file doesn't help them anyway.
> - Helm charts often add a checksum of the ConfigMap as a Pod annotation, so any config change
>   triggers a rolling restart automatically. You'll see this pattern in the capstone chart.

## 3. Secrets are base64, not encrypted

```bash
kubectl get secret app-secret -o yaml
```

The values look scrambled but they're only **base64-encoded**. Decode one:

**bash:**
```bash
kubectl get secret app-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

**PowerShell:**
```powershell
$b64 = kubectl get secret app-secret -o jsonpath='{.data.DB_PASSWORD}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
```

**Both (kubectl does the decoding):**
```bash
kubectl get secret app-secret -o go-template='{{.data.DB_PASSWORD | base64decode}}'
```

So what *do* Secrets give you over ConfigMaps?

- **Separate permissions:** with RBAC (lesson 12), you can let people read ConfigMaps but not Secrets.
- **Encryption at rest** in etcd, *if* the cluster admin enables it. Managed clouds offer it, sometimes by default.
- Kept in memory (tmpfs) on nodes when mounted, not written to disk.
- Kept out of `kubectl describe` output and treated more carefully by tooling.

**Never commit real Secret YAML to Git.** At work you'll meet one of these instead:

| Tool | Idea |
|---|---|
| **External Secrets Operator** | Secrets live in AWS Secrets Manager / Azure Key Vault / Vault; the operator syncs them into the cluster |
| **Sealed Secrets** | Encrypt a Secret with the cluster's public key; the encrypted file is safe to commit |
| **SOPS** (+ age/KMS) | Encrypt YAML values in Git; decrypt at deploy time |
| **Secrets Store CSI Driver** | Mount secrets straight from the cloud vault as files; nothing stored in etcd |

## 4. Generating YAML instead of typing it

kubectl can *write* the YAML for you. `--dry-run=client -o yaml` prints the YAML without creating anything:

```bash
kubectl create configmap demo --from-literal=MODE=fast --from-literal=RETRIES=3 --dry-run=client -o yaml
kubectl create secret generic demo --from-literal=API_KEY=abc123 --dry-run=client -o yaml
kubectl create deployment demo --image=nginx:1.29-alpine --replicas=2 --dry-run=client -o yaml
```

Redirect it into a file (`> demo.yaml`) and edit from there. **This is the fastest way to start
any manifest**, and allowed in Kubernetes certification exams (CKA/CKAD).

`--from-file` turns files into ConfigMap/Secret keys: `kubectl create configmap nginx-conf --from-file=nginx.conf`.

## Clean up

```bash
kubectl delete -f lessons/06-config-secrets/
```

## Exercises

1. Add a key `FEATURE_X: "on"` to `app-config`. Make it show up as env var `FEATURE_X` in the Pod. What did you need to do besides `apply`?
2. Mark the `app-config` ConfigMap `immutable: true` (a top-level field next to `data`), apply, then try changing a value. What happens, and why would anyone want this?
3. What happens if a Pod references a Secret that doesn't exist? Try: change `secretName` to `nope`, apply, and look at the Pod.

<details>
<summary>Answers</summary>

1. Add the key, `kubectl apply -f lessons/06-config-secrets/config.yaml`, then
   `kubectl rollout restart deploy/config-demo`. `envFrom` imports all keys, but only at container start.
2. The API server rejects changes: `field is immutable when 'immutable' is set`. You must delete and
   recreate it (or, better, create `app-config-v2` and point the Deployment at it, which also gives you
   rollback). Immutable ConfigMaps protect against accidental changes and reduce load on the API
   server in large clusters, since kubelets stop watching them.
3. The Pod is stuck in `ContainerCreating`. `kubectl describe pod` shows
   `MountVolume.SetUp failed ... secret "nope" not found`. For env var references the status is
   `CreateContainerConfigError`. Kubernetes won't start a container with missing config, which is the safe default. Notice the
   *old* Pod keeps running: the rolling update never removes a working Pod until its replacement is Ready.
</details>

---

**Next:** [Lesson 07: Namespaces, labels and quotas](../07-namespaces/README.md)
