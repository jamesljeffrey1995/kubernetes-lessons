# Dot-sourced (not run) by the course's PowerShell scripts. Works out which container engine to use:
#
#   $Ctr       the command to run containers with: "docker" or "podman"
#   $IsPodman  $true when that command is Podman - including a 'docker' command that is really
#              Podman (Podman Desktop can install one)
#
# kind itself only looks at KIND_EXPERIMENTAL_PROVIDER (default: docker), so we follow the same
# rule, and fall back to Podman when there is no 'docker' command at all.
$Ctr = "docker"
if ($env:KIND_EXPERIMENTAL_PROVIDER -eq "podman") {
    $Ctr = "podman"
} elseif (-not (Get-Command docker -ErrorAction SilentlyContinue) -and (Get-Command podman -ErrorAction SilentlyContinue)) {
    $Ctr = "podman"
}
$IsPodman = $false
try { $IsPodman = ((& $Ctr --version 2>$null | Out-String) -match "podman") } catch { }
if ($IsPodman) { $env:KIND_EXPERIMENTAL_PROVIDER = "podman" }
