# Lesson 20: Extending Kubernetes: CRDs, operators and policies

**Time:** 50 minutes · **Goal:** understand the objects in a real cluster that *aren't* in the
Kubernetes documentation, by building a tiny one yourself, and see how companies enforce house rules.

## Why this matters at work

Run this on any production cluster and you'll get dozens of kinds you haven't met in this course:

```bash
kubectl api-resources
```

`Certificate`, `ServiceMonitor`, `Application`, `ExternalSecret`, `Kafka`, `PostgresCluster`...
None of them are part of Kubernetes. They are **custom resources**, added by the tools your
company installed (cert-manager, Prometheus Operator, Argo CD, External Secrets, Strimzi,
CloudNativePG). Much of your daily work will be writing YAML for *these*.

You've already used some: `Gateway` and `HTTPRoute` from lesson 10 are custom resources.
`cluster-up` installed their definitions from `platform/gateway-api-crds.yaml`, and Traefik is
the controller that acts on them.

They all work the same way, and it's the control loop from lesson 01:

```
CustomResourceDefinition (CRD)   teaches the API server a new kind, with a schema
        +
a controller ("operator")        watches objects of that kind and makes reality match them
        =
a new, declarative API for something Kubernetes knew nothing about
```

## 1. Define a new kind

Read [`crd.yaml`](crd.yaml). It defines `Website`, with a schema: a required `title`, and
`replicas` between 1 and 5.

```bash
kubectl apply -f lessons/20-extending/crd.yaml
kubectl api-resources --api-group=lessons.example.com
kubectl explain website.spec
```

The API server now serves a new endpoint, and `kubectl explain` documents it from the schema you
wrote. Create one from [`website.yaml`](website.yaml):

```bash
kubectl apply -f lessons/20-extending/website.yaml
kubectl get websites
```

```
NAME    TITLE                          REPLICAS   READY   URL
hello   Hello from a custom resource   2
```

The schema is enforced like for built-in kinds. [`website-invalid.yaml`](website-invalid.yaml) asks for 9 replicas:

```bash
kubectl apply -f lessons/20-extending/website-invalid.yaml
```

```
The Website "too-big" is invalid: spec.replicas: Invalid value: 9: spec.replicas in body should be less than or equal to 5
```

Now check what exists for the Website you created:

```bash
kubectl get pods,deploy,svc -l app=website
```

Nothing. **A CRD only stores data.** The API server accepted and saved your Website, and nobody
is acting on it. `READY` and `URL` are empty for the same reason.

## 2. Add the controller

Read [`operator.yaml`](operator.yaml): the `reconcile.sh` loop (20 lines) and `desired.jq`,
which turns a Website into the Deployment, Service and ConfigMap it should have.

```bash
kubectl apply -f lessons/20-extending/operator.yaml
kubectl -n website-operator rollout status deploy/website-operator
```

Within a few seconds:

```bash
kubectl get websites
kubectl get deploy,svc,configmap -l app=website
kubectl exec toolbox -- curl -s http://site-hello
```

```
NAME    TITLE                          REPLICAS   READY   URL
hello   Hello from a custom resource   2          2       http://site-hello.default
```

You wrote 7 lines of intent; the operator produced about 60 lines of Kubernetes objects and
reported back in `status`. That's the whole idea. A PostgreSQL operator does the same with
"I want a 3-node database with backups", only its loop is much longer.

Now see why it's a *loop* and not an install script:

**It follows changes.** Edit `website.yaml`: set `replicas: 3` and change the title. Apply it:

```bash
kubectl apply -f lessons/20-extending/website.yaml
kubectl get deploy site-hello -w
```

**It repairs damage.** Delete something it owns:

```bash
kubectl delete deployment site-hello
kubectl get deploy site-hello
```

It's back within seconds. This is also the answer to a classic confusion at work: *"I edited the
Deployment and my change keeps disappearing."* If an operator (or Helm, or Argo CD) owns an
object, change the **source**, here the Website, not the generated object. Find out who owns something:

```bash
kubectl get deploy site-hello -o jsonpath='{.metadata.ownerReferences}'
```

**It cleans up.** The operator has no delete logic at all. Each generated object carries an
`ownerReference` to its Website, and Kubernetes' garbage collector removes children when the
owner goes:

```bash
kubectl delete website hello
kubectl get deploy,svc,configmap -l app=website
```

## 3. House rules: admission policies

Every request to the API server passes through **admission** after authentication and RBAC:

```
kubectl apply ──► authentication ──► RBAC ──► admission ──► saved in etcd
                  (who are you?)    (may you?)  (is THIS object acceptable here?)
```

