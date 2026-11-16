#!/usr/bin/env bash
# Tests scripts/check-prereqs.sh and .ps1 against simulated machines, using fake 'docker' and
# 'podman' commands and fake /sys and /proc trees: cgroup v1, rootless Docker/Podman with each
# host setting missing in turn, LDAP accounts without sub-UIDs, NFS home directories, Podman
# machine on Windows/macOS, corporate proxies, sudo, root's engine through sudo (ENGINE_SUDO=1)...
# Needs: bash, and pwsh to also test the PowerShell version. Doesn't need a running Docker.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# One fake engine, installed as both 'docker' and 'podman'. It answers from env vars set per scenario.
cat > "$WORK/bin/docker" <<'FAKE'
#!/bin/sh
case "$*" in
  "--version")
    if [ "$(basename "$0")" = podman ]; then echo "${FAKE_DOCKER_VERSION:-podman version 5.4.0}"
    else echo "${FAKE_DOCKER_VERSION:-Docker version 29.0.0, build fake}"; fi ;;
  "info")
    if [ -n "${FAKE_INFO_ERR:-}" ]; then echo "$FAKE_INFO_ERR" >&2; exit 125; fi
    echo "fake info" ;;
  # Docker's field names
  "info --format {{.CgroupVersion}}")    echo "${FAKE_CGROUP-2}" ;;
  "info --format {{.SecurityOptions}}")  echo "${FAKE_SECURITY:-[name=seccomp,profile=builtin]}" ;;
  "info --format {{.KernelVersion}}")    echo "${FAKE_ENGINE_KERNEL:-6.8.0-test}" ;;
  "info --format {{.MemTotal}}")         echo "${FAKE_MEM:-16000000000}" ;;
  "info --format {{.DockerRootDir}}")    echo "${FAKE_STORE_ROOT:-/}" ;;
  "info --format {{.Driver}}")           echo "${FAKE_STORE_DRIVER:-overlay2}" ;;
  "info --format {{.CgroupDriver}}")     echo "${FAKE_CGROUP_DRIVER:-systemd}" ;;
  # Podman's field names
  "info --format {{.Host.CgroupsVersion}}")    echo "${FAKE_PODMAN_CGROUP:-v2}" ;;
  # Through the fake sudo below, the same command is root's engine, which is never rootless.
  "info --format {{.Host.Security.Rootless}}")
    if [ "${FAKE_AS_ROOT:-}" = 1 ]; then echo false; else echo "${FAKE_PODMAN_ROOTLESS:-false}"; fi ;;
  "ps -a --format {{.Names}}")                 [ "${FAKE_AS_ROOT:-}" = 1 ] || echo "${FAKE_USER_CONTAINERS:-}" ;;
  "info --format {{.Host.Kernel}}")            echo "${FAKE_ENGINE_KERNEL:-6.8.0-test}" ;;
  "info --format {{.Host.MemTotal}}")          echo "${FAKE_MEM:-16000000000}" ;;
  "info --format {{.Store.GraphRoot}}")        echo "${FAKE_STORE_ROOT:-/}" ;;
  "info --format {{.Store.GraphDriverName}}")  echo "${FAKE_STORE_DRIVER:-overlay}" ;;
  "unshare cat /proc/self/uid_map")            printf '%b\n' "${FAKE_UID_MAP:-0 1000 1\n1 100000 65536}" ;;
  *) exit 1 ;;
esac
FAKE
cp "$WORK/bin/docker" "$WORK/bin/podman"
printf '#!/bin/sh\necho "kind v0.33.0 fake"\n' > "$WORK/bin/kind"
# Fake sudo: 'sudo -v' succeeds unless FAKE_SUDO_DENIED is set; anything else runs "as root".
cat > "$WORK/bin/sudo" <<'FAKE'
#!/bin/sh
if [ -n "${FAKE_SUDO_DENIED:-}" ]; then echo "Sorry, user tester may not run sudo." >&2; exit 1; fi
while [ $# -gt 0 ]; do
  case "$1" in -v) exit 0 ;; -H|-n) shift ;; *) break ;; esac
