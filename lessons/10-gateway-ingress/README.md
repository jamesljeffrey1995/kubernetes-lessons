# Lesson 10: Getting traffic in (Gateway API and Ingress)

**Time:** 50 minutes · **Goal:** expose HTTP apps to the outside world with host, path and
header routing, and run a canary release by shifting traffic weights.

## The problem

Services are internal (ClusterIP), and a `LoadBalancer` Service per app means one cloud load
balancer (and one bill, one IP) per app. You want **one entry point** that routes
`shop.example.com` to the shop, `api.example.com/v2` to the new API, and handles TLS, for every app.

## Gateway API vs Ingress (and why this matters at work right now)

Kubernetes has two APIs for this:

| | **Ingress** (2015) | **Gateway API** (GA in 2023) |
|---|---|---|
| Status | Stable, but frozen: no new features | The actively developed successor |
| Routing | Host + path | Host, path, **headers, query params, methods, weights** |
| Advanced features | Through vendor-specific annotations (not portable) | Built into the spec (portable across controllers) |
| Roles | One object does everything | Split: platform team owns the **Gateway**, app teams own **Routes** |

**ingress-nginx, the most widely used Ingress controller, was retired by the Kubernetes project
in March 2026.** It gets no more releases or security fixes, so lots of companies are
migrating off it right now. The official recommendation is to move to Gateway API. Knowing
Gateway API, and being able to talk about that migration, is directly useful at work.

Both need a **controller** (software that reads the objects and actually routes traffic). Our
cluster runs **Traefik** (installed by `cluster-up`), which implements both APIs. Others include
Envoy Gateway, Istio, Cilium, NGINX Gateway Fabric, and cloud-native ones (AWS Load Balancer
Controller, GKE Gateway, Azure Application Gateway for Containers).

## How traffic reaches your app here

```
Browser: http://blue.localhost:8080
   │   (*.localhost always means "this machine". Browsers and curl resolve it to 127.0.0.1, no DNS setup needed)
   ▼
localhost:8080 ──kind port mapping──► control-plane node :80 ──► Traefik Pod
                                                                    │ reads Gateway + HTTPRoutes
                                                                    │ "Host blue.localhost → Service blue"
                                                                    ▼
                                                    Service blue ──► blue Pods
```

The three Gateway API objects:

```
GatewayClass "traefik"   which controller implements Gateways      (cluster admin, once)
     │
Gateway "main"           a listener: port, protocol, TLS cert,     (platform team)
     │                   and which namespaces may attach routes
     │
HTTPRoute "blue"         hostnames + rules → Services              (app teams, many)
```

See the first two in [`platform/traefik.yaml`](../../platform/traefik.yaml) (at the bottom), and check them:

```bash
kubectl get gatewayclass
kubectl get gateway -n traefik
```

Both should show `ACCEPTED True` / `PROGRAMMED True`.

## 1. Deploy two versions of an app

Read [`apps.yaml`](apps.yaml): `blue` (v1) and `green` (v2), each with a Service.

```bash
kubectl apply -f lessons/10-gateway-ingress/apps.yaml
kubectl rollout status deploy/blue
kubectl rollout status deploy/green
```

## 2. Route by hostname

[`route-host.yaml`](route-host.yaml):

```bash
kubectl apply -f lessons/10-gateway-ingress/route-host.yaml
kubectl get httproute
```

Open <http://blue.localhost:8080> and <http://green.localhost:8080> in your browser. Or with curl:

```bash
curl http://blue.localhost:8080          # Linux/macOS
curl.exe http://blue.localhost:8080      # Windows (use curl.exe: in Windows PowerShell 'curl' is an alias for something else)
```

> **If `*.localhost` doesn't resolve for you** (some older tools and corporate setups),
> send the hostname as a header instead. This always works:
> `curl -H "Host: blue.localhost" http://127.0.0.1:8080`

Routes take a second or two to become active after `apply`. A `404 page not found` right after applying usually just means "try again".

## 3. Route by path and header

[`route-path-header.yaml`](route-path-header.yaml): one hostname, several rules:

```bash
kubectl apply -f lessons/10-gateway-ingress/route-path-header.yaml
curl http://shop.localhost:8080/blue
curl http://shop.localhost:8080/green
curl http://shop.localhost:8080/anything-else
curl -H "x-version: green" http://shop.localhost:8080/
```

(Windows: `curl.exe` as before.)

Header routing is a common trick: testers (or a browser extension) send `x-version: green` to
try the new version in production while everyone else still gets the old one.

## 4. Canary release with weights

