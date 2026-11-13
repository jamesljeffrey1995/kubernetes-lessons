# Builds the Pulse image twice (v1 and v2) and loads both into the kind cluster.
# kind nodes can't see images on your machine; 'kind load' copies them in.
$Root = Split-Path -Parent $PSScriptRoot
Push-Location $Root
# If 'docker' is really Podman, kind must be told to use its Podman provider.
if (((docker --version 2>$null | Out-String) -match "podman") -and -not $env:KIND_EXPERIMENTAL_PROVIDER) {
    $env:KIND_EXPERIMENTAL_PROVIDER = "podman"
}
try {
    foreach ($version in "v1", "v2") {
        Write-Host "==> Building pulse:$version" -ForegroundColor Cyan
        docker build --build-arg "VERSION=$version" -t "pulse:$version" app
        if ($LASTEXITCODE -ne 0) { throw "docker build failed for $version" }
    }
    Write-Host "==> Loading images into kind cluster 'lessons'" -ForegroundColor Cyan
    kind load docker-image pulse:v1 pulse:v2 --name lessons
    if ($LASTEXITCODE -ne 0) { throw "kind load failed" }
    Write-Host "Done. Next: .\capstone\scripts\deploy.ps1"
} finally {
    Pop-Location
}