done
FAKE_AS_ROOT=1 exec "$@"
FAKE
printf '#!/bin/sh\necho "Client Version: v1.37.2"\n' > "$WORK/bin/kubectl"
printf '#!/bin/sh\necho "v3.22.1"\n' > "$WORK/bin/helm"
chmod +x "$WORK/bin/"*
PATH_FAKE="$WORK/bin:$PATH"

# Fake machine: a Linux host where everything rootless mode needs is in place.
U=4242
mkdir -p "$WORK/cg-good/user.slice/user-$U.slice/user@$U.service" "$WORK/cg-bad/user.slice/user-$U.slice/user@$U.service" \
         "$WORK/cg-rhel8/user.slice/user-$U.slice/user@$U.service"
echo "cpuset cpu io memory pids" > "$WORK/cg-good/user.slice/user-$U.slice/user@$U.service/cgroup.controllers"
# Like a RHEL 8 machine where the kernel refuses 'cpu': every controller except cpu, all the way down.
mkdir -p "$WORK/cg-nocpu/user.slice/user-$U.slice/user@$U.service"
echo "cpuset io memory pids" > "$WORK/cg-nocpu/user.slice/user-$U.slice/user@$U.service/cgroup.controllers"
echo "cpuset io memory pids" > "$WORK/cg-nocpu/cgroup.subtree_control"
# Delegation drop-ins: none, and one written by an admin.
mkdir -p "$WORK/dropin-none" "$WORK/dropin-set"
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' > "$WORK/dropin-set/delegate.conf"
echo "memory pids"               > "$WORK/cg-bad/user.slice/user-$U.slice/user@$U.service/cgroup.controllers"
echo "cpu memory pids"           > "$WORK/cg-rhel8/user.slice/user-$U.slice/user@$U.service/cgroup.controllers"
mkdir -p "$WORK/mods-good/ip_tables" "$WORK/mods-good/ip6_tables" "$WORK/mods-good/iptable_nat" "$WORK/mods-good/ip6table_nat" "$WORK/mods-none"
: > "$WORK/proc-modules-empty"
printf 'NAME="Red Hat Enterprise Linux"\nID="rhel"\nVERSION_ID="8.10"\n' > "$WORK/os-release-rhel8"
printf 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n' > "$WORK/os-release-ubuntu"
mkdir -p "$WORK/not-a-cgroup-fs" "$WORK/empty" "$WORK/systemd" "$WORK/linger" "$WORK/run/bus"
: > "$WORK/linger/tester"
: > "$WORK/fuse"
mkdir -p "$WORK/sys-good/fs/inotify" "$WORK/sys-hardened/user" "$WORK/sys-hardened/fs/inotify" "$WORK/sys-lowinotify/fs/inotify"
echo 8192 > "$WORK/sys-good/fs/inotify/max_user_instances"
echo 8192 > "$WORK/sys-hardened/fs/inotify/max_user_instances"
echo 0    > "$WORK/sys-hardened/user/max_user_namespaces"
echo 128  > "$WORK/sys-lowinotify/fs/inotify/max_user_instances"
# Kernel module databases: one where the iptables modules are built in, one that doesn't ship them.
mkdir -p "$WORK/kmod-builtin" "$WORK/kmod-absent"
printf 'kernel/net/ipv4/netfilter/ip_tables.ko\nkernel/net/ipv6/netfilter/ip6_tables.ko\nkernel/net/ipv4/netfilter/iptable_nat.ko\nkernel/net/ipv6/netfilter/ip6table_nat.ko\n' > "$WORK/kmod-builtin/modules.builtin"
printf 'kernel/net/netfilter/nf_tables.ko.xz:\n' > "$WORK/kmod-absent/modules.dep"

