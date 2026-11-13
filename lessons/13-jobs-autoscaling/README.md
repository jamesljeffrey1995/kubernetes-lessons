# Lesson 13: Jobs, CronJobs and autoscaling

**Time:** 45 minutes · **Goal:** run work that *finishes* (once or on a schedule), and let
Kubernetes scale an app with load.

## Part 1: Jobs

Deployments keep Pods running *forever*. A **Job** runs Pods until a number of them **succeed**,
then stops. Use it for database migrations, batch processing, data imports, one-off fixes.

### 1. A parallel Job

Read [`job.yaml`](job.yaml): 6 work items, 2 at a time, each Pod told its item number via `JOB_COMPLETION_INDEX`.

```bash
kubectl apply -f lessons/13-jobs-autoscaling/job.yaml
kubectl get pods -l job-name=process-items -w
```

Pods run two at a time and end `Completed`. Then:

```bash
kubectl get jobs
kubectl logs -l job-name=process-items --prefix
```

```
NAME            STATUS     COMPLETIONS   DURATION
process-items   Complete   6/6           18s
```

### 2. When a Job fails

[`failing-job.yaml`](failing-job.yaml) always exits with code 1:

```bash
kubectl apply -f lessons/13-jobs-autoscaling/failing-job.yaml
kubectl get pods -l job-name=always-fails -w
```

Kubernetes retries with growing delays (10s, 20s, 40s... the back-off), and after `backoffLimit: 2` retries:

```bash
kubectl describe job always-fails
```

```
Pods Statuses:  0 Active / 0 Succeeded / 3 Failed
Warning  BackoffLimitExceeded  Job has reached the specified backoff limit
```

The failed Pods are kept so you can read their logs: `kubectl logs -l job-name=always-fails`.

> **Make Jobs safe to retry (idempotent).** A Job may run your code more than once (retries,
> node failures). A migration that crashes halfway and re-runs must not corrupt data.

## Part 2: CronJobs

A **CronJob** creates a Job on a schedule. Read [`cronjob.yaml`](cronjob.yaml).

```bash
kubectl apply -f lessons/13-jobs-autoscaling/cronjob.yaml
kubectl get cronjob report
```

Wait a minute or two, then:

```bash
kubectl get jobs
kubectl logs job/<one of the report-... job names>
```

Run it **now** without waiting for the schedule. This is great for testing, or re-running a failed night:

```bash
kubectl create job --from=cronjob/report report-manual
kubectl logs job/report-manual
```

Pause it without deleting: `kubectl patch cronjob report -p '{"spec":{"suspend":true}}'`
(in Windows PowerShell 5.1 use `-p '{\"spec\":{\"suspend\":true}}'`; PowerShell 7 is fine as is).

Cron syntax refresher: `minute hour day-of-month month day-of-week`.
`*/15 * * * *` = every 15 minutes, `0 2 * * *` = 02:00 daily, `0 9 * * 1-5` = 09:00 on weekdays.
Without `timeZone`, schedules are in the controller's time zone (UTC on almost every cluster).

## Part 3: Horizontal Pod Autoscaler (HPA)

The **HPA** adds or removes Pods to keep a metric (usually CPU) near a target:

```
desired replicas = ceil( current replicas × current usage / target )
```

It reads usage from **metrics-server** (installed by `cluster-up`). Check it works:

```bash
kubectl top nodes
```

If that errors, see the note at the end of lesson 09.

### 3. Watch it scale

Read [`autoscale.yaml`](autoscale.yaml): a tiny web server where every request burns CPU, and
an HPA targeting **50% of the CPU request**.

```bash
kubectl apply -f lessons/13-jobs-autoscaling/autoscale.yaml
kubectl rollout status deploy/cpu-app
kubectl get hpa cpu-app
```

`TARGETS` shows `cpu: <unknown>/50%` for the first minute (no metrics yet), then something like `cpu: 0%/50%`.

Open a **second terminal** and watch:

```bash
kubectl get hpa cpu-app -w
```

Start the load ([`load.yaml`](load.yaml): 4 Pods requesting in a tight loop):

```bash
kubectl apply -f lessons/13-jobs-autoscaling/load.yaml
```

Within 1-2 minutes CPU shoots past the target and `REPLICAS` climbs (often straight to the
maximum of 8). See the HPA's reasoning:

```bash
kubectl describe hpa cpu-app
kubectl top pods -l app=cpu-app
```

```
Normal  SuccessfulRescale  New size: 4; reason: cpu resource utilization (percentage of request) above target
Normal  SuccessfulRescale  New size: 8; reason: cpu resource utilization (percentage of request) above target
```

Now stop the load:

```bash
kubectl delete -f lessons/13-jobs-autoscaling/load.yaml
```

After the `stabilizationWindowSeconds` (30s in our file, **5 minutes by default**) it scales back
down to 1. Scaling down slowly is deliberate: it avoids flapping when load is bursty.

### HPA at work: what to know

- **The HPA needs CPU *requests*.** Percentages are relative to the request. No request means no autoscaling.
- **Don't set `replicas:` in your Deployment YAML (or Helm values) when an HPA manages it.**
  Every `kubectl apply` would reset the count and fight the HPA.
- **CPU is often the wrong signal** for I/O-bound apps. You can scale on memory, or on custom
  metrics (requests/sec, queue length) with **KEDA**, which also scales to zero.
- **Pods can only scale if there's room.** On cloud clusters, the **Cluster Autoscaler** or
  **Karpenter** adds *nodes* when Pods are `Pending` for lack of space. HPA (more Pods) and node
  autoscaling (more nodes) work together.
- **VPA** (Vertical Pod Autoscaler) adjusts requests/limits instead of the replica count, and is useful for right-sizing.

## Clean up

```bash
kubectl delete -f lessons/13-jobs-autoscaling/
kubectl delete job report-manual
```

## Exercises

1. Change `job.yaml` to `parallelism: 6`. How long does the Job take now? Then try `parallelism: 10` and explain the result.
2. A nightly CronJob sometimes takes 26 hours. What does `concurrencyPolicy: Forbid` do then? What would `Allow` do, and why might that be dangerous?
3. With the load running, change the HPA's `maxReplicas` to 3. What happens to the extra Pods? What happens to response times?

<details>
<summary>Answers</summary>

1. About 3 seconds (all 6 at once, plus start-up). With `parallelism: 10` it's the same: there
   are only 6 completions to do, so Kubernetes never runs more than 6.
2. `Forbid` skips the next run while one is still going. `Allow` starts another alongside it, so
   two copies process the same data at once, which can mean double emails, duplicate rows or lock contention. (`Replace` kills the running one and starts fresh.)
3. The HPA scales down to 3 and keeps it there even though CPU is above target. `describe hpa`
   shows it is limited by `maxReplicas`. Each Pod hits its CPU limit and gets throttled, so
   responses slow down. That's exactly the situation you'd spot on a latency dashboard at work.
</details>

---

**Next:** [Lesson 14: Troubleshooting](../14-troubleshooting/README.md)
