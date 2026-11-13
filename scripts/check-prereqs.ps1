# Checks that this machine can run the course:
#   - the tools are installed (docker, kind, kubectl, helm, git)
#   - Docker is running
#   - Docker's setup can run Kubernetes 1.37 nodes: cgroup v2, and - if Docker runs in
#     ROOTLESS mode (Linux only) - the extra host settings kind needs for that.
#
# Usage:  .\scripts\check-prereqs.ps1               full check
#         .\scripts\check-prereqs.ps1 -ForCluster   only what cluster-up needs (no helm/git)
param([switch]$ForCluster)

$script:failed = $false
$script:warned = $false

# Paths are overridable only so tests/check-prereqs-test.sh can simulate other machines.
$CgroupRoot   = if ($env:CGROUP_ROOT)    { $env:CGROUP_ROOT }    else { "/sys/fs/cgroup" }
$SysModuleDir = if ($env:SYS_MODULE_DIR) { $env:SYS_MODULE_DIR } else { "/sys/module" }
$ProcModules  = if ($env:PROC_MODULES)   { $env:PROC_MODULES }   else { "/proc/modules" }
$CgroupFsRoot = if ($env:CGROUP_FS_ROOT) { $env:CGROUP_FS_ROOT } else { "/sys/fs/cgroup" }
$OsRelease    = if ($env:OS_RELEASE)     { $env:OS_RELEASE }     else { "/etc/os-release" }

function Pass($name, $msg) { Write-Host ("  [OK]   {0,-9} {1}" -f $name, $msg) -ForegroundColor Green }
function Fail($name, $msg) { Write-Host ("  [FAIL] {0,-9} {1}" -f $name, $msg) -ForegroundColor Red; $script:failed = $true }
function Warn($name, $msg) { Write-Host ("  [WARN] {0,-9} {1}" -f $name, $msg) -ForegroundColor Yellow; $script:warned = $true }
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

Write-Host "Checking tools..."
Check-Tool "docker"  { docker --version }
Check-Tool "kind"    { kind version }
Check-Tool "kubectl" { kubectl version --client }
if (-not $ForCluster) {
    Check-Tool "helm" { helm version --short }
    Check-Tool "git"  { git --version }
}