LINUX=(HOST_OS=Linux HOST_KERNEL=6.8.0-test "CURRENT_UID=$U" CURRENT_USER=tester OS_RELEASE="$WORK/os-release-ubuntu"
       CGROUP_ROOT="$WORK/cg-good" SYS_MODULE_DIR="$WORK/mods-good" PROC_MODULES="$WORK/proc-modules-empty"
       MODULES_DIR="$WORK/empty" PROC_SYS="$WORK/sys-good" RUN_SYSTEMD="$WORK/systemd" LINGER_DIR="$WORK/linger"
       DEV_FUSE="$WORK/fuse" USER_RUNTIME_DIR="$WORK/run" XDG_RUNTIME_DIR="$WORK/run"
       STORAGE_FSTYPE=xfs STORAGE_FREE_KB=50000000 "STORAGE_MOUNT_OPTS=rw,relatime" ULIMIT_NPROC=unlimited
       HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= KIND_EXPERIMENTAL_PROVIDER= SUDO_USER=
       DELEGATE_DROPIN_DIR="$WORK/dropin-none")
ROOTLESS_DOCKER=("${LINUX[@]}" "FAKE_SECURITY=[name=seccomp,profile=builtin name=rootless name=cgroupns]")
ROOTLESS_PODMAN=("${LINUX[@]}" "FAKE_DOCKER_VERSION=podman version 4.9.4-rhel" FAKE_PODMAN_ROOTLESS=true KIND_EXPERIMENTAL_PROVIDER=podman)
# Rootless Podman for your own user, used the ENGINE_SUDO way: root's Podman through sudo.
SUDO_PODMAN=("${ROOTLESS_PODMAN[@]}" ENGINE_SUDO=1)
PASSED=0

# run_one <label> <name> <expected exit> <expected text> <command...>
run_one() {
  local label=$1 name=$2 want_exit=$3 want_text=$4; shift 4
  local out code
  set +e
  out=$("$@" 2>&1)
  code=$?
  set -e
  if [ "$code" != "$want_exit" ] || ! grep -q -- "$want_text" <<<"$out"; then
    echo "FAIL [$label] $name: exit $code (want $want_exit), expected text: $want_text"
    echo "$out"
    exit 1
  fi
  echo "ok   [$label] $name"
  PASSED=$((PASSED + 1))
}

# scenario <name> <expected exit> <text that must appear> -- VAR=value ...
# Runs the bash script, and the PowerShell script (which hands over to bash on Linux).
scenario() {
  local name=$1 want_exit=$2 want_text=$3; shift 4
  run_one sh "$name" "$want_exit" "$want_text" env PATH="$PATH_FAKE" "$@" "$ROOT/scripts/check-prereqs.sh"
  if command -v pwsh >/dev/null; then
    run_one ps1 "$name" "$want_exit" "$want_text" env PATH="$PATH_FAKE" "$@" pwsh -NoProfile -File "$ROOT/scripts/check-prereqs.ps1"
  fi
}

# windows <name> <expected exit> <text> -- VAR=value ...   the PowerShell script's own (Windows) logic
windows() {
  local name=$1 want_exit=$2 want_text=$3; shift 4
  command -v pwsh >/dev/null || return 0
  run_one win "$name" "$want_exit" "$want_text" env PATH="$PATH_FAKE" CHECK_PREREQS_NATIVE=1 \
    HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= KIND_EXPERIMENTAL_PROVIDER= "$@" \
    pwsh -NoProfile -File "$ROOT/scripts/check-prereqs.ps1"
}

echo "--- ordinary (rootful) setups"
scenario "normal Docker, cgroup v2"            0 "All good" -- "${LINUX[@]}"
scenario "cgroup v1 fails"                     1 "update-grub" -- "${LINUX[@]}" FAKE_CGROUP=1
scenario "cgroup version unknown is a failure" 1 "could not determine the cgroup version" -- \
  "${LINUX[@]}" FAKE_CGROUP= CGROUP_FS_ROOT="$WORK/not-a-cgroup-fs"
