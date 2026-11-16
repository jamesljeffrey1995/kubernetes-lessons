#!/usr/bin/env bash
# Checks that this machine can run the course:
#   - the tools are installed (a container engine, kind, kubectl, helm, git)
#   - the container engine (Docker or Podman) is running and reachable
#   - it can run Kubernetes 1.37 nodes: cgroup v2, enough memory, sane proxy settings
#   - if it runs ROOTLESS (the default for Podman, optional for Docker): everything kind needs
#     for that. Rootless mode has by far the most ways to fail, so most of this file is about it.
#     Each check is explained in lessons/00-setup/rootless.md.
#
# Usage:  ./scripts/check-prereqs.sh                 full check
#         ./scripts/check-prereqs.sh --for-cluster   only what cluster-up needs (no helm/git)
#
# ✔ = fine   ! = works, but read it   ✘ = must be fixed first
set -uo pipefail

# Everything below is overridable only so tests/check-prereqs-test.sh can simulate other machines.
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
SYS_MODULE_DIR="${SYS_MODULE_DIR:-/sys/module}"
PROC_MODULES="${PROC_MODULES:-/proc/modules}"
CGROUP_FS_ROOT="${CGROUP_FS_ROOT:-/sys/fs/cgroup}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
PROC_SYS="${PROC_SYS:-/proc/sys}"
DELEGATE_DROPIN_DIR="${DELEGATE_DROPIN_DIR:-/etc/systemd/system/user@.service.d}"
RUN_SYSTEMD="${RUN_SYSTEMD:-/run/systemd/system}"
LINGER_DIR="${LINGER_DIR:-/var/lib/systemd/linger}"
DEV_FUSE="${DEV_FUSE:-/dev/fuse}"
HOST_OS="${HOST_OS:-$(uname -s)}"
HOST_KERNEL="${HOST_KERNEL:-$(uname -r)}"
MODULES_DIR="${MODULES_DIR:-/lib/modules/$HOST_KERNEL}"
CURRENT_UID="${CURRENT_UID:-$(id -u)}"
CURRENT_USER="${CURRENT_USER:-$(id -un 2>/dev/null || echo "${USER:-you}")}"
USER_RUNTIME_DIR="${USER_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$CURRENT_UID}}"
EXPECTED_KIND="0.33"

FOR_CLUSTER=false
[ "${1:-}" = "--for-cluster" ] && FOR_CLUSTER=true

