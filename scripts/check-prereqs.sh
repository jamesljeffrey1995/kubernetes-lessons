#!/usr/bin/env bash
# Checks that this machine can run the course:
#   - the tools are installed (docker, kind, kubectl, helm, git)
#   - Docker is running
#   - Docker's setup can run Kubernetes 1.37 nodes: cgroup v2, and - if Docker runs in
#     ROOTLESS mode - the extra host settings kind needs for that (cgroup delegation,
#     iptables kernel modules). These are the usual causes of "kind create cluster" failing.
#
# Usage:  ./scripts/check-prereqs.sh                 full check
#         ./scripts/check-prereqs.sh --for-cluster   only what cluster-up needs (no helm/git)
set -uo pipefail

# Paths are overridable only so tests/check-prereqs-test.sh can simulate other machines.
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
SYS_MODULE_DIR="${SYS_MODULE_DIR:-/sys/module}"
PROC_MODULES="${PROC_MODULES:-/proc/modules}"
CGROUP_FS_ROOT="${CGROUP_FS_ROOT:-/sys/fs/cgroup}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"

FOR_CLUSTER=false
[ "${1:-}" = "--for-cluster" ] && FOR_CLUSTER=true

failed=0
warned=0
pass() { printf '  \033[32m✔\033[0m %-9s %s\n' "$1" "$2"; }
fail() { printf '  \033[31m✘\033[0m %-9s %s\n' "$1" "$2"; failed=1; }
warn() { printf '  \033[33m!\033[0m %-9s %s\n' "$1" "$2"; warned=1; }
fix()  { printf '              %s\n' "$@"; }

check_tool() {
  local name=$1; shift
  local out
  # Capture ALL output, then take the first line. Piping straight into 'head -n 1' can kill
  # the tool with SIGPIPE (e.g. 'kubectl version' prints 2 lines) and, with pipefail, make a
  # working tool look broken - randomly.
  if out=$("$@" 2>/dev/null) && [ -n "$out" ]; then
    pass "$name" "${out%%$'\n'*}"
  else
    fail "$name" "not found or not working (see lessons/00-setup/README.md)"
  fi
}

echo "Checking tools..."
check_tool docker  docker --version
check_tool kind    kind version
check_tool kubectl kubectl version --client
if ! $FOR_CLUSTER; then
  check_tool helm  helm version --short
  check_tool git   git --version
fi

echo
echo "Checking Docker..."
if ! docker info >/dev/null 2>&1; then
  fail daemon "Docker is not running, or you lack permission to use it"
  fix "Docker Desktop: start it and wait for 'Engine running'."
  fix "Linux: sudo systemctl start docker, and make sure you're in the 'docker' group"
  fix "       (sudo usermod -aG docker \$USER, then log out and back in)."