[`route-canary.yaml`](route-canary.yaml) sends 90% to blue and 10% to green:

```bash
kubectl apply -f lessons/10-gateway-ingress/route-canary.yaml
```

Send 100 requests and count the answers.

**bash:**
```bash
for i in $(seq 1 100); do curl -s http://canary.localhost:8080; done | sort | uniq -c
```

**PowerShell:**
```powershell
1..100 | ForEach-Object { curl.exe -s http://canary.localhost:8080 } | Group-Object | ForEach-Object { "{0,7} {1}" -f $_.Count, $_.Name }
```

```
     90 BLUE  (v1)
     10 GREEN (v2)
```

Now edit the weights to `50`/`50`, re-apply, and count again. Then `0`/`100`. **That's a canary
release**: shift traffic gradually, watch your error rates and dashboards, and set the weight
back to `100`/`0` the moment something looks wrong. Tools like Argo Rollouts and Flagger
automate exactly this loop, adjusting the weights based on metrics.

## 5. The older way: Ingress

[`ingress.yaml`](ingress.yaml) does what `route-host.yaml` does, using the Ingress API:

```bash
kubectl apply -f lessons/10-gateway-ingress/ingress.yaml
kubectl get ingress
curl http://legacy.localhost:8080
```

Compare the two files. You'll read a lot of Ingress YAML at work. Write new things with Gateway API.

## 6. When a route doesn't work

Check the route's **status**. The controller writes back whether it accepted the route:

```bash
kubectl describe httproute blue
```

Look under `Status → Parents → Conditions`:

- `Accepted: True`: the Gateway took the route. If `False`, the `parentRefs` are wrong, or the Gateway doesn't allow routes from your namespace.
- `ResolvedRefs: True`: the backend Services exist. If `False` with `BackendNotFound`, you mistyped a Service name or port.

Then work down the chain: route → Service endpoints (lesson 05) → Pod readiness (lesson 09). And
the controller's own logs: `kubectl logs -n traefik deploy/traefik`. Every request is
logged there, with the route it matched and which Pod IP it went to.

## TLS / HTTPS (how it works at work)

On real clusters you add an HTTPS listener to the Gateway referencing a TLS Secret, and
**cert-manager** obtains and renews certificates automatically (from Let's Encrypt or your
company's CA). App teams don't touch certificates at all. It's not set up in this course
because `*.localhost` can't get a public certificate, but this is the shape:

```yaml
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"
      tls:
        certificateRefs:
          - name: wildcard-example-com   # a Secret that cert-manager keeps up to date
```

## Clean up

```bash
kubectl delete -f lessons/10-gateway-ingress/
```

## Exercises

1. Add a route so that <http://whoami.localhost:8080> reaches a `traefik/whoami` Deployment
   (write the Deployment, Service and HTTPRoute yourself). Refresh several times. Does the hostname change?
2. Break the route on purpose: point it at Service `whoamii`. What does the browser show? What
   does `kubectl describe httproute` say?
3. In `route-path-header.yaml`, what would happen if the catch-all rule (no `matches`) were
   listed *first*? Try it. (Gateway API has precise precedence rules. Is rule order what decides?)

<details>
<summary>Answers</summary>

1. Something like:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: whoami }
   spec:
     replicas: 3
     selector: { matchLabels: { app: whoami } }
     template:
       metadata: { labels: { app: whoami } }
       spec:
         containers:
           - name: whoami
             image: traefik/whoami:v1.11.0
             ports: [{ containerPort: 80 }]
   ---
   apiVersion: v1
   kind: Service
   metadata: { name: whoami }
   spec:
     selector: { app: whoami }
     ports: [{ port: 80 }]
   ---
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata: { name: whoami }
   spec:
     parentRefs: [{ name: main, namespace: traefik }]
     hostnames: ["whoami.localhost"]
     rules:
       - backendRefs: [{ name: whoami, port: 80 }]
   ```
   The `Hostname:` line changes between refreshes, so requests are spread across Pods. (Browsers
   reuse connections, but Traefik balances per *request*, not per connection.)
2. The browser gets an error page (Traefik returns `500` for a route whose backend doesn't exist).
   `describe` shows `ResolvedRefs False`, reason `BackendNotFound`.
3. Nothing changes. Gateway API doesn't use "first match wins" by rule order. It picks the
   **most specific** match: exact path beats prefix, longer prefix beats shorter, more header
   matches beat fewer. A rule with no matches is the least specific, so it only catches what
   nothing else does. That's a nice improvement over many older routers.
</details>

---

**Next:** [Lesson 11: Helm](../11-helm/README.md)