scenario "Podman posing as docker"             0 "KIND_EXPERIMENTAL_PROVIDER" -- "${LINUX[@]}" "FAKE_DOCKER_VERSION=podman version 5.4.0"
scenario "run with sudo is refused"            1 "don't run the course scripts with sudo" -- "${LINUX[@]}" CURRENT_UID=0 SUDO_USER=tester
scenario "sudo refusal points to ENGINE_SUDO"  1 "Run as yourself with ENGINE_SUDO=1" -- "${LINUX[@]}" CURRENT_UID=0 SUDO_USER=tester
scenario "engine VM too small"                 1 "three Kubernetes nodes will not start" -- "${LINUX[@]}" FAKE_MEM=2000000000
scenario "proxy without NO_PROXY"              0 "NO_PROXY doesn't list localhost" -- "${LINUX[@]}" HTTPS_PROXY=http://proxy.corp:8080 NO_PROXY= no_proxy=
scenario "proxy on localhost"                  0 "cluster nodes can't reach that address" -- \
  "${LINUX[@]}" HTTPS_PROXY=http://127.0.0.1:3128 "NO_PROXY=localhost,127.0.0.1"
scenario "low inotify limit is only a note"    0 "All good" -- "${LINUX[@]}" PROC_SYS="$WORK/sys-lowinotify"

echo "--- the engine can't be reached"
scenario "Docker down"                         1 "Docker is not running" -- "${LINUX[@]}" "FAKE_INFO_ERR=Cannot connect to the Docker daemon"
scenario "rootless Docker, shell uses system socket" 1 "export DOCKER_HOST=unix://" -- \
  "${LINUX[@]}" "FAKE_INFO_ERR=permission denied while trying to connect" FAKE_ROOTLESS_SOCK=1
scenario "Podman: user namespaces disabled"    1 "user.max_user_namespaces=0" -- \
  "${ROOTLESS_PODMAN[@]}" "FAKE_INFO_ERR=cannot clone: Invalid argument" PROC_SYS="$WORK/sys-hardened"
scenario "Podman: newuidmap missing"           1 "no sub-UID range" -- \
  "${ROOTLESS_PODMAN[@]}" "FAKE_INFO_ERR=command required for rootless mode with multiple IDs: exec: newuidmap: not found"

echo "--- rootless Docker"
scenario "rootless Docker, everything set up"  0 "iptables kernel modules available" -- "${ROOTLESS_DOCKER[@]}"
scenario "rootless, no cgroup delegation"      1 "Delegate=cpu cpuset io memory pids" -- "${ROOTLESS_DOCKER[@]}" CGROUP_ROOT="$WORK/cg-bad"
scenario "rootless, cpuset/io missing is fine" 0 "kind doesn't require these" -- "${ROOTLESS_DOCKER[@]}" CGROUP_ROOT="$WORK/cg-rhel8"
scenario "rootless, no systemd user session"   1 "enable-linger" -- "${ROOTLESS_DOCKER[@]}" CGROUP_ROOT="$WORK/not-a-cgroup-fs"
scenario "rootless Docker not run by systemd"  1 "Cgroup Driver: none" -- "${ROOTLESS_DOCKER[@]}" FAKE_CGROUP_DRIVER=none
scenario "rootless, iptables modules missing"  1 "modules-load.d/iptables.conf" -- "${ROOTLESS_DOCKER[@]}" SYS_MODULE_DIR="$WORK/mods-none"
scenario "rootless, iptables built into kernel" 0 "iptables kernel modules available" -- \
  "${ROOTLESS_DOCKER[@]}" SYS_MODULE_DIR="$WORK/mods-none" MODULES_DIR="$WORK/kmod-builtin"
scenario "rootless, kernel ships no iptables"  0 "this kernel doesn't provide" -- \
  "${ROOTLESS_DOCKER[@]}" SYS_MODULE_DIR="$WORK/mods-none" MODULES_DIR="$WORK/kmod-absent"
