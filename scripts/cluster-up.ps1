# Creates the "lessons" kind cluster and installs the platform pieces:
#   - Gateway API CRDs (platform/gateway-api-crds.yaml)
#   - Traefik gateway/ingress controller (platform/traefik.yaml)
#   - metrics-server, for `kubectl top` and autoscaling (platform/metrics-server.yaml)
#
# Safe to re-run: if the cluster already exists it just (re)applies the platform.
#
# Usage (PowerShell 7+ recommended, Windows PowerShell 5.1 also works):
#   .\scripts\cluster-up.ps1
# If scripts are blocked by execution policy:
#   powershell -ExecutionPolicy Bypass -File .\scripts\cluster-up.ps1
# Options:
#   $env:KIND_CONFIG = "path\to\other-kind-config.yaml"; .\scripts\cluster-up.ps1

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

Step "Checking tools"
foreach ($tool in "docker", "kind", "kubectl") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Die "'$tool' not found. See lessons/00-setup/README.md"
    }
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { Die "Docker is installed but not running. Start Docker Desktop and retry." }

Step "Creating kind cluster '$ClusterName' (first time takes 1-3 minutes)"
$existing = @(kind get clusters 2>$null)
if ($existing -contains $ClusterName) {
    Write-Host "Cluster '$ClusterName' already exists - reusing it."
    Invoke-Native kubectl config use-context "kind-$ClusterName" | Out-Null
} else {
    Invoke-Native kind create cluster --config $KindConfig
}
Invoke-Native kubectl wait --for=condition=Ready nodes --all --timeout=180s

Step "Installing Gateway API CRDs"
Invoke-Native kubectl apply --server-side --force-conflicts -f (Join-Path $Root "platform/gateway-api-crds.yaml") | Out-Null
Invoke-Native kubectl wait --for=condition=Established crd --all --timeout=60s | Out-Null

Step "Installing Traefik (the cluster's front door on http://localhost:8080)"
Invoke-Native kubectl apply -f (Join-Path $Root "platform/traefik.yaml")
Invoke-Native kubectl -n traefik rollout status deploy/traefik --timeout=180s

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