failed=0
warned=0
pass() { printf '  \033[32m✔\033[0m %-9s %s\n' "$1" "$2"; }
fail() { printf '  \033[31m✘\033[0m %-9s %s\n' "$1" "$2"; failed=1; }
warn() { printf '  \033[33m!\033[0m %-9s %s\n' "$1" "$2"; warned=1; }
note() { printf '  \033[36m·\033[0m %-9s %s\n' "$1" "$2"; }
fix()  { printf '              %s\n' "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }

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

# Called when cgroup controllers are missing for the user. There are three different causes,
# and they need three different fixes, so work out which one it is:
#   1. delegation was never configured
#   2. it is configured, but the user's systemd instance started before that and kept the old setting
#   3. it is configured and active, but the KERNEL refuses to enable the cpu controller, because
#      realtime processes are running outside the root cgroup (cgroup v2 rule on older kernels)
explain_delegation() {
  local missing=$1 conf="" conf_mtime="" started="" uid=$CURRENT_UID
  for f in "$DELEGATE_DROPIN_DIR"/*.conf; do
    [ -r "$f" ] && grep -qE '^[[:space:]]*Delegate=' "$f" && conf=$f
  done

  if [ -z "$conf" ]; then
    fix "Delegation isn't configured. An admin (sudo) must run:"
    fix "  sudo mkdir -p /etc/systemd/system/user@.service.d/"
    fix "  printf '[Service]\\nDelegate=cpu cpuset io memory pids\\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf"
    fix "  sudo systemctl daemon-reload"
    fix "Then REBOOT - the setting applies when your user's systemd restarts."
    fix "(systemd 252+ does this by default; yours: $(systemctl --version 2>/dev/null | head -n 1))"
    return
  fi

  # 2) Has the user's systemd restarted since the file was written?
  conf_mtime="${DELEGATE_CONF_MTIME:-$(stat -c %Y "$conf" 2>/dev/null)}"
  started="${USER_MANAGER_START:-$(date -d "$(systemctl show "user@$uid.service" -p ActiveEnterTimestamp --value 2>/dev/null)" +%s 2>/dev/null)}"
  if [ -n "$conf_mtime" ] && [ -n "$started" ] && [ "$conf_mtime" -gt "$started" ] 2>/dev/null; then
    fix "$conf exists, but your user's systemd was started BEFORE it was written, so it still"
    fix "has the old setting. Logging out doesn't help while any session (SSH, VS Code, tmux) or"
    fix "lingering keeps it running. Reboot, then re-run this script."
    fix "(Without a reboot, an admin can run: sudo systemctl restart user@$uid.service - this ends your sessions.)"
    return
  fi

  # 3) Configured and active. Then the question is whether the kernel lets anyone enable 'cpu'.
  if grep -qw cpu <<<"$missing" && ! grep -qw cpu "$CGROUP_ROOT/cgroup.subtree_control" 2>/dev/null; then
    local rt
    if [ -n "${RT_PROCS_OVERRIDE+x}" ]; then
      rt=$RT_PROCS_OVERRIDE
    else
      # Realtime (FIFO/RR) processes whose cgroup isn't the root one. Kernel threads are always
      # in the root cgroup, so they drop out by themselves.
      rt=$(ps -eo pid=,cls=,comm= 2>/dev/null | awk '$2 == "FF" || $2 == "RR" { print $1, $3 }' |
        while read -r pid comm; do
          cg=$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null)
          [ -n "$cg" ] && [ "$cg" != "/" ] && echo "$pid $comm $cg"
        done)
    fi
    fix "$conf is in place and active, but the 'cpu' controller isn't enabled even at the top"
    fix "of the cgroup tree ($CGROUP_ROOT/cgroup.subtree_control). That isn't something you configured wrong."
    if [ -n "$rt" ]; then
      fix "Cause: on this kernel, cgroup v2 refuses to enable 'cpu' while REALTIME processes run"
      fix "outside the root cgroup (see 'realtime' in the kernel's cgroup-v2 documentation). These are:"
      while read -r line; do fix "    $line"; done <<<"$rt"
      fix "Changing that is a system administration decision (those services chose realtime priority"
      fix "for a reason), so don't work around it yourself. Ask IT - the details are under"
      fix "'RHEL 8' in lessons/00-setup/rootless.md. Kubernetes cannot run rootless here until then."
    else
      fix "No realtime processes found, so the cause is unknown. For IT or for an issue, collect:"
      fix "  cat $CGROUP_ROOT/cgroup.controllers $CGROUP_ROOT/cgroup.subtree_control"
      fix "  echo +cpu | sudo tee $CGROUP_ROOT/cgroup.subtree_control      # the error message is the answer"
    fi
    return
  fi

  fix "$conf is in place and your user's systemd has restarted since, yet these are still missing."
  fix "Follow the chain down to see where they stop:"
  fix "  grep . $CGROUP_ROOT/cgroup.subtree_control $CGROUP_ROOT/user.slice/cgroup.subtree_control \\"
  fix "        $CGROUP_ROOT/user.slice/user-$uid.slice/cgroup.subtree_control"
}

# ---- Which container engine? ---------------------------------------------------------------
# kind uses Docker unless KIND_EXPERIMENTAL_PROVIDER says otherwise, so we follow the same rule.
# With no 'docker' command at all (RHEL without the podman-docker package) we fall back to Podman.
CTR=docker
case "${KIND_EXPERIMENTAL_PROVIDER:-}" in
  podman) CTR=podman ;;
  docker|"") have docker || { have podman && CTR=podman; } ;;
  *) CTR="${KIND_EXPERIMENTAL_PROVIDER}" ;;
esac
CTR_VERSION=$("$CTR" --version 2>/dev/null)
IS_PODMAN=false
grep -qi podman <<<"$CTR_VERSION" && IS_PODMAN=true
cinfo() { "$CTR" info --format "$1" 2>/dev/null; }

echo "Checking tools..."
if [ "$CTR" != docker ] && [ "$CTR" != podman ]; then
  fail engine "KIND_EXPERIMENTAL_PROVIDER=$CTR - this course's scripts support docker and podman only"
elif [ "$CTR" = podman ]; then
  check_tool podman podman --version
  have docker || note docker "no 'docker' command - the scripts use 'podman' directly. Where a lesson says 'docker', type 'podman'."
else
  check_tool docker docker --version
fi
check_tool kind    kind version
check_tool kubectl kubectl version --client
if ! $FOR_CLUSTER; then
  check_tool helm  helm version --short
  check_tool git   git --version
fi
KIND_VERSION=$(kind version 2>/dev/null)
if [ -n "$KIND_VERSION" ] && ! grep -q "v$EXPECTED_KIND\." <<<"$KIND_VERSION"; then
  warn kind "the course is tested with kind v$EXPECTED_KIND.x (Kubernetes 1.37); other versions create other Kubernetes versions"
fi

# Running the scripts with sudo is the classic over-correction when rootless setup fails. It creates
# the cluster in ROOT's engine and writes root's kubeconfig, so afterwards your own user sees nothing.
if [ "$CURRENT_UID" = "0" ] && [ -n "${SUDO_USER:-}" ] && [ "${ALLOW_SUDO:-}" != "1" ]; then
  fail sudo "don't run the course scripts with sudo"
  fix "sudo uses root's containers and writes root's kubeconfig; '$SUDO_USER' then can't see the cluster."
  fix "Run them as yourself. (Really want a root-owned cluster? ALLOW_SUDO=1, and use sudo for every command.)"
fi

echo
echo "Checking the container engine ($CTR)..."
INFO_ERR=$("$CTR" info 2>&1 >/dev/null)
INFO_RC=$?
if [ $INFO_RC -ne 0 ]; then
  if $IS_PODMAN || [ "$CTR" = podman ]; then
    fail engine "Podman is installed but 'podman info' fails:"
    fix "  $(tail -n 2 <<<"$INFO_ERR" | tr '\n' ' ')"
    if [ "$(cat "$PROC_SYS/user/max_user_namespaces" 2>/dev/null)" = "0" ]; then
      fix "User namespaces are switched off (user.max_user_namespaces=0, a common hardening setting)."
      fix "Rootless containers cannot work without them. An admin must run:"
      fix "  echo 'user.max_user_namespaces=28633' | sudo tee /etc/sysctl.d/99-userns.conf && sudo sysctl --system"
    elif grep -qiE 'newuidmap|newgidmap|subuid|subgid' <<<"$INFO_ERR"; then
      fix "Your user has no sub-UID range, or newuidmap is missing (package: shadow-utils / uidmap)."
      fix "See 'subuid' in lessons/00-setup/rootless.md."
    elif grep -qiE 'podman machine|unable to connect to Podman' <<<"$INFO_ERR"; then
      fix "macOS/Windows: start the Podman VM with 'podman machine start'."
    fi
  else
    fail daemon "Docker is not running, or you lack permission to use it"
    ROOTLESS_SOCK="$USER_RUNTIME_DIR/docker.sock"
    if [ -S "$ROOTLESS_SOCK" ] || [ -n "${FAKE_ROOTLESS_SOCK:-}" ]; then
      fix "ROOTLESS Docker is running for your user, but this shell is talking to the system-wide Docker."
      fix "Point it at your own daemon (add this line to ~/.bashrc to keep it):"
      fix "  export DOCKER_HOST=unix://$ROOTLESS_SOCK"
    else
      fix "Docker Desktop: start it and wait for 'Engine running'."
      fix "Linux: sudo systemctl start docker, and make sure you're in the 'docker' group"
      fix "       (sudo usermod -aG docker \$USER, then log out and back in)."
      fix "Rootless Docker: systemctl --user start docker, and export DOCKER_HOST=unix://$ROOTLESS_SOCK"
      if [ "$(cat "$PROC_SYS/kernel/apparmor_restrict_unprivileged_userns" 2>/dev/null)" = "1" ]; then
        fix "Ubuntu 24.04+: AppArmor blocks rootless Docker until you add a profile for 'rootlesskit' -"
        fix "see https://docs.docker.com/engine/security/rootless/troubleshoot/ ('permission denied' on userns)."
      fi
    fi
  fi
else
  pass engine "$CTR is running"

  # Docker and Podman report the same facts under different field names.
  if $IS_PODMAN; then
    CGROUP=$(cinfo '{{.Host.CgroupsVersion}}')                    # "v1" or "v2"
    CGROUP=${CGROUP#v}
    ROOTLESS=$(cinfo '{{.Host.Security.Rootless}}')               # "true"/"false"
    ENGINE_KERNEL=$(cinfo '{{.Host.Kernel}}')
    ENGINE_MEM=$(cinfo '{{.Host.MemTotal}}')
    STORE_ROOT=$(cinfo '{{.Store.GraphRoot}}')
    STORE_DRIVER=$(cinfo '{{.Store.GraphDriverName}}')
    if [ "$CTR" = docker ]; then
      if [ "${KIND_EXPERIMENTAL_PROVIDER:-}" = "podman" ]; then
        pass podman "'docker' is Podman, and KIND_EXPERIMENTAL_PROVIDER=podman is set"
      else
        warn podman "'docker' is really Podman. kind needs: export KIND_EXPERIMENTAL_PROVIDER=podman"
        fix "(cluster-up and the capstone scripts set this for you. Set it yourself when you run 'kind' by hand.)"
      fi
    elif [ "${KIND_EXPERIMENTAL_PROVIDER:-}" != "podman" ]; then
      warn podman "kind needs: export KIND_EXPERIMENTAL_PROVIDER=podman"
      fix "(cluster-up and the capstone scripts set this for you. Set it yourself when you run 'kind' by hand.)"
    fi
    PODMAN_MAJOR=$(sed -E 's/[^0-9]*([0-9]+)\..*/\1/' <<<"$CTR_VERSION")
    if [ -n "$PODMAN_MAJOR" ] && [ "$PODMAN_MAJOR" -lt 4 ] 2>/dev/null; then
      warn podman "Podman $PODMAN_MAJOR.x is old: kind can't check cgroup controllers before Podman 4, and its networking differs"
      fix "Upgrade if you can (current RHEL 8 and 9 releases ship Podman 4 or newer: sudo dnf upgrade podman)."
    fi
  else
    CGROUP=$(cinfo '{{.CgroupVersion}}')                          # "1" or "2"
    ROOTLESS=false
    grep -q rootless <<<"$(cinfo '{{.SecurityOptions}}')" && ROOTLESS=true
    ENGINE_KERNEL=$(cinfo '{{.KernelVersion}}')
    ENGINE_MEM=$(cinfo '{{.MemTotal}}')
    STORE_ROOT=$(cinfo '{{.DockerRootDir}}')
    STORE_DRIVER=$(cinfo '{{.Driver}}')
  fi

  # Is the engine running on THIS Linux machine, or in a VM (Docker Desktop, Podman machine,
  # Rancher Desktop, Colima)? In a VM, this machine's /sys, /proc and systemd say nothing about
  # the engine, so the host checks below must be skipped rather than report nonsense.
  ENGINE_LOCAL=false
  if [ "$HOST_OS" = "Linux" ] && { [ -z "$ENGINE_KERNEL" ] || [ "$ENGINE_KERNEL" = "$HOST_KERNEL" ]; }; then
    ENGINE_LOCAL=true
  fi

  # Fallback: ask the Linux filesystem directly (cgroup2fs = v2, tmpfs = v1).
  if [ -z "$CGROUP" ] && $ENGINE_LOCAL && [ -d "$CGROUP_FS_ROOT" ]; then
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
    if ! $ENGINE_LOCAL; then
      fix "Docker Desktop (WSL2): run 'wsl --update' and restart Docker Desktop."
      fix "Podman machine: recreate it ('podman machine rm' then 'podman machine init') - current images use v2."
    elif $IS_RHEL; then
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

  # Memory the ENGINE has - on Docker Desktop / Podman machine that's the VM's size, not the laptop's.
  if [ -n "$ENGINE_MEM" ] && [ "$ENGINE_MEM" -gt 0 ] 2>/dev/null; then
    MEM_MB=$((ENGINE_MEM / 1024 / 1024))
    if [ "$MEM_MB" -lt 3500 ]; then
      fail memory "the container engine has only ${MEM_MB} MB - three Kubernetes nodes will not start"
      fix "Docker Desktop: Settings > Resources > Memory. Podman: podman machine stop && podman machine set --memory 8192 && podman machine start"
    elif [ "$MEM_MB" -lt 5500 ]; then
      warn memory "the container engine has ${MEM_MB} MB; lessons 13 (autoscaling) and the capstone want about 6 GB"
      fix "Docker Desktop: Settings > Resources > Memory. Podman: podman machine set --memory 8192"
    else
      pass memory "${MEM_MB} MB available to containers"
    fi
  fi

  # Corporate proxies: kubectl and curl must NOT send local traffic to the proxy, and kind copies
  # these variables into the nodes, where 'localhost' means the node itself.
  PROXY="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
  if [ -n "$PROXY" ]; then
    NOPROXY="${NO_PROXY:-${no_proxy:-}}"
    if grep -q 'localhost' <<<"$NOPROXY" && grep -q '127\.0\.0\.1' <<<"$NOPROXY"; then
      pass proxy "proxy is set, and NO_PROXY covers localhost and 127.0.0.1"
    else
      warn proxy "a proxy is set but NO_PROXY doesn't list localhost and 127.0.0.1"
      fix "kubectl would send requests for your local cluster to the company proxy and fail. Add to ~/.bashrc:"
      fix "  export NO_PROXY=\"localhost,127.0.0.1,.localhost,\${NO_PROXY:-}\"; export no_proxy=\"\$NO_PROXY\""
    fi
    if grep -qE '//(localhost|127\.0\.0\.1)[:/]|^(localhost|127\.0\.0\.1)[:/]' <<<"$PROXY"; then
      warn proxy "your proxy is on localhost ($PROXY) - cluster nodes can't reach that address"
      fix "Inside a node, 'localhost' is the node. Image pulls will fail with 'proxyconnect ... connection refused'."
      fix "Make the local proxy (cntlm, px...) listen on your machine's LAN address and use that address instead."
    fi
  fi

  if [ "$ROOTLESS" != "true" ]; then
    $ENGINE_LOCAL && [ "$HOST_OS" = "Linux" ] && pass rootful "containers run as root (the simple case - nothing more to check)"
  elif ! $ENGINE_LOCAL; then
    # Podman machine / Podman Desktop on Windows and macOS: rootless inside a VM we can't inspect.
    warn rootless "$CTR runs rootless inside a VM (Podman machine?) - its host settings can't be checked from here"
    fix "If creating the cluster fails, switch the VM to rootful mode, which kind handles best:"
    fix "  podman machine stop && podman machine set --rootful && podman machine start"
  else
    # ---- Rootless on this Linux machine -----------------------------------------------------
    warn rootless "containers run in ROOTLESS mode - checking what kind needs for that"
    fix "(Every check below is explained in lessons/00-setup/rootless.md. On your own machine,"
    fix " normal 'rootful' Docker is far simpler.)"

    # 0) systemd must be the init system: delegation, user sessions and kind's node boot rely on it.
    if [ ! -d "$RUN_SYSTEMD" ]; then
      fail systemd "this system isn't running systemd, which rootless kind depends on"
      fix "WSL2: add '[boot]' and 'systemd=true' to /etc/wsl.conf, then run 'wsl --shutdown' from Windows."
      fix "Inside a container or chroot: use a real VM or machine instead."
    fi

    # 1) sub-UIDs: a rootless container maps its users onto a range of UIDs owned by you.
    #    Accounts that come from LDAP/AD/SSSD usually have NO range, and image pulls then fail.
    if $IS_PODMAN; then
      UID_MAP=$("$CTR" unshare cat /proc/self/uid_map 2>/dev/null)
      UID_COUNT=$(awk '{ n += $3 } END { print n + 0 }' <<<"$UID_MAP")
      if [ "$UID_COUNT" -ge 65537 ]; then
        pass subuid "$UID_COUNT user IDs available to your containers"
      else
        fail subuid "only $UID_COUNT user ID(s) mapped - the Kubernetes node image needs 65536"
        fix "Your account has no (or too small a) range in /etc/subuid and /etc/subgid. This is normal for"
        fix "accounts that come from LDAP / Active Directory. Check: grep \"^\$USER:\" /etc/subuid /etc/subgid"
        fix "Fix (pick a range no other user in those files uses):"
        fix "  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 \"\$USER\""
        fix "  # if usermod says the user doesn't exist (LDAP/AD), append the line directly instead:"
        fix "  echo \"\$USER:100000:65536\" | sudo tee -a /etc/subuid /etc/subgid"
        fix "  podman system migrate      # make Podman pick up the new range"
      fi
    fi

    # 2) cgroup delegation: kind itself insists on cpu, memory and pids (see validateProvider in
    #    kind's source); cpuset and io are nice to have and impossible to delegate on old systemd.
    CTRL_FILE="$CGROUP_ROOT/user.slice/user-${CURRENT_UID}.slice/user@${CURRENT_UID}.service/cgroup.controllers"
    if [ "$CGROUP" != "2" ]; then
      warn delegate "can only be checked once the host is on cgroup v2 - re-run this script after switching"
    elif [ -r "$CTRL_FILE" ]; then
      MISSING=""; OPTIONAL=""
      for c in cpu memory pids; do grep -qw "$c" "$CTRL_FILE" || MISSING="$MISSING $c"; done
      for c in cpuset io;       do grep -qw "$c" "$CTRL_FILE" || OPTIONAL="$OPTIONAL $c"; done
      if [ -z "$MISSING" ]; then
        pass delegate "cgroup controllers delegated to your user ($(tr '\n' ' ' <"$CTRL_FILE" | sed 's/ *$//'))"
        [ -n "$OPTIONAL" ] && note delegate "not delegated:$OPTIONAL - kind doesn't require these (cpuset needs systemd 244+)"
      else
        fail delegate "cgroup controllers not delegated to your user:$MISSING"
        explain_delegation "$MISSING"
      fi
    else
      fail delegate "no systemd user session for your user ($CTRL_FILE is missing)"
      fix "Rootless containers need one. Common cause: switching user with 'su' or 'sudo -i'."
      fix "Log in directly as yourself (a new SSH or desktop login, not su/sudo), or run:"
      fix "  sudo loginctl enable-linger \"\$USER\"      (then log in again)"
    fi
    if ! $IS_PODMAN && [ "$(cinfo '{{.CgroupDriver}}')" = "none" ]; then
      fail delegate "rootless Docker reports 'Cgroup Driver: none' - it was not started by systemd"
      fix "Stop the dockerd-rootless.sh you started by hand and use the systemd user service:"
      fix "  systemctl --user enable --now docker"
    fi

    # 3) The user's D-Bus session: cluster-up starts kind with 'systemd-run --user', which needs it.
    if $IS_PODMAN; then
      if [ -e "$USER_RUNTIME_DIR/bus" ]; then
        if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
          note session "XDG_RUNTIME_DIR isn't set in this shell (you used su/sudo?) - cluster-up sets it for you"
        else
          pass session "systemd user session reachable ($USER_RUNTIME_DIR/bus)"
        fi
      else
        warn session "no systemd user bus at $USER_RUNTIME_DIR/bus - 'systemd-run --user' can't work"
        fix "cluster-up then starts kind directly, which on some distributions fails with a 'Delegate=yes' error."
        fix "Log in directly as yourself (not via su/sudo), or: sudo loginctl enable-linger \"\$USER\" and log in again."
      fi
    fi

    # 4) Lingering: without it, systemd kills ALL your containers when your last session ends.
    if [ -e "$LINGER_DIR/$CURRENT_USER" ]; then
      pass linger "lingering enabled - the cluster survives you logging out"
    else
      warn linger "lingering is off: logging out (or a dropped SSH connection) stops your whole cluster"
      fix "loginctl enable-linger          (if that's refused: sudo loginctl enable-linger \"\$USER\")"
    fi

    # 5) Where images are stored. Network filesystems can't hold rootless container storage.
    if [ -n "$STORE_ROOT" ]; then
      PROBE=$STORE_ROOT
      while [ ! -e "$PROBE" ] && [ "$PROBE" != "/" ] && [ -n "$PROBE" ]; do PROBE=$(dirname "$PROBE"); done
      FSTYPE="${STORAGE_FSTYPE:-$(stat -f -c %T "$PROBE" 2>/dev/null)}"
      FREE_KB="${STORAGE_FREE_KB:-$(df -Pk "$PROBE" 2>/dev/null | awk 'NR==2 { print $4 }')}"
      MOUNT_OPTS="${STORAGE_MOUNT_OPTS:-$(findmnt -no OPTIONS -T "$PROBE" 2>/dev/null)}"
      case "$FSTYPE" in
        nfs*|cifs|smb*|gpfs|lustre|ceph|afs|ecryptfs|9p|fuseblk|vboxsf)
          fail storage "container storage ($STORE_ROOT) is on '$FSTYPE', which can't hold rootless containers"
          fix "Network/shared home directories don't support the file ownership tricks rootless mode needs."
          fix "Move the storage to a LOCAL disk you can write to, for example:"
          if $IS_PODMAN; then
            fix "  sudo mkdir -p /var/lib/containers-\$USER && sudo chown \"\$USER\" /var/lib/containers-\$USER"
            fix "  mkdir -p ~/.config/containers"
            fix "  printf '[storage]\\ndriver = \"overlay\"\\ngraphroot = \"/var/lib/containers-%s\"\\n' \"\$USER\" > ~/.config/containers/storage.conf"
            fix "  podman system reset        # deletes existing rootless images and containers"
          else
            fix "  set \"data-root\" to a local directory in ~/.config/docker/daemon.json, then: systemctl --user restart docker"
          fi
          ;;
        "") note storage "could not determine the filesystem of $STORE_ROOT" ;;
        *)  pass storage "container storage on local filesystem ($FSTYPE): $STORE_ROOT" ;;
      esac
      if [ "$STORE_DRIVER" = "vfs" ]; then
        warn storage "storage driver is 'vfs': every image layer is a full copy - very slow, and needs 20+ GB"
        fix "Install fuse-overlayfs (sudo dnf install fuse-overlayfs / sudo apt install fuse-overlayfs),"
        fix "then 'podman system reset' so Podman switches to the overlay driver."
      fi
      if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 10485760 ] 2>/dev/null; then
        warn storage "only $((FREE_KB / 1024 / 1024)) GB free where images are stored - the course needs about 10 GB"
        fix "Rootless images live in your HOME directory, which often has a quota at work."
        fix "Free space with '$CTR system prune', or move the storage (see lessons/00-setup/rootless.md)."
      fi
      if grep -qw noexec <<<"$MOUNT_OPTS"; then
        warn storage "container storage is on a filesystem mounted 'noexec' - containers may fail with 'permission denied'"
        fix "Hardened machines mount /home or /tmp noexec. Move the storage to a filesystem without it."
      fi
    fi

    # 6) /dev/fuse: in rootless mode kind always starts nodes with '--device /dev/fuse'.
    if [ -e "$DEV_FUSE" ]; then
      pass fuse "/dev/fuse exists"
    else
      fail fuse "/dev/fuse is missing - kind passes it to every rootless node, so creating one fails"
      fix "sudo modprobe fuse && echo fuse | sudo tee /etc/modules-load.d/fuse.conf"
    fi

    # 7) iptables modules: a rootless container can't load kernel modules, so the host must have
    #    them loaded already, or Services and the gateway don't route traffic.
    MISSING_MODS=""; ABSENT_MODS=""
    for m in ip_tables ip6_tables iptable_nat ip6table_nat; do
      [ -d "$SYS_MODULE_DIR/$m" ] && continue
      grep -qw "^$m" "$PROC_MODULES" 2>/dev/null && continue
      grep -q "/$m\.ko" "$MODULES_DIR/modules.builtin" 2>/dev/null && continue       # compiled into the kernel
      if [ -r "$MODULES_DIR/modules.dep" ] && ! grep -q "/$m\.ko" "$MODULES_DIR/modules.dep"; then
        ABSENT_MODS="$ABSENT_MODS $m"                                                   # this kernel doesn't ship it
      else
        MISSING_MODS="$MISSING_MODS $m"
      fi
    done
    if [ -n "$MISSING_MODS" ]; then
      fail iptables "kernel modules not loaded:$MISSING_MODS (rootless networking will break)"
      fix "printf 'ip6_tables\\nip6table_nat\\nip_tables\\niptable_nat\\n' | sudo tee /etc/modules-load.d/iptables.conf"
      fix "sudo systemctl restart systemd-modules-load.service"
    elif [ -n "$ABSENT_MODS" ]; then
      warn iptables "this kernel doesn't provide:$ABSENT_MODS (an nftables-only system?)"
      fix "Nothing to load. If Services or http://localhost:8080 don't work later, this is the first suspect:"
      fix "check 'kubectl -n kube-system logs ds/kube-proxy' for iptables errors."
    else
      pass iptables "iptables kernel modules available"
    fi

    # 8) Process limit: every process in every Pod on every node counts against YOUR user's limit.
    NPROC="${ULIMIT_NPROC:-$(ulimit -u 2>/dev/null)}"
    if [ -n "$NPROC" ] && [ "$NPROC" != "unlimited" ] && [ "$NPROC" -lt 8192 ] 2>/dev/null; then
      warn nproc "your user may run only $NPROC processes (ulimit -u); a 3-node cluster can exceed that"
      fix "Symptom: Pods crash with 'fork: retry: Resource temporarily unavailable'. An admin can raise it:"
      fix "  echo \"\$USER soft nproc 32768\" | sudo tee /etc/security/limits.d/90-kind.conf     (then log in again)"
    fi

    # 9) Old kernels (RHEL 8 is 4.18).
    KMAJ=${HOST_KERNEL%%.*}; KREST=${HOST_KERNEL#*.}; KMIN=${KREST%%[!0-9]*}
    if [ "$KMAJ" -lt 5 ] 2>/dev/null || { [ "$KMAJ" = "5" ] && [ "${KMIN:-0}" -lt 8 ] 2>/dev/null; }; then
      warn kernel "kernel $HOST_KERNEL is older than 5.8, the minimum Kubernetes documents for cgroup v2"
      fix "It may still work (RHEL backports a lot), but this combination is not tested by this course."
      fix "If the cluster misbehaves, a RHEL 9+/Ubuntu 22.04+ VM is the reliable way out."
    fi
  fi

  # inotify: each node and many Pods open inotify handles; distro defaults (128 instances) are low
  # for a 3-node cluster. Not rootless-specific. Informational, because it only bites sometimes.
  if $ENGINE_LOCAL; then
    INST=$(cat "$PROC_SYS/fs/inotify/max_user_instances" 2>/dev/null)
    if [ -n "$INST" ] && [ "$INST" -lt 512 ] 2>/dev/null; then
      note inotify "fs.inotify.max_user_instances=$INST is low for 3 nodes. If nodes fail to boot or Pods"
      fix "report 'too many open files', raise it:"
      fix "  printf 'fs.inotify.max_user_watches=524288\\nfs.inotify.max_user_instances=512\\n' | sudo tee /etc/sysctl.d/99-kind.conf && sudo sysctl --system"
    fi
  fi
fi

echo
if [ $failed -ne 0 ]; then
  echo "Fix the items marked ✘ above, then re-run this script."
  echo "More help: lessons/00-setup/README.md ('Things that go wrong') and lessons/00-setup/rootless.md."
  exit 1
fi
if [ $warned -ne 0 ]; then
  echo "OK, with warnings (marked !). You can continue."
else
  echo "All good."
fi
$FOR_CLUSTER || echo "Next: ./scripts/cluster-up.sh"
exit 0