RBAC can say "may create Deployments". Only admission can say "...but not without resource
limits / not from an unknown registry / not without an owner label". You met one built-in
admission check in lesson 12 (Pod Security Standards). Companies add their own.

Read [`policy.yaml`](policy.yaml): in namespaces labelled `policy=strict`, a Deployment must have a `team` label.

```bash
kubectl apply -f lessons/20-extending/policy.yaml
kubectl apply -f lessons/20-extending/deploy-unlabelled.yaml
```

```
The deployments "web" is invalid: : ValidatingAdmissionPolicy 'require-team-label' with binding
'require-team-label' denied request: Deployments in this namespace must have a 'team' label, so we know who to call.
```

(A new policy takes a few seconds to become active. If the Deployment was created, delete it and try again.)

The version with the label is accepted:

```bash
kubectl apply -f lessons/20-extending/deploy-labelled.yaml
```

When your deploy pipeline fails at work with `admission webhook "..." denied the request` or
`ValidatingAdmissionPolicy ... denied request`, it is one of these. The message tells you which
rule, and the fix is nearly always in your manifest, not in the cluster. Find the rules that apply:

```bash
kubectl get validatingadmissionpolicies,validatingadmissionpolicybindings
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
```

The second line lists **admission webhooks**: the older mechanism, where the API server calls an
external service (Kyverno, OPA Gatekeeper, or a tool's own webhook) to validate or *mutate*
objects. Mutating webhooks are why a Pod you created sometimes has containers or labels you never
wrote (a service-mesh sidecar, for example).

## What to remember at work

- **`kubectl explain <kind>` and `kubectl get crd` work for custom resources.** Use them before
  searching the web: they describe the version installed on *your* cluster.
- **Status and events are your interface to an operator.** `kubectl describe <kind> <name>`, then
  the operator's own logs (`kubectl logs -n <operator namespace> deploy/<operator>`).
- **A custom resource stuck in `Terminating`** is waiting for its operator to finish cleanup
  (a *finalizer*). If the operator is gone or broken, it waits forever. Fix the operator rather than deleting the finalizer by hand.
- **CRDs are cluster-wide and shared.** Two teams can't install different versions of the same
  CRD, and deleting a CRD deletes **every object of that kind in every namespace**. That's why installing operators is usually a platform-team job.
- **An operator has the permissions in its ClusterRole, permanently.** Read that list before
  installing one from the internet.
- **Don't write an operator for your web service.** A Helm chart or Kustomize overlay is enough
  for stateless apps. Operators earn their complexity for things with operational knowledge to
  automate: databases, message queues, certificates.

## Clean up

```bash
kubectl delete namespace strict-team
kubectl delete -f lessons/20-extending/policy.yaml --ignore-not-found
kubectl delete -f lessons/20-extending/operator.yaml
kubectl delete -f lessons/20-extending/crd.yaml
```

## Exercises

1. Apply a Website with `replicas: 3` and no `owner`. Which line of `crd.yaml` rejects it? Fix the Website.
2. Stop the operator (`kubectl -n website-operator scale deploy/website-operator --replicas=0`), then create a second Website and delete the Deployment of the first. What still works, what doesn't? Start it again.
3. Change the policy binding's `validationActions` to `["Warn"]` and apply the unlabelled Deployment again. Why would a platform team start with `Warn`?
4. List the CRDs on your cluster (`kubectl get crd`). Which tool installed each group, and what in the cluster acts on them?
5. Create a Website, then delete the CRD. What happens to the Website and to its Deployment?

<details>
<summary>Answers</summary>

1. The `x-kubernetes-validations` rule: *sites with more than 2 replicas must name an owner*.
   Add `owner: your-team` to the spec. Rules across several fields can't be expressed with plain
   `minimum`/`maximum`, which is what CEL is for.
2. Existing sites keep serving: the operator isn't in the request path. But nothing reconciles:
   the new Website gets no Deployment, and the deleted Deployment stays deleted. Operators failing
   is usually silent like this, which is why they're monitored. Scale back to 1 and both are fixed within seconds.
3. The Deployment is created, and kubectl prints a warning with the policy's message. Teams
   introduce a rule as `Warn` (or `Audit`), see who would be affected, give them time to fix
   their manifests, and only then switch to `Deny`, instead of breaking every pipeline on day one.
4. `gateway.networking.k8s.io`: the Gateway API CRDs from `platform/gateway-api-crds.yaml`, acted
   on by Traefik. `traefik.io` (if present): Traefik's own. `lessons.example.com`: yours, acted on by the website-operator.
5. Both are deleted. Removing a CRD removes all its objects, and garbage collection then removes
   what they owned. On a real cluster, deleting the wrong CRD is one of the fastest ways to cause an outage.
</details>

---

**Next:** [Capstone: Pulse](../../capstone/README.md)
