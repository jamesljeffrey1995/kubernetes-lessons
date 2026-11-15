# Lesson 15: Kustomize: one app, several environments, no templates

**Time:** 40 minutes · **Goal:** deploy the same app to dev and prod from one set of YAML,
and know when to reach for Kustomize instead of Helm.

## Why this matters at work

Lesson 11 solved "same app, different settings per environment" with Helm templates. The other
tool you'll meet in almost every company is **Kustomize**. It is built into kubectl
(`kubectl apply -k`), and Argo CD and Flux both speak it natively. Many teams use both: Helm for
software they install from someone else, Kustomize for their own services.

The idea is the opposite of templating:

```
Helm:       templates with {{ holes }}  +  values            ->  YAML
Kustomize:  plain, valid YAML (a "base") +  patches (an "overlay")  ->  YAML
```

```
lessons/15-kustomize/
├── base/                    what every environment shares
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
└── overlays/
    ├── dev/kustomization.yaml       base + "namespace shop-dev, name it dev"
    └── prod/kustomization.yaml      base + "namespace shop-prod, 3 replicas, more memory, spread out"
```

## 1. Look before you apply

Read [`base/kustomization.yaml`](base/kustomization.yaml) and
[`overlays/dev/kustomization.yaml`](overlays/dev/kustomization.yaml). Then let Kustomize show
you what it would send to the cluster. Nothing is applied yet:

```bash
kubectl kustomize lessons/15-kustomize/overlays/dev
```

Compare with the base files and find the three things the overlay did:

1. Every object got `namespace: shop-dev` and the label `environment: dev`.
2. The ConfigMap is called something like `whoami-config-9kt5g9k9f8`, and the Deployment's
   `configMapRef` points at that exact name.
3. `WHOAMI_NAME` is `dev`, not `base`.

**Get into this habit:** render first, read the output, then apply. It works the same for Helm
(`helm template`).

## 2. Deploy dev and prod

```bash
kubectl apply -k lessons/15-kustomize/overlays/dev
kubectl apply -k lessons/15-kustomize/overlays/prod
kubectl get deploy,pods -n shop-dev
kubectl get deploy,pods -n shop-prod -o wide
```

One Pod in dev, three in prod, spread across your worker nodes. Ask each one who it is
(the toolbox Pod is from earlier lessons: `kubectl apply -f lessons/tools/toolbox.yaml`):

```bash
kubectl exec toolbox -- curl -s http://whoami.shop-dev
kubectl exec toolbox -- curl -s http://whoami.shop-prod
```

The first line of each answer is `Name: dev` or `Name: prod`.

Now read [`overlays/prod/kustomization.yaml`](overlays/prod/kustomization.yaml). It shows the
four tools you'll use most:

| In the file | What it does | Typical use |
|---|---|---|
| `replicas:` | Sets a Deployment's replica count | Bigger in prod |
| `images:` | Replaces an image name or tag everywhere | CI sets the tag of the build it just made |
| `patches:` with `path:` | Merges a YAML fragment into an object | Resources, env vars, annotations |
| `patches:` with inline `patch:` | JSON patch: add/remove/replace at an exact path | Adding to a list, removing a field |

## 3. Config changes that roll out by themselves

In lesson 06 you saw that editing a ConfigMap does **not** restart the Pods using it. Kustomize's
`configMapGenerator` solves that with the hash in the name.

Watch prod's Pods in a second terminal:

```bash
kubectl get pods -n shop-prod -w
```

Edit `overlays/prod/kustomization.yaml`, change `WHOAMI_NAME=prod` to `WHOAMI_NAME=prod-blue`, and:

```bash
kubectl diff -k lessons/15-kustomize/overlays/prod      # what would change? (needs a 'diff' program; skip on Windows if missing)
kubectl apply -k lessons/15-kustomize/overlays/prod
```

A **new** ConfigMap with a different hash is created, the Deployment now refers to it, and that
is a change to the Pod template, so Kubernetes does a normal rolling update. A bad config value
now fails like a bad image: the rollout stops and `kubectl rollout undo` brings back the old
Pods *and* the old config, because the old ConfigMap still exists.

```bash
kubectl get configmap -n shop-prod
kubectl exec toolbox -- curl -s http://whoami.shop-prod
```

Old generated ConfigMaps pile up. `kubectl apply -k ... --prune -l environment=prod` removes
objects that are no longer in the output. GitOps tools do that pruning for you.

Change the file back to `WHOAMI_NAME=prod` when you're done.

## Helm or Kustomize?

| | Helm | Kustomize |
|---|---|---|
| Model | Templates + values | Plain YAML + patches |
| Installing third-party software | **Yes**: charts are the standard package format | Awkward |
| Your own service in 3 environments | Works, but you maintain templates | **Simple**, and every file is valid YAML your editor can check |
| Release history, `rollback`, hooks, tests | Yes | No. It only produces YAML |
| Loops and conditions | Yes | No, on purpose |
| Extra tool to install | `helm` | None (`kubectl -k`) |

A rule of thumb that holds up: **Helm when you need a package, Kustomize when you need
variations.** They also combine: Kustomize can post-process a rendered Helm chart, which is how
teams adjust a vendor chart without forking it.

## Things that go wrong

| Symptom | Cause |
|---|---|
| `no matches for Id Deployment...; failed to find unique target for patch` | The patch's `kind`/`name` doesn't match any object in the base. Typos, or the name was changed by a `namePrefix` |
| The Pods didn't restart after a config change | The ConfigMap is a plain file in `resources:`, not a `configMapGenerator` |
| `kubectl apply -k` changes the Service selector and traffic stops | `labels:` with `includeSelectors: true` (or the old `commonLabels:`) on an app that's already running. Selectors of a Deployment can't be changed after creation |
| Works with `kustomize build` but not with `kubectl apply -k` | kubectl bundles its own, sometimes older, Kustomize. Check with `kubectl version --client` |

## Clean up

```bash
kubectl delete -k lessons/15-kustomize/overlays/dev
kubectl delete -k lessons/15-kustomize/overlays/prod
```

## Exercises

1. Create `overlays/staging`: namespace `shop-staging`, 2 replicas, `WHOAMI_NAME=staging`. Render it before applying.
2. In prod, add an environment variable `LOG_LEVEL=warn` to the container **without** touching the base. (Hint: a patch, or one more literal.)
3. What does `kubectl kustomize lessons/15-kustomize/base` print for the ConfigMap name, and why isn't it just `whoami-config`?
4. Your CI built image tag `v1.12.0`. Which single line of which file changes, and what happens to dev?

<details>
<summary>Answers</summary>

1. Copy `overlays/dev` to `overlays/staging`, change the namespace in both files, the label and
   the literal, and add `replicas: [{name: whoami, count: 2}]`.
2. Easiest: add `- LOG_LEVEL=warn` under the prod `configMapGenerator` literals. The container
   loads the whole ConfigMap with `envFrom`, so the variable appears, and the hash changes, so
   the Pods roll. A patch adding `env:` to the container works too.
3. `whoami-config-<hash>`. Generators always add the content hash, in the base too. That's
   what makes config changes roll out.
4. `newTag:` under `images:` in `overlays/prod/kustomization.yaml`. Dev is unaffected: it has
   no `images:` entry, so it keeps the tag written in the base. Each environment is promoted separately.
</details>

---

**Next:** [Lesson 16: Scheduling and node maintenance](../16-scheduling/README.md)
