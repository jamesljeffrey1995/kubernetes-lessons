# Builds the Pulse image twice (v1 and v2) and copies both into the kind cluster.
# kind nodes can't see images on your machine, so they have to be loaded into each node.
#
# Works with Docker and Podman. It deliberately does NOT use 'kind load docker-image': that
# command always calls the 'docker' binary (even with the Podman provider), and can fail with
# Docker's containerd image store. Saving to a tar file and loading that works everywhere.
$Root = Split-Path -Parent $PSScriptRoot
# Sets $Ctr (docker or podman) and KIND_EXPERIMENTAL_PROVIDER when Podman is in use.
. (Join-Path (Split-Path -Parent $Root) "scripts/engine.ps1")
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pulse-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Tmp | Out-Null
Push-Location $Root
try {
    foreach ($version in "v1", "v2") {
        # The full name matters with Podman, which would otherwise call the image 'localhost/pulse'.
        # Kubernetes reads 'pulse:v1' as 'docker.io/library/pulse:v1', so that's the name we build.
        $image = "docker.io/library/pulse:$version"
        Write-Host "==> Building pulse:$version" -ForegroundColor Cyan
        & $Ctr build --build-arg "VERSION=$version" -t $image app
        if ($LASTEXITCODE -ne 0) { throw "$Ctr build failed for $version" }
        & $Ctr save -o (Join-Path $Tmp "pulse-$version.tar") $image
        if ($LASTEXITCODE -ne 0) { throw "$Ctr save failed for $version" }
    }
    Write-Host "==> Loading images into kind cluster 'lessons'" -ForegroundColor Cyan
    foreach ($version in "v1", "v2") {
        kind load image-archive (Join-Path $Tmp "pulse-$version.tar") --name lessons
        if ($LASTEXITCODE -ne 0) { throw "kind load failed for $version" }
    }
    Write-Host "Done. Next: .\capstone\scripts\deploy.ps1"
} finally {
    Pop-Location
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
