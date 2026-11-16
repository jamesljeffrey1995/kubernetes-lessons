# Lesson 19: Observability with Prometheus

**Time:** 50 minutes · **Goal:** answer "is it working, how much is it using, and since when?"
with metrics instead of guesses, and write an alert that fires on what users experience.

## Why this matters at work

`kubectl get pods` shows *now*. It can't tell you that latency doubled at 14:05, that memory has
been creeping up for three days, or that 3% of requests fail. For that, every company running
Kubernetes has a metrics system, and in the vast majority of cases it is **Prometheus** or
something that speaks its language (Grafana Mimir, Thanos, VictoriaMetrics, the managed services
of AWS, Azure and Google). The dashboards you'll be shown in your first week are built on it, and
the pages that wake people up are Prometheus alert rules.

The three kinds of signals, so you know the vocabulary:

| Signal | Answers | Typical tools |
|---|---|---|
| **Metrics** | *How much, how fast, how often?* Numbers over time. Cheap, great for alerts and dashboards | Prometheus, Grafana |
| **Logs** | *What exactly happened in this request?* | Loki, Elasticsearch/OpenSearch, cloud logging |
| **Traces** | *Where did the time go across services?* | OpenTelemetry, Tempo, Jaeger |

This lesson covers metrics, because they're what you'll query and alert on most.

## How Prometheus works

```
   your Pods ── /metrics (plain text) ◄─── scrape every 10s ─── Prometheus ──► queries (PromQL)
   kubelets  ── /metrics/cadvisor     ◄─── scrape ──────────────┘    │
                                                                      └──► alert rules ──► Alertmanager ──► Slack / pager
```

- **Pull, not push.** Apps expose a `/metrics` page; Prometheus fetches it on a schedule.
- **Service discovery.** Prometheus asks the Kubernetes API which Pods exist, so new Pods are
  picked up without anyone editing a config file.
- **Everything is a time series with labels**: `http_requests_total{namespace="shop", status="500"}`.
  Labels are how you slice: per app, per Pod, per status code.

## 1. Install it and an app to watch

Read [`prometheus.yaml`](prometheus.yaml) (the two `scrape_configs` are the heart of it) and
[`app.yaml`](app.yaml) (note the two `prometheus.io/...` annotations).

```bash
kubectl apply -f lessons/19-observability/prometheus.yaml
kubectl apply -f lessons/19-observability/app.yaml -f lessons/19-observability/traffic.yaml
kubectl -n monitoring rollout status deploy/prometheus
kubectl rollout status deploy/shop
```

First, see what a metrics page looks like: it's just text.

```bash
kubectl exec toolbox -- curl -s http://shop/metrics
```

```
# HELP http_request_duration_seconds Seconds spent serving HTTP requests.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_count{method="GET",path="root",status="200"} 1482
```

