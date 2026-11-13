# Installs (or resets) Pulse v1 into the 'pulse' namespace and runs its self-test.
$Root = Split-Path -Parent $PSScriptRoot
Push-Location $Root
try {
    Write-Host "==> Namespace (enforces the 'restricted' Pod Security Standard)" -ForegroundColor Cyan
    kubectl apply -f k8s/namespace.yaml
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed" }

    Write-Host "==> helm upgrade --install pulse" -ForegroundColor Cyan
    helm upgrade --install pulse chart/pulse -n pulse --wait --timeout 5m
    if ($LASTEXITCODE -ne 0) { throw "helm upgrade failed" }

    Write-Host "==> helm test" -ForegroundColor Cyan
    helm test pulse -n pulse --logs
    if ($LASTEXITCODE -ne 0) { throw "helm test failed" }

    Write-Host ""
    Write-Host "Pulse is running. Open http://pulse.localhost:8080"
    Write-Host "(or: curl.exe -H 'Host: pulse.localhost' http://127.0.0.1:8080)"
} finally {
    Pop-Location
}