scenario "rootless, no systemd at all (WSL)"   1 "isn't running systemd" -- "${ROOTLESS_DOCKER[@]}" RUN_SYSTEMD="$WORK/nope"
scenario "rootless, /dev/fuse missing"         1 "modprobe fuse" -- "${ROOTLESS_DOCKER[@]}" DEV_FUSE="$WORK/nope"
scenario "rootless, lingering off"             0 "loginctl enable-linger" -- "${ROOTLESS_DOCKER[@]}" LINGER_DIR="$WORK/empty"
scenario "rootless, home on NFS"               1 "can't hold rootless containers" -- "${ROOTLESS_DOCKER[@]}" STORAGE_FSTYPE=nfs4
scenario "rootless, low process limit"         0 "ulimit -u" -- "${ROOTLESS_DOCKER[@]}" ULIMIT_NPROC=4096

echo "--- rootless Podman (RHEL)"
scenario "rootless Podman, cgroup v2, set up"  0 "user IDs available to your containers" -- "${ROOTLESS_PODMAN[@]}"
scenario "RHEL 8 rootless Podman on cgroup v1" 1 "grubby --update-kernel=ALL" -- \
  "${ROOTLESS_PODMAN[@]}" FAKE_PODMAN_CGROUP=v1 OS_RELEASE="$WORK/os-release-rhel8" CGROUP_ROOT="$WORK/cg-bad"
scenario "RHEL 8 kernel warns but passes"      0 "older than 5.8" -- \
  "${ROOTLESS_PODMAN[@]}" HOST_KERNEL=4.18.0-553.el8_10.x86_64 FAKE_ENGINE_KERNEL=4.18.0-553.el8_10.x86_64 CGROUP_ROOT="$WORK/cg-rhel8"
scenario "delegation never configured"         1 "Delegation isn't configured" -- \
  "${ROOTLESS_PODMAN[@]}" CGROUP_ROOT="$WORK/cg-nocpu"
scenario "delegation configured, not rebooted"  1 "started BEFORE it was written" -- \
  "${ROOTLESS_PODMAN[@]}" CGROUP_ROOT="$WORK/cg-nocpu" DELEGATE_DROPIN_DIR="$WORK/dropin-set" \
  DELEGATE_CONF_MTIME=2000 USER_MANAGER_START=1000
scenario "delegation active, RT processes block cpu" 1 "REALTIME processes run" -- \
  "${ROOTLESS_PODMAN[@]}" CGROUP_ROOT="$WORK/cg-nocpu" DELEGATE_DROPIN_DIR="$WORK/dropin-set" \
  DELEGATE_CONF_MTIME=1000 USER_MANAGER_START=2000 "RT_PROCS_OVERRIDE=1187 multipathd /system.slice/multipathd.service"
scenario "delegation active, cpu refused, cause unknown" 1 "echo +cpu | sudo tee" -- \
  "${ROOTLESS_PODMAN[@]}" CGROUP_ROOT="$WORK/cg-nocpu" DELEGATE_DROPIN_DIR="$WORK/dropin-set" \
  DELEGATE_CONF_MTIME=1000 USER_MANAGER_START=2000 RT_PROCS_OVERRIDE=
scenario "LDAP account without sub-UIDs"       1 "echo \"\$USER:100000:65536\"" -- "${ROOTLESS_PODMAN[@]}" "FAKE_UID_MAP=0 1000 1"
scenario "Podman storage driver vfs"           0 "fuse-overlayfs" -- "${ROOTLESS_PODMAN[@]}" FAKE_STORE_DRIVER=vfs
scenario "Podman home nearly full"             0 "GB free where images are stored" -- "${ROOTLESS_PODMAN[@]}" STORAGE_FREE_KB=2000000
scenario "Podman storage on noexec mount"      0 "mounted 'noexec'" -- "${ROOTLESS_PODMAN[@]}" "STORAGE_MOUNT_OPTS=rw,nosuid,nodev,noexec"
scenario "Podman via su: no user bus"          0 "systemd-run --user' can't work" -- "${ROOTLESS_PODMAN[@]}" USER_RUNTIME_DIR="$WORK/empty" XDG_RUNTIME_DIR=
scenario "Podman 3 is flagged as old"          0 "Podman 3.x is old" -- "${ROOTLESS_PODMAN[@]}" "FAKE_DOCKER_VERSION=podman version 3.4.4"
scenario "Podman only, no provider variable"   0 "kind needs: export KIND_EXPERIMENTAL_PROVIDER=podman" -- \
  "${LINUX[@]}" "FAKE_DOCKER_VERSION=podman version 5.4.0"