Write-Host ""
Write-Host "Checking Docker..."
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Fail "daemon" "Docker is not running, or you lack permission to use it"
    Fix "Docker Desktop: start it and wait for 'Engine running'."
} else {
    Pass "daemon" "Docker is running"

    # Docker and Podman report cgroup version and rootless mode under different fields.
    $dockerVersion = (docker --version 2>$null | Out-String)
    $isPodman = $dockerVersion -match "podman"
    if ($isPodman) {
        $cgroup = (docker info --format '{{.Host.CgroupsVersion}}' 2>$null | Out-String).Trim() -replace '^v', ''
        $rootless = ((docker info --format '{{.Host.Security.Rootless}}' 2>$null | Out-String).Trim() -eq "true")
        if ($env:KIND_EXPERIMENTAL_PROVIDER -eq "podman") {
            Pass "podman" "'docker' is Podman, and KIND_EXPERIMENTAL_PROVIDER=podman is set"
        } else {
            Warn "podman" "'docker' is really Podman. kind needs: `$env:KIND_EXPERIMENTAL_PROVIDER = 'podman'"
            Fix "(cluster-up sets this for you automatically.)"
        }
    } else {
        $cgroup = (docker info --format '{{.CgroupVersion}}' 2>$null | Out-String).Trim()
        $rootless = ((docker info --format '{{.SecurityOptions}}' 2>$null | Out-String) -match "rootless")
    }
    # Fallback on Linux: ask the filesystem directly (cgroup2fs = v2, tmpfs = v1).
    if (-not $cgroup -and (Test-Path $CgroupFsRoot) -and (Get-Command stat -ErrorAction SilentlyContinue)) {
        $fsType = (stat -fc %T $CgroupFsRoot 2>$null | Out-String).Trim()
        if ($fsType -eq "cgroup2fs") { $cgroup = "2" } elseif ($fsType -eq "tmpfs") { $cgroup = "1" }
    }
    $isRhel = (Test-Path $OsRelease) -and ((Get-Content $OsRelease) -match '^(ID|ID_LIKE)=.*(rhel|centos|fedora)')

    # cgroup v2 is required: recent Kubernetes (including 1.37, used here) refuses to start on
    # cgroup v1, and kind refuses rootless mode on cgroup v1 outright.
    if ($cgroup -eq "2") {
        Pass "cgroup" "cgroup v2"
    } elseif ($cgroup -eq "1") {
        Fail "cgroup" "cgroup v1 - Kubernetes 1.37 (used by kind v0.33) will not start on it"
        if ($isRhel) {
            Fix "RHEL/CentOS/Rocky 8 default to cgroup v1 (RHEL 9+ uses v2). Switch to v2 with:"
            Fix "  sudo grubby --update-kernel=ALL --args=`"systemd.unified_cgroup_hierarchy=1`""
            Fix "  sudo reboot"
            Fix "On a company-managed machine, changing kernel boot settings may need IT's approval."
        } else {
            Fix "Docker Desktop (WSL2): run 'wsl --update' and restart Docker Desktop; recent WSL uses cgroup v2."
            Fix "Linux: add systemd.unified_cgroup_hierarchy=1 to GRUB_CMDLINE_LINUX, update-grub, reboot."
        }
        if ($rootless) { Fix "Then re-run this script: rootless setups usually need the delegation step it shows next." }
    } else {
        Fail "cgroup" "could not determine the cgroup version"
        Fix "Check by hand (Linux): 'stat -fc %T /sys/fs/cgroup' prints cgroup2fs for v2 (needed) or tmpfs for v1."
    }

    # Rootless Docker only exists on Linux hosts (Docker Desktop on Windows/macOS runs a VM instead).
    if ($rootless) {
        Warn "rootless" "containers run in ROOTLESS mode - checking what kind needs for that"
        Fix "(If this is your own machine, normal 'rootful' Docker is simpler - see lesson 00.)"
        $uid = (id -u 2>$null | Out-String).Trim()
        $ctrlFile = "$CgroupRoot/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
        if ($cgroup -ne "2") {
            Warn "delegate" "can only be checked once the host is on cgroup v2 - re-run this script after switching"
        } elseif ($uid -and (Test-Path $ctrlFile)) {
            $controllers = (Get-Content $ctrlFile -Raw) -split '\s+'
            $missing = @("cpu", "cpuset", "io", "memory", "pids") | Where-Object { $controllers -notcontains $_ }
            if (-not $missing) {
                Pass "delegate" "cgroup controllers delegated to your user (cpu cpuset io memory pids)"
            } else {
                Fail "delegate" "cgroup controllers not delegated to your user: $($missing -join ' ')"
                Fix "sudo mkdir -p /etc/systemd/system/user@.service.d/"
                Fix "printf '[Service]\nDelegate=yes\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf"
                if ($isPodman) { Fix "sudo systemctl daemon-reload, then log out and back in" }
                else { Fix "sudo systemctl daemon-reload; systemctl --user restart docker" }
            }
        } else {
            Warn "delegate" "could not read $ctrlFile to check cgroup delegation"
        }
        $loaded = @()
        if (Test-Path $ProcModules) { $loaded = Get-Content $ProcModules | ForEach-Object { ($_ -split ' ')[0] } }
        $missingMods = @("ip_tables", "ip6_tables", "iptable_nat", "ip6table_nat") |
            Where-Object { -not (Test-Path (Join-Path $SysModuleDir $_)) -and ($loaded -notcontains $_) }
        if (-not $missingMods) {
            Pass "iptables" "iptables kernel modules loaded"
        } else {
            Fail "iptables" "kernel modules not loaded: $($missingMods -join ' ') (rootless networking will break)"
            Fix "printf 'ip6_tables\nip6table_nat\nip_tables\niptable_nat\n' | sudo tee /etc/modules-load.d/iptables.conf"
            Fix "sudo systemctl restart systemd-modules-load.service"
        }
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
