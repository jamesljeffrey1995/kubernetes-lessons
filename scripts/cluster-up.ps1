# Creates the "lessons" kind cluster and installs the platform pieces:
#   - Gateway API CRDs (platform/gateway-api-crds.yaml)
#   - Traefik gateway/ingress controller (platform/traefik.yaml)
#   - metrics-server, for `kubectl top` and autoscaling (platform/metrics-server.yaml)
#
# Safe to re-run: if the cluster already exists it restarts stopped nodes if needed and
# (re)applies the platform. If a step times out on a slow machine, just run it again.
#
# Usage (PowerShell 7+ recommended, Windows PowerShell 5.1 also works):
#   .\scripts\cluster-up.ps1
# If scripts are blocked by execution policy:
#   powershell -ExecutionPolicy Bypass -File .\scripts\cluster-up.ps1
# Options:
#   $env:KIND_CONFIG = "path\to\other-kind-config.yaml"; .\scripts\cluster-up.ps1
#   $env:SKIP_HOST_CHECKS = "1"   (skip the pre-flight checks - not recommended)

# Note: no $ErrorActionPreference = "Stop" on purpose. In Windows PowerShell 5.1 it turns
# harmless stderr output from kubectl/kind into script-killing errors. Invoke-Native checks
# exit codes instead.

$ClusterName = "lessons"
$Root = Split-Path -Parent $PSScriptRoot
$KindConfig = if ($env:KIND_CONFIG) { $env:KIND_CONFIG } else { Join-Path $Root "platform/kind-config.yaml" }

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "WARNING: $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# Runs a native command and stops the script if it fails.
# ($ErrorActionPreference does not apply to .exe exit codes in PowerShell 5.1.)
function Invoke-Native {
    $exe, $rest = $args
    & $exe @rest
    if ($LASTEXITCODE -ne 0) { Die "'$exe $($rest -join ' ')' failed with exit code $LASTEXITCODE" }
}

# Sets $Ctr (docker or podman), $IsPodman, and KIND_EXPERIMENTAL_PROVIDER when Podman is in use.
. (Join-Path $PSScriptRoot "engine.ps1")

Step "Checking this machine (tools, container engine, cgroups)"
if ($env:SKIP_HOST_CHECKS -eq "1") {
    Warn "SKIP_HOST_CHECKS=1 - skipping host checks"
} else {
    & (Join-Path $PSScriptRoot "check-prereqs.ps1") -ForCluster
    if ($LASTEXITCODE -ne 0) { Die "This machine isn't ready yet - see the failed items above." }
}

function Test-PortInUse($port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.Connect("127.0.0.1", [int]$port); return $true } catch { return $false } finally { $client.Close() }
}

