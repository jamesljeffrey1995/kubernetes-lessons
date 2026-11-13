# Checks that the tools this course needs are installed and Docker is running.

$script:failed = $false

function Check($name, [scriptblock]$cmd) {
    $out = $null
    $code = 1
    try {
        $all = @(& $cmd 2>$null)   # capture everything first; cutting a native pipe short breaks $LASTEXITCODE
        $code = $LASTEXITCODE
        if ($all.Count -gt 0) { $out = $all[0] }
    } catch { }
    if ($code -eq 0 -and $out) {
        Write-Host ("  [OK]   {0,-8} {1}" -f $name, $out) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] {0,-8} not found or not working" -f $name) -ForegroundColor Red
        $script:failed = $true
    }
}

Write-Host "Checking prerequisites..."
Check "docker"  { docker --version }
Check "kind"    { kind version }
Check "kubectl" { kubectl version --client }
Check "helm"    { helm version --short }
Check "git"     { git --version }

docker info *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host ("  [OK]   {0,-8} {1}" -f "daemon", "Docker is running") -ForegroundColor Green
} else {
    Write-Host ("  [FAIL] {0,-8} {1}" -f "daemon", "Docker is not running (start Docker Desktop)") -ForegroundColor Red
    $script:failed = $true
}

Write-Host ""
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "Note: you are on Windows PowerShell $($PSVersionTable.PSVersion). It works, but PowerShell 7 ('pwsh') is recommended." -ForegroundColor Yellow
}
if (-not $script:failed) {
    Write-Host "All good. Next: .\scripts\cluster-up.ps1"
    exit 0
} else {
    Write-Host "Fix the items marked FAIL (see lessons/00-setup/README.md), then re-run this script."
    exit 1
}
