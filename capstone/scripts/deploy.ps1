# Installs (or resets) Pulse v1 into the 'pulse' namespace and runs its self-test.
#
# Where the cluster pulls Pulse from is chosen with environment variables:
#   unset (default)     the local images that build.ps1 loaded into kind
#   $env:PULSE_IMAGE    a registry build.ps1 pushed to, e.g. "ghcr.io/you/pulse"
#   $env:PULSE_REGISTRY_USER + $env:PULSE_REGISTRY_TOKEN
#                       only for a PRIVATE registry: creates the 'pulse-registry' pull secret.
#                       The token is read from your environment and is never written to the repo.
#                       GHCR: a personal access token with the read:packages scope.
$Root = Split-Path -Parent $PSScriptRoot
Push-Location $Root
$Cfg = $null
try {
    $PulseImage = $env:PULSE_IMAGE
    $HelmArgs = @()
    if ($PulseImage) {
        $HelmArgs += @("--set-string", "image.repository=$PulseImage")
    }

    Write-Host "==> Namespace (enforces the 'restricted' Pod Security Standard)" -ForegroundColor Cyan
    kubectl apply -f k8s/namespace.yaml
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed" }

    if ($PulseImage -and $env:PULSE_REGISTRY_USER) {
        if (-not $env:PULSE_REGISTRY_TOKEN) { throw "PULSE_REGISTRY_USER is set but PULSE_REGISTRY_TOKEN is not." }
        # The registry host is the first part of the image name. Names without a dot, colon or
        # 'localhost' belong to Docker Hub.
        $server = $PulseImage.Split('/')[0]
        if ($server -notmatch '[.:]' -and $server -ne 'localhost') { $server = "https://index.docker.io/v1/" }
        Write-Host "==> Registry pull secret 'pulse-registry' for $server" -ForegroundColor Cyan
        $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:PULSE_REGISTRY_USER):$($env:PULSE_REGISTRY_TOKEN)"))
        $Cfg = Join-Path ([System.IO.Path]::GetTempPath()) ("pulse-regcfg-" + [guid]::NewGuid().ToString("N") + ".json")
        Set-Content -Path $Cfg -Value ('{"auths":{"' + $server + '":{"auth":"' + $auth + '"}}}') -Encoding ascii
        kubectl -n pulse create secret generic pulse-registry --type=kubernetes.io/dockerconfigjson --from-file=".dockerconfigjson=$Cfg" --dry-run=client -o yaml | kubectl apply -f -
        if ($LASTEXITCODE -ne 0) { throw "creating the registry pull secret failed" }
        $HelmArgs += @("--set", "imagePullSecrets[0].name=pulse-registry")
    }

    Write-Host "==> helm upgrade --install pulse" -ForegroundColor Cyan
    helm upgrade --install pulse chart/pulse -n pulse --wait --timeout 5m @HelmArgs
    if ($LASTEXITCODE -ne 0) { throw "helm upgrade failed" }

    Write-Host "==> helm test" -ForegroundColor Cyan
    helm test pulse -n pulse --logs
    if ($LASTEXITCODE -ne 0) { throw "helm test failed" }

    Write-Host ""
    Write-Host "Pulse is running. Open http://pulse.localhost:8080"
    Write-Host "(or: curl.exe -H 'Host: pulse.localhost' http://127.0.0.1:8080)"
} finally {
    if ($Cfg) { Remove-Item -Force $Cfg -ErrorAction SilentlyContinue }
    Pop-Location
}
