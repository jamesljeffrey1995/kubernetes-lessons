# Guided live demo of Pulse. Open http://pulse.localhost:8080 in a browser next to this
# terminal before you start: every step is visible on the dashboard.
#
# Usage:  .\capstone\scripts\demo.ps1          (pauses before each step - for presenting)
#         .\capstone\scripts\demo.ps1 -Auto    (no pauses, checks each step - used by CI)
#         .\capstone\scripts\demo.ps1 -SkipAutoscale   (skip step 7, e.g. if metrics-server isn't working)
param(
    [switch]$Auto,
    [switch]$SkipAutoscale
)

$NS = "pulse"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
if ($env:SKIP_AUTOSCALE -eq "1") { $SkipAutoscale = $true }

function Title($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Magenta }
function Say($t)   { Write-Host $t -ForegroundColor Cyan }
function Fail($t)  { Write-Host "FAILED: $t" -ForegroundColor Red; exit 1 }
function Pause-Demo { if (-not $Auto) { Read-Host "Enter to continue..." | Out-Null } }

# Shows a command, runs it, and stops the demo if it fails.
function Run([string]$cmd) {
    Write-Host "> $cmd" -ForegroundColor Yellow
    Invoke-Expression $cmd
    if ($LASTEXITCODE -ne 0) { Fail "command failed: $cmd" }
}

# Retries a check (a scriptblock returning $true/$false) until it passes or times out.
function Wait-For([int]$TimeoutSeconds, [string]$Description, [scriptblock]$Check) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (& $Check)) {
        if ((Get-Date) -gt $deadline) { Fail "timed out waiting for: $Description" }
        Start-Sleep -Seconds 3
    }
    Say "OK: $Description"
}

function Get-ReadyReplicas {
    $n = kubectl get deploy pulse -n $NS -o jsonpath='{.status.readyReplicas}' 2>$null
    if ($n) { [int]$n } else { 0 }
}

function Test-AllPodsVersion([string]$Want) {
    $got = kubectl get pods -n $NS -l app.kubernetes.io/component=web -o jsonpath='{.items[*].metadata.labels.app\.kubernetes\.io/version}' 2>$null
    if (-not $got) { return $false }
    $unique = @($got -split ' ' | Where-Object { $_ } | Sort-Object -Unique)
    return ($unique.Count -eq 1 -and $unique[0] -eq $Want)
}

Title "0. Starting point: Pulse v1, 3 replicas"
kubectl apply -f k8s/namespace.yaml | Out-Null
Run "helm upgrade --install pulse chart/pulse -n $NS --wait --timeout 5m | Out-Null"
Run "kubectl get pods -n $NS -o wide"
Say "Dashboard: http://pulse.localhost:8080 - every tile is a Pod; the page polls ~3x per second."
Pause-Demo

Title "1. Scaling: 3 -> 6 Pods"
Say "One value change. New tiles appear on the dashboard within seconds."
Run "helm upgrade pulse chart/pulse -n $NS --set replicaCount=6 --wait | Out-Null"
Run "kubectl get pods -n $NS -l app.kubernetes.io/component=web -o wide"
Wait-For 60 "6 Pods ready" { (Get-ReadyReplicas) -ge 6 }
Pause-Demo

Title "2. Self-healing"
Say "2a. Kill ONE Pod (a crash, or a node failure taking out one replica)."
Say "    Watch the 'failed' counter on the dashboard: it stays at 0, because the other Pods carry the traffic."
$victim = kubectl get pods -n $NS -l app.kubernetes.io/component=web -o jsonpath='{.items[0].metadata.name}'
Run "kubectl delete pod $victim -n $NS --wait=false"
Wait-For 120 "Deployment replaced the Pod" { (Get-ReadyReplicas) -ge 6 }
Pause-Demo
Say "2b. Now the worst case: kill EVERY app Pod at the same time."
Say "    Expect a few seconds of failed requests (nothing is Ready until replacements start),"
Say "    then full recovery without anyone touching anything."
Run "kubectl delete pods -n $NS -l app.kubernetes.io/component=web --wait=false"
Run "kubectl get pods -n $NS -l app.kubernetes.io/component=web"
Wait-For 120 "Deployment replaced all 6 Pods" { (Get-ReadyReplicas) -ge 6 }
Say "The hit counter kept counting: state lives in Redis (a StatefulSet with its own disk), not in the Pods."
Say "Real outages look like 2a far more often than 2b, and spreading replicas across nodes and zones keeps it that way."
Pause-Demo

