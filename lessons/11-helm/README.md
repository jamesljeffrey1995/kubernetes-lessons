# Lesson 11: Helm, packaging your app

**Time:** 50 minutes · **Goal:** install, configure, upgrade and roll back apps with Helm, and
understand a chart well enough to write your own.

## The problem Helm solves

By now an app is a Deployment + Service + HTTPRoute + ConfigMap + ... And you need it in dev
(1 replica, `hello-dev.localhost`) and prod (3 replicas, more memory, `hello-prod.localhost`).
Copy-pasting YAML per environment drifts and breaks.

**Helm** is the Kubernetes package manager:

- A **chart** is a folder of YAML **templates** plus default **values**.
- You **install** a chart with your own values → that creates a **release** (a named instance).
- Helm records every **revision** of a release, so you can **upgrade** and **roll back** as one unit.
- Thousands of ready-made charts exist (databases, monitoring, ingress controllers...). At work,
  most third-party software gets installed with Helm.

(Helm 3 and Helm 4 both work for everything in this course.)

## 1. Anatomy of a chart

```
lessons/11-helm/
├── hello/                     <- the chart
│   ├── Chart.yaml             name, chart version, app version
│   ├── values.yaml            default settings
│   └── templates/
│       ├── _helpers.tpl       reusable snippets (names, labels)
│       ├── deployment.yaml    templates: YAML with {{ placeholders }}
│       ├── service.yaml
│       ├── httproute.yaml     only rendered if route.enabled is true
│       └── NOTES.txt          message printed after install
├── values-dev.yaml            per-environment overrides
└── values-prod.yaml
```

Open [`hello/templates/deployment.yaml`](hello/templates/deployment.yaml) next to
[`hello/values.yaml`](hello/values.yaml). Templates use Go templating:

| Syntax | Meaning |
|---|---|
| `{{ .Values.replicaCount }}` | Insert a value from values.yaml (or overrides) |
| `{{ .Release.Name }}` | The release name you chose at install time |
| `{{ .Chart.AppVersion }}` | From Chart.yaml |
| `{{ .Values.image.tag \| default .Chart.AppVersion }}` | Use a fallback when empty |
| `{{ include "hello.labels" . \| nindent 4 }}` | Insert a helper, indented 4 spaces on a new line |
| `{{- if .Values.route.enabled }} ... {{- end }}` | Conditional block (`-` trims whitespace) |
| `{{- with .Values.resources }} {{ toYaml . }} {{- end }}` | Dump a whole values block as YAML |

## 2. See what Helm would generate: `template` and `lint`

**Always look at the rendered output before installing.** It's how you debug charts.

```bash
helm lint lessons/11-helm/hello
helm template demo lessons/11-helm/hello
helm template demo lessons/11-helm/hello -f lessons/11-helm/values-prod.yaml
```

Compare the `replicas:` and hostnames between the last two. Nothing is sent to the cluster.

## 3. Install two environments from one chart

```bash
helm install hello-dev  lessons/11-helm/hello -n dev  --create-namespace -f lessons/11-helm/values-dev.yaml
helm install hello-prod lessons/11-helm/hello -n prod --create-namespace -f lessons/11-helm/values-prod.yaml
helm list -A
kubectl get deploy -n dev
kubectl get deploy -n prod
```

Open <http://hello-dev.localhost:8080> and <http://hello-prod.localhost:8080>. The `Name:` line
shows `hello-DEV` vs `hello-PROD`. **Same chart, different values.**

Value precedence (later wins): chart `values.yaml` → `-f file1.yaml` → `-f file2.yaml` → `--set`.

## 4. Upgrade, history, rollback

Change a setting:

```bash
helm upgrade hello-prod lessons/11-helm/hello -n prod -f lessons/11-helm/values-prod.yaml --set replicaCount=4 --wait
kubectl get deploy -n prod
```

> ⚠️ On every `upgrade`, pass the **same `-f` files** again. Helm computes values fresh each time.
> Forget `-f values-prod.yaml` and prod silently reverts to the chart defaults. (There's a
> `--reuse-values` flag, but it has surprising edge cases. Being explicit is safer, and
> exactly what CI/CD pipelines do.)

