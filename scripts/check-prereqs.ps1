# Checks that this machine can run the course:
#   - the tools are installed (a container engine, kind, kubectl, helm, git)
#   - the container engine (Docker or Podman) is running
#   - it can run Kubernetes 1.37 nodes: cgroup v2, enough memory, sane proxy settings
#
# On Linux and macOS this script hands over to check-prereqs.sh, which also checks the Linux host
# settings that ROOTLESS Docker/Podman need. Those don't exist on Windows, where the engine runs
# in a VM (Docker Desktop, Podman machine, Rancher Desktop).
#
# Usage:  .\scripts\check-prereqs.ps1               full check
#         .\scripts\check-prereqs.ps1 -ForCluster   only what cluster-up needs (no helm/git)
param([switch]$ForCluster)

$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
if (-not $onWindows -and $env:CHECK_PREREQS_NATIVE -ne "1" -and (Get-Command bash -ErrorAction SilentlyContinue)) {
    $sh = Join-Path $PSScriptRoot "check-prereqs.sh"
    if ($ForCluster) { & bash $sh --for-cluster } else { & bash $sh }
    exit $LASTEXITCODE
}

$script:failed = $false
$script:warned = $false

function Pass($name, $msg) { Write-Host ("  [OK]   {0,-9} {1}" -f $name, $msg) -ForegroundColor Green }
function Fail($name, $msg) { Write-Host ("  [FAIL] {0,-9} {1}" -f $name, $msg) -ForegroundColor Red; $script:failed = $true }
function Warn($name, $msg) { Write-Host ("  [WARN] {0,-9} {1}" -f $name, $msg) -ForegroundColor Yellow; $script:warned = $true }
function Note($name, $msg) { Write-Host ("  [NOTE] {0,-9} {1}" -f $name, $msg) -ForegroundColor Cyan }
function Fix($msg)         { Write-Host "                   $msg" }

function Check-Tool($name, [scriptblock]$cmd) {
    $out = $null
    $code = 1
    try {
        $all = @(& $cmd 2>$null)   # capture everything first; cutting a native pipe short breaks $LASTEXITCODE
        $code = $LASTEXITCODE
        if ($all.Count -gt 0) { $out = $all[0] }
    } catch { }
    if ($code -eq 0 -and $out) { Pass $name $out } else { Fail $name "not found or not working (see lessons/00-setup/README.md)" }
}

# Sets $Ctr (docker or podman) and $IsPodman.
. (Join-Path $PSScriptRoot "engine.ps1")
function Get-EngineInfo($format) {
    try { return (& $Ctr info --format $format 2>$null | Out-String).Trim() } catch { return "" }
}

Write-Host "Checking tools..."
if ($Ctr -eq "podman") {
    Check-Tool "podman" { podman --version }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Note "docker" "no 'docker' command - the scripts use 'podman' directly. Where a lesson says 'docker', type 'podman'."
    }
} else {
    Check-Tool "docker" { docker --version }
}
Check-Tool "kind"    { kind version }
Check-Tool "kubectl" { kubectl version --client }
if (-not $ForCluster) {
    Check-Tool "helm" { helm version --short }
    Check-Tool "git"  { git --version }
}
$kindVersion = ""
try { $kindVersion = (kind version 2>$null | Out-String) } catch { }
if ($kindVersion -and $kindVersion -notmatch "v0\.33\.") {
    Warn "kind" "the course is tested with kind v0.33.x (Kubernetes 1.37); other versions create other Kubernetes versions"
}