Step "Creating kind cluster '$ClusterName' (first time takes 1-3 minutes)"
$existing = @(kind get clusters 2>$null)
if ($existing -contains $ClusterName) {
    Write-Host "Cluster '$ClusterName' already exists - reusing it."
    # After a reboot, nodes may be stopped: Docker restarts them itself, Podman never does.
    $stopped = @()
    foreach ($node in "$ClusterName-control-plane", "$ClusterName-worker", "$ClusterName-worker2") {
        $state = (& $Ctr inspect -f '{{.State.Running}}' $node 2>$null | Out-String).Trim()
        if ($state -eq "false") { $stopped += $node }
    }
    if ($stopped.Count -gt 0) {
        Write-Host "Nodes are stopped (after a reboot?) - starting: $($stopped -join ' ')"
        & $Ctr start @stopped | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "Could not start the nodes. Recreate the cluster: .\scripts\cluster-down.ps1; .\scripts\cluster-up.ps1" }
    }
    # Rewrites the kubeconfig entry too, in case it was lost or the API port changed.
    kind export kubeconfig --name $ClusterName *> $null
    if ($LASTEXITCODE -ne 0) { Invoke-Native kubectl config use-context "kind-$ClusterName" | Out-Null }
    Write-Host "Waiting for the API server..."
    $ready = $false
    foreach ($i in 1..60) {
        kubectl get --raw /readyz *> $null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { Die "The existing cluster doesn't answer. Recreate it: .\scripts\cluster-down.ps1; .\scripts\cluster-up.ps1" }
} else {
    $hostPort = $null
    $m = Select-String -Path $KindConfig -Pattern 'hostPort:\s*(\d+)' | Select-Object -First 1
    if ($m) { $hostPort = $m.Matches[0].Groups[1].Value }
    if ($hostPort -and (Test-PortInUse $hostPort)) {
        Warn "See what holds it:  netstat -ano | findstr :$hostPort   (Linux: ss -ltnp | grep ':$hostPort ')"
        Warn "An earlier cluster made with another engine? Check: docker ps / podman ps"
        Warn "Something else? Change hostPort in platform/kind-config.yaml and use that port in the lessons."
        Die "Port $hostPort on this machine is already in use, and the cluster's front door needs it."
    }

    # Rootless Podman (Linux): kind's docs say some distros need kind started in its own systemd
    # scope with cgroup delegation. https://kind.sigs.k8s.io/docs/user/rootless/
    $useScope = $false
    if ($IsPodman -and (Get-Command systemd-run -ErrorAction SilentlyContinue) -and
        ((& $Ctr info --format '{{.Host.Security.Rootless}}' 2>$null | Out-String).Trim() -eq "true")) {
        systemd-run --scope --user -p "Delegate=yes" true *> $null
        $useScope = ($LASTEXITCODE -eq 0)
    }
    if ($useScope) {
        Write-Host "Rootless Podman detected: starting kind in its own systemd scope (Delegate=yes)."
        $output = & systemd-run --scope --user -p "Delegate=yes" kind create cluster --config $KindConfig 2>&1
    } else {
        $output = & kind create cluster --config $KindConfig 2>&1
    }
    $code = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) {
        $text = ($output | Out-String)
        if ($text -match "could not find a log line") {
            Warn "The node container started but kind never saw it finish booting."
            Warn "Rootless Podman on Linux: see 'could not find a log line' in lessons/00-setup/rootless.md."
            Warn "Docker Desktop / Podman machine: give the VM more memory, then retry."
        } elseif ($text -match "Delegate=yes") {
            Warn "cgroup delegation isn't active for your user. On Linux run ./scripts/check-prereqs.sh;"
            Warn "Podman machine: podman machine stop; podman machine set --rootful; podman machine start"
        } elseif ($text -match "requires cgroup v2") {
            Warn "kind sees cgroup v1. Docker Desktop: 'wsl --update', then restart Docker Desktop."
        } elseif ($text -match "address already in use|port is already allocated") {
            Warn "A port the cluster needs is taken: netstat -ano | findstr `":8080 :6443`""
        } elseif ($text -match "toomanyrequests") {
            Warn "Docker Hub's anonymous pull limit is used up for your IP. Wait, or '$Ctr login docker.io'."
        } elseif ($text -match "x509|certificate signed by unknown authority") {
            Warn "A TLS-inspecting company proxy is in the way. See 'Corporate proxy' in lessons/00-setup/README.md."
        } else {
            Warn "Not a failure this script recognises. See 'Things that go wrong' in lessons/00-setup/README.md."
        }
        kind delete cluster --name $ClusterName *> $null
        Die "kind could not create the cluster (full output above)."
    }
}
Invoke-Native kubectl wait --for=condition=Ready nodes --all --timeout=300s

Step "Installing Gateway API CRDs"
Invoke-Native kubectl apply --server-side --force-conflicts -f (Join-Path $Root "platform/gateway-api-crds.yaml") | Out-Null
Invoke-Native kubectl wait --for=condition=Established crd --all --timeout=60s | Out-Null

Step "Installing Traefik (the cluster's front door on http://localhost:8080)"
Invoke-Native kubectl apply -f (Join-Path $Root "platform/traefik.yaml")
Invoke-Native kubectl -n traefik rollout status deploy/traefik --timeout=300s

Step "Installing metrics-server (for 'kubectl top' and autoscaling)"
Invoke-Native kubectl apply -f (Join-Path $Root "platform/metrics-server.yaml") | Out-Null
kubectl -n kube-system rollout status deploy/metrics-server --timeout=120s
if ($LASTEXITCODE -ne 0) {
    Warn "metrics-server is not ready yet. Only lessons 09 and 13 need it; check later with:"
    Warn "  kubectl -n kube-system get pods -l k8s-app=metrics-server"
}

Step "Done"
kubectl get nodes
Write-Host ""
Write-Host "Cluster is ready. kubectl context: kind-$ClusterName"
Write-Host "Delete it any time with: .\scripts\cluster-down.ps1"