else
  pass daemon "Docker is running"

  # Docker and Podman report cgroup version and rootless mode under different fields.
  DOCKER_VERSION=$(docker --version 2>/dev/null)
  IS_PODMAN=false
  grep -qi podman <<<"$DOCKER_VERSION" && IS_PODMAN=true
  if $IS_PODMAN; then
    CGROUP=$(docker info --format '{{.Host.CgroupsVersion}}' 2>/dev/null)   # "v1" or "v2"
    CGROUP=${CGROUP#v}
    ROOTLESS=$(docker info --format '{{.Host.Security.Rootless}}' 2>/dev/null)  # "true"/"false"
    if [ "${KIND_EXPERIMENTAL_PROVIDER:-}" = "podman" ]; then
      pass podman "'docker' is Podman, and KIND_EXPERIMENTAL_PROVIDER=podman is set"
    else
      warn podman "'docker' is really Podman. kind needs: export KIND_EXPERIMENTAL_PROVIDER=podman"
      fix "(cluster-up sets this for you automatically.)"
    fi
  else
    CGROUP=$(docker info --format '{{.CgroupVersion}}' 2>/dev/null)          # "1" or "2"
    ROOTLESS=false
    grep -q rootless <<<"$(docker info --format '{{.SecurityOptions}}' 2>/dev/null)" && ROOTLESS=true
  fi
  # Fallback: ask the Linux filesystem directly (cgroup2fs = v2, tmpfs = v1).
  if [ -z "$CGROUP" ] && [ -d "$CGROUP_FS_ROOT" ]; then
    case "$(stat -fc %T "$CGROUP_FS_ROOT" 2>/dev/null)" in
      cgroup2fs) CGROUP=2 ;;
      tmpfs)     CGROUP=1 ;;
    esac
  fi

  IS_RHEL=false
  grep -qiE '^(ID|ID_LIKE)=.*(rhel|centos|fedora)' "$OS_RELEASE" 2>/dev/null && IS_RHEL=true

  # cgroup v2 is required: recent Kubernetes (including 1.37, used here) refuses to start on
  # cgroup v1, and kind refuses rootless mode on cgroup v1 outright.
  if [ "$CGROUP" = "2" ]; then
    pass cgroup "cgroup v2"
  elif [ "$CGROUP" = "1" ]; then
    fail cgroup "cgroup v1 - Kubernetes 1.37 (used by kind v0.33) will not start on it"
    if $IS_RHEL; then
      fix "RHEL/CentOS/Rocky 8 default to cgroup v1 (RHEL 9+ uses v2). Switch to v2 with:"
      fix "  sudo grubby --update-kernel=ALL --args=\"systemd.unified_cgroup_hierarchy=1\""
      fix "  sudo reboot"
      fix "On a company-managed machine, changing kernel boot settings may need IT's approval."
    else
      fix "Ubuntu/Debian: add systemd.unified_cgroup_hierarchy=1 to GRUB_CMDLINE_LINUX in"
      fix "/etc/default/grub, run 'sudo update-grub' and reboot. (Ubuntu 21.10+ is v2 by default.)"
      fix "WSL2: update WSL ('wsl --update') - recent versions use cgroup v2."
    fi
    [ "$ROOTLESS" = "true" ] && fix "Then re-run this script: rootless setups usually need the delegation step it shows next."
  else
    fail cgroup "could not determine the cgroup version"
    fix "Check by hand: 'stat -fc %T /sys/fs/cgroup' prints cgroup2fs for v2 (needed) or tmpfs for v1."
  fi

  # Rootless Docker: works with kind, but needs host settings rootful Docker doesn't.
  if [ "$ROOTLESS" = "true" ]; then
    warn rootless "containers run in ROOTLESS mode - checking what kind needs for that"
    fix "(If this is your own machine, normal 'rootful' Docker is simpler - see lesson 00.)"

    # 1) cgroup delegation: the user's systemd slice must be allowed to manage cpu etc.
    UID_NUM=$(id -u)
    CTRL_FILE="$CGROUP_ROOT/user.slice/user-${UID_NUM}.slice/user@${UID_NUM}.service/cgroup.controllers"
    if [ "$CGROUP" != "2" ]; then
      warn delegate "can only be checked once the host is on cgroup v2 - re-run this script after switching"
    elif [ -r "$CTRL_FILE" ]; then
      MISSING=""
      for c in cpu cpuset io memory pids; do
        grep -qw "$c" "$CTRL_FILE" || MISSING="$MISSING $c"
      done
      if [ -z "$MISSING" ]; then
        pass delegate "cgroup controllers delegated to your user (cpu cpuset io memory pids)"
      else
        fail delegate "cgroup controllers not delegated to your user:$MISSING"
        fix "sudo mkdir -p /etc/systemd/system/user@.service.d/"
        fix "printf '[Service]\\nDelegate=yes\\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf"
        if $IS_PODMAN; then
          fix "sudo systemctl daemon-reload, then log out and back in"
        else
          fix "sudo systemctl daemon-reload && systemctl --user restart docker"
        fi
        fix "(systemd 252+ does this by default; yours: $(systemctl --version 2>/dev/null | head -n 1))"
      fi
    else
      warn delegate "could not read $CTRL_FILE to check cgroup delegation"
    fi

    # 2) iptables modules: without them, Services and the gateway don't work in rootless mode.
    MISSING_MODS=""
    for m in ip_tables ip6_tables iptable_nat ip6table_nat; do
      [ -d "$SYS_MODULE_DIR/$m" ] || grep -qw "^$m" "$PROC_MODULES" 2>/dev/null || MISSING_MODS="$MISSING_MODS $m"
    done
    if [ -z "$MISSING_MODS" ]; then
      pass iptables "iptables kernel modules loaded"
    else
      fail iptables "kernel modules not loaded:$MISSING_MODS (rootless networking will break)"
      fix "printf 'ip6_tables\\nip6table_nat\\nip_tables\\niptable_nat\\n' | sudo tee /etc/modules-load.d/iptables.conf"
      fix "sudo systemctl restart systemd-modules-load.service"
    fi
  fi
fi

echo
if [ $failed -ne 0 ]; then
  echo "Fix the items marked ✘ above, then re-run this script."
  echo "More help: lessons/00-setup/README.md (section 'Things that go wrong')."
  exit 1
fi
if [ $warned -ne 0 ]; then
  echo "OK, with warnings (marked !). You can continue."
else
  echo "All good."
fi
$FOR_CLUSTER || echo "Next: ./scripts/cluster-up.sh"
exit 0