Write-Host ""
Write-Host "Checking the container engine ($Ctr)..."
$infoOk = $false
try { & $Ctr info *> $null; $infoOk = ($LASTEXITCODE -eq 0) } catch { }
if (-not $infoOk) {
    if ($IsPodman -or $Ctr -eq "podman") {
        Fail "engine" "Podman is installed but 'podman info' fails"
        Fix "Start the Podman VM: podman machine start   (first time: podman machine init --memory 8192)"
    } else {
        Fail "daemon" "Docker is not running, or you lack permission to use it"
        Fix "Docker Desktop / Rancher Desktop: start it and wait until it says the engine is running."
    }
} else {
    Pass "engine" "$Ctr is running"

    # Docker and Podman report the same facts under different field names.
    if ($IsPodman) {
        $cgroup   = (Get-EngineInfo '{{.Host.CgroupsVersion}}') -replace '^v', ''
        $rootless = ((Get-EngineInfo '{{.Host.Security.Rootless}}') -eq "true")
        $memText  = Get-EngineInfo '{{.Host.MemTotal}}'
        if ($env:KIND_EXPERIMENTAL_PROVIDER -ne "podman") {
            Warn "podman" "the engine is Podman. kind needs: `$env:KIND_EXPERIMENTAL_PROVIDER = 'podman'"
            Fix "(cluster-up and the capstone scripts set this for you. Set it yourself when you run 'kind' by hand.)"
        }
    } else {
        $cgroup   = Get-EngineInfo '{{.CgroupVersion}}'
        $rootless = ((Get-EngineInfo '{{.SecurityOptions}}') -match "rootless")
        $memText  = Get-EngineInfo '{{.MemTotal}}'
    }

    # cgroup v2 is required: recent Kubernetes (including 1.37, used here) refuses to start on cgroup v1.
    if ($cgroup -eq "2") {
        Pass "cgroup" "cgroup v2"
    } elseif ($cgroup -eq "1") {
        Fail "cgroup" "cgroup v1 - Kubernetes 1.37 (used by kind v0.33) will not start on it"
        Fix "Docker Desktop (WSL2): run 'wsl --update' and restart Docker Desktop; recent WSL uses cgroup v2."
        Fix "Podman machine: recreate it ('podman machine rm' then 'podman machine init') - current images use v2."
    } else {
        Fail "cgroup" "could not determine the cgroup version"
        Fix "Run '$Ctr info' and look for the cgroup version; it must be 2."
    }

    # Memory the ENGINE has: on Windows that's the size of its VM, not of your laptop.
    $mem = 0L
    if ([long]::TryParse($memText, [ref]$mem) -and $mem -gt 0) {
        $memMb = [long]($mem / 1MB)
        if ($memMb -lt 3500) {
            Fail "memory" "the container engine has only $memMb MB - three Kubernetes nodes will not start"
            Fix "Docker Desktop: Settings > Resources (or %UserProfile%\.wslconfig, 'memory=8GB', then 'wsl --shutdown')."
            Fix "Podman: podman machine stop; podman machine set --memory 8192; podman machine start"
        } elseif ($memMb -lt 5500) {
            Warn "memory" "the container engine has $memMb MB; lessons 13 (autoscaling) and the capstone want about 6 GB"
            Fix "Docker Desktop: Settings > Resources. Podman: podman machine set --memory 8192"
        } else {
            Pass "memory" "$memMb MB available to containers"
        }
    }

    # Corporate proxies: kubectl and curl must NOT send local traffic to the proxy.
    $proxy = @($env:HTTPS_PROXY, $env:https_proxy, $env:HTTP_PROXY, $env:http_proxy) | Where-Object { $_ } | Select-Object -First 1
    if ($proxy) {
        $noProxy = "$($env:NO_PROXY)$($env:no_proxy)"
        if ($noProxy -match "localhost" -and $noProxy -match "127\.0\.0\.1") {
            Pass "proxy" "proxy is set, and NO_PROXY covers localhost and 127.0.0.1"
        } else {
            Warn "proxy" "a proxy is set but NO_PROXY doesn't list localhost and 127.0.0.1"
            Fix "kubectl would send requests for your local cluster to the company proxy and fail. Set it for good:"
            Fix "  setx NO_PROXY `"localhost,127.0.0.1,.localhost`"      (then open a new terminal)"
        }
        if ($proxy -match "(//|^)(localhost|127\.0\.0\.1)[:/]") {
            Warn "proxy" "your proxy is on localhost ($proxy) - cluster nodes can't reach that address"
            Fix "Inside a node, 'localhost' is the node. Image pulls will fail with 'proxyconnect ... connection refused'."
        }
    }

    # Rootless here means "rootless inside the engine's VM" (Podman machine's default).
    if ($rootless) {
        Warn "rootless" "$Ctr runs rootless inside its VM - its settings can't be checked from here"
        Fix "If creating the cluster fails, switch the VM to rootful mode, which kind handles best:"
        Fix "  podman machine stop; podman machine set --rootful; podman machine start"
    }
}

Write-Host ""
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "Note: you are on Windows PowerShell $($PSVersionTable.PSVersion). It works, but PowerShell 7 ('pwsh') is recommended." -ForegroundColor Yellow
}
if ($script:failed) {
    Write-Host "Fix the items marked FAIL above, then re-run this script."
    Write-Host "More help: lessons/00-setup/README.md (section 'Things that go wrong')."
    exit 1
}
if ($script:warned) { Write-Host "OK, with warnings (marked WARN). You can continue." } else { Write-Host "All good." }
if (-not $ForCluster) { Write-Host "Next: .\scripts\cluster-up.ps1" }
exit 0