Now ship a broken release (an image tag that doesn't exist), with `--wait` so Helm watches it become ready:

```bash
helm upgrade hello-prod lessons/11-helm/hello -n prod -f lessons/11-helm/values-prod.yaml --set image.tag=v9.9.9 --wait --timeout 60s
```

After 60s: `UPGRADE FAILED: context deadline exceeded` (Helm 4 adds the reason: `not ready`).
Meanwhile the old Pods keep serving (the rolling update protects you, lesson 04). See the record and roll back:

```bash
helm history hello-prod -n prod
helm rollback hello-prod 2 -n prod --wait
kubectl get deploy -n prod -o wide
```

```
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         superseded  Upgrade complete
3         failed      Upgrade "hello-prod" failed: ...
4         deployed    Rollback to 2
```

Unlike `kubectl rollout undo` (one Deployment), **Helm rolls back every object in the release
together**: Deployment, Service, route, ConfigMaps...

> **Tip:** `helm upgrade --install` installs if missing and upgrades otherwise. It's the one
> command CI/CD pipelines use. Add `--atomic` (Helm 3) / `--rollback-on-failure` (Helm 4) to
> roll back automatically when `--wait` fails.

Other useful commands:

```bash
helm get values hello-prod -n prod        # the values YOU supplied
helm get manifest hello-prod -n prod      # the exact YAML Helm applied
helm status hello-prod -n prod
```

## 5. Installing someone else's chart

Public charts live in chart repositories or OCI registries. For example
[podinfo](https://github.com/stefanprodan/podinfo), a demo app used in lots of tutorials:

```bash
helm show values oci://ghcr.io/stefanprodan/charts/podinfo      # read the knobs first!
helm install podinfo oci://ghcr.io/stefanprodan/charts/podinfo -n podinfo --create-namespace --set replicaCount=2
kubectl get pods -n podinfo
helm uninstall podinfo -n podinfo
```

Classic (non-OCI) repositories work like this: `helm repo add <name> <url>`, `helm repo update`,
`helm install <release> <name>/<chart>`.

> **At work:** before installing a public chart, read its `values.yaml`, pin a `--version`
> (otherwise you get whatever is latest), and check what images it pulls and from where.
> A chart runs with whatever permissions you give Helm.

## 6. Helm vs Kustomize (you'll hear both)

**Kustomize** (built into kubectl: `kubectl apply -k`) takes the other approach: no templates.
Plain YAML "bases" plus "overlays" that patch them per environment. Rough rule of thumb:

- **Helm**: packaging and distributing apps, especially third-party ones, and when you need logic (if/else, loops).
- **Kustomize**: small per-environment tweaks to your own plain YAML.
- Many teams use both. GitOps tools (Argo CD, Flux) support both.

## Clean up

```bash
helm uninstall hello-dev -n dev
helm uninstall hello-prod -n prod
kubectl delete namespace dev prod
```

## Exercises

1. Add a `values-test.yaml` (2 replicas, name `hello-TEST`, host `hello-test.localhost`) and install a `hello-test` release in namespace `test`.
2. Install with `--set route.enabled=false`. What changes in `helm template` output, and how does NOTES.txt adapt?
3. Add a ConfigMap template to the chart whose content comes from a new value `message`, and
   bump `version` in `Chart.yaml` to `0.2.0`. Upgrade a release and check `helm history`.
4. Run `helm template x lessons/11-helm/hello --set replicaCount=abc`, then `helm lint` with the same `--set`. Which catches it? What would catch it reliably? (Hint: look up `values.schema.json`.)

<details>
<summary>Answers</summary>

1. ```yaml
   replicaCount: 2
   greetingName: "hello-TEST"
   route:
     hostname: hello-test.localhost
   ```
   `helm install hello-test lessons/11-helm/hello -n test --create-namespace -f values-test.yaml`
2. The HTTPRoute disappears from the output, and the install notes print the `port-forward` hint instead of a URL.
3. `templates/configmap.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: {{ include "hello.fullname" . }}
     labels:
       {{- include "hello.labels" . | nindent 4 }}
   data:
     message: {{ .Values.message | default "hi" | quote }}
   ```
   `helm upgrade ... --set message=hello` then `helm history` shows a new revision with chart `hello-0.2.0`.
4. Both render `replicas: abc` happily; neither checks types. The API server would reject it at
   install time. A **`values.schema.json`** in the chart (JSON Schema) makes Helm validate values
   on lint/template/install. The capstone chart includes one.
</details>

---

**Next:** [Lesson 12: Security: RBAC, security contexts, network policies](../12-security/README.md)
