#!/usr/bin/env bash
# Tests scripts/check-prereqs.sh and .ps1 against simulated machines (cgroup v1, rootless Docker
# with and without delegation / iptables modules, Podman), using a fake 'docker' command.
# Needs: bash, and pwsh to also test the PowerShell version. Doesn't need a running Docker.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fake tools. 'docker' answers from env vars set per scenario.
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/sh
case "$*" in
  "--version")                           echo "${FAKE_DOCKER_VERSION:-Docker version 29.0.0, build fake}" ;;
  "info")                                echo "fake info" ;;
  "info --format {{.CgroupVersion}}")    echo "${FAKE_CGROUP-2}" ;;
  "info --format {{.SecurityOptions}}")  echo "${FAKE_SECURITY:-[name=seccomp,profile=builtin]}" ;;
  "info --format {{.Host.CgroupsVersion}}")   echo "${FAKE_PODMAN_CGROUP:-v2}" ;;
  "info --format {{.Host.Security.Rootless}}") echo "${FAKE_PODMAN_ROOTLESS:-false}" ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\necho "kind v0.33.0 fake"\n' > "$WORK/bin/kind"
printf '#!/bin/sh\necho "Client Version: v1.37.2"\n' > "$WORK/bin/kubectl"
printf '#!/bin/sh\necho "v3.22.1"\n' > "$WORK/bin/helm"
chmod +x "$WORK/bin/"*
PATH_FAKE="$WORK/bin:$PATH"

# Fake /sys trees
U=$(id -u)
mkdir -p "$WORK/cg-good/user.slice/user-$U.slice/user@$U.service" "$WORK/cg-bad/user.slice/user-$U.slice/user@$U.service"
echo "cpuset cpu io memory pids" > "$WORK/cg-good/user.slice/user-$U.slice/user@$U.service/cgroup.controllers"
echo "memory pids" > "$WORK/cg-bad/user.slice/user-$U.slice/user@$U.service/cgroup.controllers"
mkdir -p "$WORK/mods-good/ip_tables" "$WORK/mods-good/ip6_tables" "$WORK/mods-good/iptable_nat" "$WORK/mods-good/ip6table_nat" "$WORK/mods-none"
: > "$WORK/proc-modules-empty"
printf 'NAME="Red Hat Enterprise Linux"\nID="rhel"\nVERSION_ID="8.10"\n' > "$WORK/os-release-rhel8"
printf 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n' > "$WORK/os-release-ubuntu"
mkdir -p "$WORK/not-a-cgroup-fs"

ROOTLESS='[name=seccomp,profile=builtin name=rootless name=cgroupns]'
PASSED=0

# scenario <name> <expected exit> <text that must appear> -- VAR=value ...
scenario() {
  local name=$1 want_exit=$2 want_text=$3; shift 4
  for impl in sh ps1; do
    if [ $impl = ps1 ] && ! command -v pwsh >/dev/null; then continue; fi
    local out code
    set +e
    if [ $impl = sh ]; then
      out=$(env PATH="$PATH_FAKE" "$@" "$ROOT/scripts/check-prereqs.sh" 2>&1)
    else
      out=$(env PATH="$PATH_FAKE" "$@" pwsh -NoProfile -File "$ROOT/scripts/check-prereqs.ps1" 2>&1)
    fi
    code=$?
    set -e
    if [ "$code" != "$want_exit" ] || ! grep -q -- "$want_text" <<<"$out"; then
      echo "FAIL [$impl] $name: exit $code (want $want_exit), expected text: $want_text"
      echo "$out"
      exit 1
    fi
    echo "ok   [$impl] $name"
    PASSED=$((PASSED + 1))
  done
}

scenario "normal Docker, cgroup v2"           0 "All good" -- \
  CGROUP_ROOT="$WORK/cg-good" SYS_MODULE_DIR="$WORK/mods-good"
scenario "cgroup v1 fails"                    1 "update-grub" -- \
  FAKE_CGROUP=1 OS_RELEASE="$WORK/os-release-ubuntu"
scenario "rootless, everything set up"        0 "iptables kernel modules loaded" -- \
  FAKE_SECURITY="$ROOTLESS" CGROUP_ROOT="$WORK/cg-good" SYS_MODULE_DIR="$WORK/mods-good" PROC_MODULES="$WORK/proc-modules-empty"
scenario "rootless, no cgroup delegation"     1 "Delegate=cpu cpuset io memory pids" -- \
  FAKE_SECURITY="$ROOTLESS" CGROUP_ROOT="$WORK/cg-bad" SYS_MODULE_DIR="$WORK/mods-good" PROC_MODULES="$WORK/proc-modules-empty"
scenario "rootless, iptables modules missing" 1 "modules-load.d/iptables.conf" -- \
  FAKE_SECURITY="$ROOTLESS" CGROUP_ROOT="$WORK/cg-good" SYS_MODULE_DIR="$WORK/mods-none" PROC_MODULES="$WORK/proc-modules-empty"
scenario "Podman posing as docker"            0 "KIND_EXPERIMENTAL_PROVIDER" -- \
  FAKE_DOCKER_VERSION="podman version 5.4.0"
scenario "RHEL 8 rootless Podman on cgroup v1" 1 "grubby --update-kernel=ALL" -- \
  FAKE_DOCKER_VERSION="podman version 4.9.4-rhel" FAKE_PODMAN_CGROUP=v1 FAKE_PODMAN_ROOTLESS=true \
  OS_RELEASE="$WORK/os-release-rhel8" CGROUP_ROOT="$WORK/cg-bad" SYS_MODULE_DIR="$WORK/mods-good"
scenario "rootless Podman, cgroup v2, set up"  0 "iptables kernel modules loaded" -- \
  FAKE_DOCKER_VERSION="podman version 4.9.4-rhel" FAKE_PODMAN_CGROUP=v2 FAKE_PODMAN_ROOTLESS=true \
  KIND_EXPERIMENTAL_PROVIDER=podman CGROUP_ROOT="$WORK/cg-good" SYS_MODULE_DIR="$WORK/mods-good" PROC_MODULES="$WORK/proc-modules-empty"
scenario "rootless, no systemd user session"  1 "enable-linger" -- \
  FAKE_SECURITY="$ROOTLESS" CGROUP_ROOT="$WORK/not-a-cgroup-fs" SYS_MODULE_DIR="$WORK/mods-good" PROC_MODULES="$WORK/proc-modules-empty"
scenario "cgroup version unknown is a failure" 1 "could not determine the cgroup version" -- \
  FAKE_CGROUP= CGROUP_FS_ROOT="$WORK/not-a-cgroup-fs"

echo "PASS: $PASSED scenario checks"