echo "--- root's engine through sudo (ENGINE_SUDO=1, lessons/00-setup/rootful.md)"
scenario "ENGINE_SUDO: root's Podman is checked" 0 "root's podman, used through sudo" -- "${SUDO_PODMAN[@]}"
scenario "ENGINE_SUDO: no rootless checks"     0 "All good" -- "${SUDO_PODMAN[@]}" CGROUP_ROOT="$WORK/cg-bad" DEV_FUSE="$WORK/nope"
scenario "ENGINE_SUDO: sudo refused"           1 "sudo was refused" -- "${SUDO_PODMAN[@]}" FAKE_SUDO_DENIED=1
scenario "ENGINE_SUDO: old rootless cluster"   0 "ENGINE_SUDO=0 ./scripts/cluster-down.sh" -- \
  "${SUDO_PODMAN[@]}" FAKE_USER_CONTAINERS=lessons-control-plane
scenario "ENGINE_SUDO: realtime blocks cpu"    0 "applies to root's containers too" -- \
  "${SUDO_PODMAN[@]}" CGROUP_ROOT="$WORK/cg-nocpu" "RT_PROCS_OVERRIDE=1187 multipathd /system.slice/multipathd.service"
scenario "ENGINE_SUDO: root's Docker"          0 "root's docker, used through sudo" -- "${ROOTLESS_DOCKER[@]}" ENGINE_SUDO=1 \
  "FAKE_SECURITY=[name=seccomp,profile=builtin]"
scenario "rootless failure points to rootful.md" 1 "lessons/00-setup/rootful.md" -- "${ROOTLESS_PODMAN[@]}" CGROUP_ROOT="$WORK/cg-nocpu"
if [ "$(id -u)" != 0 ]; then      # root can write any file, so this can't be simulated as root
  mkdir -p "$WORK/kube-ro" && : > "$WORK/kube-ro/config" && chmod 444 "$WORK/kube-ro/config"
  scenario "kubeconfig owned by root"          1 "you can't write" -- "${LINUX[@]}" KUBECONFIG="$WORK/kube-ro/config"
fi

echo "--- engines inside a VM (Docker Desktop, Podman machine): host checks must be skipped"
scenario "Podman machine on macOS"             0 "runs rootless inside a VM" -- \
  "${ROOTLESS_PODMAN[@]}" HOST_OS=Darwin HOST_KERNEL=24.1.0 CGROUP_ROOT="$WORK/nope" RUN_SYSTEMD="$WORK/nope" DEV_FUSE="$WORK/nope"
scenario "Docker Desktop for Linux (VM kernel)" 0 "All good" -- \
  "${LINUX[@]}" FAKE_ENGINE_KERNEL=6.10.14-linuxkit CGROUP_FS_ROOT="$WORK/not-a-cgroup-fs"

echo "--- PowerShell script's own logic (what runs on Windows)"
windows "Docker Desktop, healthy"              0 "All good" --
windows "cgroup v1 (old WSL)"                  1 "wsl --update" -- FAKE_CGROUP=1
windows "Docker Desktop not started"           1 "Docker is not running" -- "FAKE_INFO_ERR=error during connect"
windows "Podman Desktop, rootless machine"     0 "podman machine set --rootful" -- \
  KIND_EXPERIMENTAL_PROVIDER=podman FAKE_PODMAN_ROOTLESS=true
windows "VM too small"                         1 "three Kubernetes nodes will not start" -- FAKE_MEM=2000000000
windows "proxy without NO_PROXY"               0 "setx NO_PROXY" -- HTTPS_PROXY=http://proxy.corp:8080 NO_PROXY= no_proxy=

echo "PASS: $PASSED scenario checks"