Title "3. Zero-downtime rolling update: v1 (blue) -> v2 (green)"
Say "Tiles turn green one by one. Pods are replaced gradually, so: 0 failed requests."
Run "helm upgrade pulse chart/pulse -n $NS -f values-v2.yaml --wait --timeout 5m | Out-Null"
Wait-For 120 "all Pods on v2" { Test-AllPodsVersion "v2" }
Run "helm history pulse -n $NS"
Pause-Demo

Title "4. Rollback: back to v1 in one command"
Run "helm rollback pulse -n $NS --wait | Out-Null"
Wait-For 120 "all Pods back on v1" { Test-AllPodsVersion "v1" }
Pause-Demo

Title "5. Node maintenance: drain a worker node"
$redisNode = kubectl get pod pulse-redis-0 -n $NS -o jsonpath='{.spec.nodeName}'
$workers = (kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}') -split ' '
$node = $workers | Where-Object { $_ -and $_ -ne $redisNode } | Select-Object -First 1
Say "Draining $node (the node without Redis: kind's local disks can't move between nodes)."
Say "Pods are evicted gracefully and rescheduled; the PodDisruptionBudget keeps at least 1 running."
Say "(--force also removes unmanaged Pods, like the lessons' 'toolbox' Pod, from that node.)"
Run "kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --timeout=180s"
Run "kubectl get pods -n $NS -o wide"
Wait-For 120 "app still fully available" { (Get-ReadyReplicas) -ge 3 }
Run "kubectl uncordon $node"
Pause-Demo

Title "6. Security: the namespace rejects unsafe Pods"
Say "The 'pulse' namespace enforces the 'restricted' Pod Security Standard. A plain nginx Pod (runs as root):"
$err = kubectl run root-test -n $NS --image=nginx:1.29-alpine 2>&1
if ($LASTEXITCODE -eq 0) {
    kubectl delete pod root-test -n $NS --wait=false | Out-Null
    Fail "an insecure Pod was admitted"
}
$msg = ($err | Out-String).Trim()
Write-Host $msg.Substring(0, [Math]::Min(220, $msg.Length)) -ForegroundColor Red
Say "Rejected. Every Pod in the chart passes these rules (non-root, read-only filesystem, no capabilities)."
Say ""
Say "NetworkPolicies: only the gateway and Pods in this namespace may reach the app; only the app may reach Redis."
Say "Trying to reach Redis directly from the 'default' namespace:"
kubectl delete pod netpol-test -n default --ignore-not-found | Out-Null
kubectl run netpol-test -n default --restart=Never --image=busybox:1.37 --command -- sh -c "nc -w 3 pulse-redis-0.pulse-redis.$NS.svc.cluster.local 6379 </dev/null && echo CONNECTED || echo BLOCKED" | Out-Null
Wait-For 60 "test Pod finished" {
    $phase = kubectl get pod netpol-test -n default -o jsonpath='{.status.phase}' 2>$null
    $phase -eq "Succeeded" -or $phase -eq "Failed"
}
$result = (kubectl logs netpol-test -n default 2>$null | Select-Object -Last 1)
kubectl delete pod netpol-test -n default --wait=false | Out-Null
if ($result -eq "BLOCKED") {
    Say "BLOCKED, as intended."
} elseif ($env:STRICT_NETPOL -eq "1") {
    Fail "NetworkPolicy not enforced (got '$result')"
} else {
    Write-Host "Got '$result'. Your network plugin may not enforce NetworkPolicies (see lesson 12)." -ForegroundColor Yellow
}
Pause-Demo

if ($SkipAutoscale) {
    Say "Skipping step 7 (autoscaling)."
} else {
    Title "7. Autoscaling: let the HPA decide the replica count"
    Run "helm upgrade pulse chart/pulse -n $NS -f values-autoscale.yaml --wait | Out-Null"
    Run "kubectl get hpa -n $NS"
    Say "Starting a load generator (3 Pods hammering /api/work, which burns CPU)..."
    Run "kubectl apply -f k8s/load.yaml"
    Say "Within 1-2 minutes CPU passes the 50% target and the HPA adds Pods (watch new tiles appear)."
    Wait-For 300 "HPA scaled above 2 replicas" {
        $d = kubectl get hpa pulse -n $NS -o jsonpath='{.status.desiredReplicas}' 2>$null
        $d -and [int]$d -gt 2
    }
    Run "kubectl get hpa -n $NS"
    Run "kubectl delete -f k8s/load.yaml"
    Say "Load stopped. The HPA scales back down after its 60s stabilization window."
    Pause-Demo
}

Title "Done"
Say "Reset to the starting point any time with: .\capstone\scripts\deploy.ps1"
helm upgrade pulse chart/pulse -n $NS --wait | Out-Null
Say "(Already reset: v1, 3 replicas, no autoscaling.)"