Now open the Prometheus UI: **<http://prometheus.localhost:8080>**
(if your browser doesn't resolve `*.localhost`, use `kubectl -n monitoring port-forward svc/prometheus 9090` and <http://localhost:9090>).

Go to **Status → Target health**. You should see two `pods` targets (the two `shop` Pods) and three
`containers` targets (one kubelet per node), all `UP`. This page is the first place to look when
"my metrics are missing".

## 2. PromQL in four queries

Type these into the query box on the **Query** page. Switch to the **Graph** tab to see them over time.

**1. Is it up?** `up` is 1 for every target Prometheus could scrape, 0 otherwise.

```promql
up
```

**2. Requests per second, per status code.** Counters only ever go up, so you never graph them
directly. `rate()` turns "total so far" into "per second over the last minute":

```promql
sum by (status) (rate(http_request_duration_seconds_count{app="shop"}[1m]))
```

About 10 per second with status 200: that's the `traffic` Deployment.

**3. Latency.** "99% of requests were faster than this many seconds":

```promql
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{app="shop"}[1m])))
```

Averages hide slow requests. Percentiles (p95, p99) are what service-level objectives are written in.

**4. Resource use, for any Pod, without the app's cooperation.** These come from the kubelet:

```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="default", container!=""}[1m]))
```
```promql
container_memory_working_set_bytes{namespace="default", container="podinfo"} / 1024 / 1024
```

The first is CPU cores in use per Pod, the number to compare with the CPU *request* you set in
lesson 09. The second is memory in MiB, the number the OOM killer compares with your *limit*.
Right-sizing requests and limits is done by looking at exactly these two graphs over a week.

The pattern in every query: **pick a metric, filter with `{labels}`, `rate()` it if it's a
counter, then `sum by (...)` the dimension you care about.**

## 3. An incident, and an alert that catches it

The config contains an alert rule, `HighErrorRate`: *more than 5% of an app's requests failing
for 30 seconds*. Look at it under **Alerts** in the UI: it's green (`inactive`).

Start the incident. [`errors.yaml`](errors.yaml) hammers an endpoint that returns HTTP 500:

```bash
kubectl apply -f lessons/19-observability/errors.yaml
```

Re-run query 2 on the Graph tab: a second line appears for `status="500"`. On the **Alerts**
page, within about a minute, `HighErrorRate` turns yellow (**pending**: the condition is true, but
not yet for 30 seconds) and then red (**firing**).

The `for:` delay is deliberate. Without it, every brief blip pages someone, people start ignoring
pages, and then the real one gets ignored too.

In a full setup, firing alerts go to **Alertmanager**, which groups them, silences them during
maintenance, and routes them to Slack, email or an on-call pager. Here the UI is the end of the line.

End the incident and watch the alert resolve:

```bash
kubectl delete -f lessons/19-observability/errors.yaml
```

Notice that `kubectl get pods` showed nothing wrong the whole time. Every Pod was `Running` and
`Ready`. That is the case for metrics: **healthy Pods are not the same as a healthy service.**

## What to monitor: two checklists that are used everywhere

**For a service (what users feel): RED**

| | Meaning | Query shape |
|---|---|---|
| **R**ate | Requests per second | `sum(rate(..._count[1m]))` |
| **E**rrors | Share of requests failing | `rate(errors) / rate(all)` |
| **D**uration | How long requests take (p95/p99) | `histogram_quantile(...)` |

**For a resource (CPU, memory, disk): USE**: **U**tilisation, **S**aturation (queuing, throttling), **E**rrors.

Alert on symptoms from the RED list (users are affected *now*). Put causes (CPU high, a Pod
restarted) on dashboards, where they help explain an alert without waking anyone.

## What's different at work

| Here | At work |
|---|---|
| One Prometheus Pod, data lost on restart | Highly available, long-term storage, often run by a platform team or the cloud |
| Annotations on Pods | Often a **ServiceMonitor** / **PodMonitor** object (Prometheus Operator): same idea as a custom resource (lesson 20) |
| The built-in UI | **Grafana** dashboards on top. You'll mostly read dashboards and only sometimes write PromQL |
| Alerts end in the UI | Alertmanager → on-call rotation, with runbooks linked from each alert |
| Container metrics only | Plus **kube-state-metrics**: the state of objects as metrics (`kube_pod_container_status_restarts_total`, `kube_deployment_status_replicas_unavailable`) |

Things worth knowing before your first on-call shift:

- **Labels with many values are expensive.** Never put user IDs, request IDs or full URLs in a
  label: each distinct value is a separate time series. This "cardinality explosion" is the classic way to take down a Prometheus.
- **`rate()` needs a window at least 4x the scrape interval** (`[1m]` for a 15s interval), or graphs get gaps.
- **A missing metric is not zero.** If an app is down, its error-rate query returns *nothing*, and
  an alert on `> 0.05` stays silent. That's why you also alert on `up == 0` or on "no data".

## Clean up

```bash
kubectl delete -f lessons/19-observability/app.yaml -f lessons/19-observability/traffic.yaml
kubectl delete -f lessons/19-observability/errors.yaml --ignore-not-found
kubectl delete -f lessons/19-observability/prometheus.yaml
```

## Exercises

1. Write a query for the **error ratio** of `shop` as a percentage. Run it with and without `errors.yaml` applied.
2. Scale `shop` to 4 replicas. How long until Prometheus scrapes the new Pods, and where do you see it? Did you change any Prometheus config?
3. Deploy `lessons/09-health-resources/oom.yaml` and graph its memory against its limit. What does the graph look like just before it's killed?
4. Remove the `prometheus.io/scrape` annotation from `app.yaml` and apply. What happens to the targets, to query 2, and to the `HighErrorRate` alert if errors start now?
5. Why does the `HighErrorRate` rule divide two `rate()`s instead of alerting on "more than 1 error per second"?

<details>
<summary>Answers</summary>

1. `100 * sum(rate(http_request_duration_seconds_count{app="shop",status=~"5.."}[1m])) / sum(rate(http_request_duration_seconds_count{app="shop"}[1m]))`.
   About 33% during the incident (5 failing of 15 requests per second). Without errors it returns
   **no data**, not 0, because no series has `status=~"5.."`. Append `or vector(0)` to get a 0.
2. Within one scrape interval (10s) of the Pods being ready, on **Status → Target health** and in
   `count(up{app="shop"})`. No config change: service discovery found them through the annotation.
3. `container_memory_working_set_bytes{pod="memory-hog"}` climbs in a straight line to the limit
   (`container_spec_memory_limit_bytes`), then the series stops and restarts from near zero: a
   saw-tooth. That shape on a dashboard means an OOM loop.
4. The two `pods` targets disappear and query 2 goes empty after a few minutes. The alert **never
   fires**, however many errors there are. The service is broken *and* unmonitored. This is the "missing metric
   is not zero" trap, and why `up`/absence alerts matter.
5. A ratio works at any traffic level. "1 error per second" is a catastrophe for a service with 2
   requests per second and unnoticeable noise for one with 20,000.
</details>

---

**Next:** [Lesson 20: Extending Kubernetes: CRDs, operators and policies](../20-extending/README.md)
