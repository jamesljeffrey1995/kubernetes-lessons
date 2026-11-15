#!/usr/bin/env bash
# Creates the "lessons" kind cluster and installs the platform pieces:
#   - Gateway API CRDs (platform/gateway-api-crds.yaml)
#   - Traefik gateway/ingress controller (platform/traefik.yaml)
#   - metrics-server, for `kubectl top` and autoscaling (platform/metrics-server.yaml)
#
# Safe to re-run: if the cluster already exists it restarts stopped nodes if needed and
# (re)applies the platform. If a step times out on a slow machine, just run it again.
#
# Usage:   ./scripts/cluster-up.sh
# Options: KIND_CONFIG=path/to/other-kind-config.yaml ./scripts/cluster-up.sh
#          SKIP_HOST_CHECKS=1 ./scripts/cluster-up.sh   (skip the pre-flight checks - not recommended)
set -euo pipefail

CLUSTER_NAME="lessons"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND_CONFIG="${KIND_CONFIG:-$ROOT/platform/kind-config.yaml}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Sets CTR (docker or podman), IS_PODMAN, and KIND_EXPERIMENTAL_PROVIDER when Podman is in use.
# shellcheck source=scripts/engine.sh
source "$ROOT/scripts/engine.sh"

step "Checking this machine (tools, container engine, cgroups, rootless mode)"
if [ "${SKIP_HOST_CHECKS:-}" = "1" ]; then
  warn "SKIP_HOST_CHECKS=1 - skipping host checks"
else
  "$ROOT/scripts/check-prereqs.sh" --for-cluster || die "This machine isn't ready yet - see the ✘ items above."
fi

# Turns kind's error output into advice. kind's own messages for these are a Go stack trace.
explain_failure() {
  local log=$1
  if grep -q "could not find a log line" "$log"; then
    warn "The node container started but kind never saw it finish booting. Two known causes:"
    warn " 1. inotify limits too low for 3 nodes (any engine). Check: sysctl fs.inotify.max_user_instances"
    warn "    Below 512? Raise it - the command is in the output of ./scripts/check-prereqs.sh"
    warn " 2. Rootless Podman's log relay misses the boot message. Fix, then re-run:"
    warn "      mkdir -p ~/.config/containers"
    warn "      printf '[containers]\\nlog_driver = \"k8s-file\"\\n' >> ~/.config/containers/containers.conf"
  elif grep -q 'Delegate=yes' "$log"; then
    warn "cgroup delegation isn't active for your user. Run ./scripts/check-prereqs.sh;"
    warn "after changing delegate.conf you must FULLY log out (every session - including VS Code"
    warn "remote/terminal sessions) or reboot. Check with: loginctl user-status \$USER"
  elif grep -q 'requires cgroup v2' "$log"; then
    warn "kind sees cgroup v1. Check: stat -fc %T /sys/fs/cgroup  (must print cgroup2fs)"
  elif grep -qiE 'insufficient UIDs or GIDs|lchown .*invalid argument|newuidmap' "$log"; then
    warn "Your user has too few sub-UIDs to unpack the node image (typical for LDAP/AD accounts)."
    warn "See the 'subuid' check in ./scripts/check-prereqs.sh for the fix."
  elif grep -qiE 'slirp4netns|pasta.*(not found|no such file)|could not find pasta' "$log"; then
    warn "Rootless networking helper missing. Install it: sudo dnf install passt slirp4netns"
    warn "(Debian/Ubuntu: sudo apt install passt slirp4netns)"
  elif grep -qi 'aardvark' "$log"; then
    warn "Podman has no DNS for its networks, so the nodes can't find each other."
    warn "Install it: sudo dnf install aardvark-dns   (Debian/Ubuntu: sudo apt install aardvark-dns)"
  elif grep -qiE 'address already in use|port is already allocated' "$log"; then
    warn "A port the cluster needs is taken. See what holds it: ss -ltnp | grep -E ':(8080|6443) '"
    warn "Change hostPort in platform/kind-config.yaml if it's 8080 (and use that port in the lessons)."
  elif grep -qi 'too many open files' "$log"; then
    warn "inotify/file limits are too low. Raise them (needs sudo):"
    warn "  printf 'fs.inotify.max_user_watches=524288\\nfs.inotify.max_user_instances=512\\n' | sudo tee /etc/sysctl.d/99-kind.conf && sudo sysctl --system"
  elif grep -qi 'no space left on device' "$log"; then
    warn "Out of disk space where images are stored (rootless: your HOME, which may have a quota)."
    warn "Free some with: $CTR system prune"
  elif grep -qi 'toomanyrequests' "$log"; then
    warn "Docker Hub's anonymous pull limit is used up for your IP. Wait, or '$CTR login docker.io' with a free account."
  elif grep -qiE 'x509|certificate signed by unknown authority' "$log"; then
    warn "A TLS-inspecting company proxy is in the way. See 'Corporate proxy' in lessons/00-setup/README.md."
  elif grep -qiE '/dev/fuse' "$log"; then
    warn "/dev/fuse is missing: sudo modprobe fuse"
  elif grep -qiE 'Failed to connect to bus|No medium found' "$log"; then
    warn "No systemd user session (you came in via su/sudo?). Log in directly as yourself and retry."
  else
    warn "Not a failure this script recognises. Work through lessons/00-setup/rootless.md, or get the node"
    warn "logs with:  kind create cluster --retain --config platform/kind-config.yaml ; kind export logs"
  fi
}

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

step "Creating kind cluster '$CLUSTER_NAME' (first time takes 1-3 minutes)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists - reusing it."
  # After a reboot, nodes may be stopped: Docker restarts them itself, Podman never does.
  STOPPED=()
  for node in "$CLUSTER_NAME-control-plane" "$CLUSTER_NAME-worker" "$CLUSTER_NAME-worker2"; do
    state=$("$CTR" inspect -f '{{.State.Running}}' "$node" 2>/dev/null || true)
    [ "$state" = "false" ] && STOPPED+=("$node")
  done
  if [ ${#STOPPED[@]} -gt 0 ]; then
    echo "Nodes are stopped (after a reboot or logout?) - starting: ${STOPPED[*]}"
    "$CTR" start "${STOPPED[@]}" >/dev/null || die "Could not start the nodes. Recreate the cluster: ./scripts/cluster-down.sh && ./scripts/cluster-up.sh"
  fi
  # Rewrites the kubeconfig entry too, in case it was lost or the API port changed.
  kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null 2>&1 || kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
  echo "Waiting for the API server..."
  ready=false
  for _ in $(seq 1 60); do
    if kubectl get --raw /readyz >/dev/null 2>&1; then ready=true; break; fi
    sleep 2
  done
  $ready || die "The existing cluster doesn't answer. Recreate it: ./scripts/cluster-down.sh && ./scripts/cluster-up.sh"
else
  HOST_PORT=$(awk '/hostPort:/ { print $2; exit }' "$KIND_CONFIG")
  if [ -n "$HOST_PORT" ] && port_in_use "$HOST_PORT"; then
    die "Port $HOST_PORT on this machine is already in use, and the cluster's front door needs it.
       See what holds it:  ss -ltnp | grep ':$HOST_PORT '   (Windows: netstat -ano | findstr :$HOST_PORT)
       - An earlier cluster made with sudo or another engine?  sudo kind get clusters / podman ps / docker ps
       - Something else? Change hostPort in platform/kind-config.yaml and use that port in the lessons."
  fi

  CREATE=(kind create cluster --config "$KIND_CONFIG")
  # Rootless Podman: kind's docs say some distros (RHEL among them) need kind started in its
  # own systemd scope with cgroup delegation, or it fails with 'requires setting systemd
  # property "Delegate=yes"'. https://kind.sigs.k8s.io/docs/user/rootless/
  if $IS_PODMAN && engine_is_rootless && command -v systemd-run >/dev/null 2>&1; then
    # Probe first: without a systemd user session systemd-run itself fails, before kind even starts.
    if systemd-run --scope --user -p "Delegate=yes" true >/dev/null 2>&1; then
      echo "Rootless Podman detected: starting kind in its own systemd scope (Delegate=yes)."
      CREATE=(systemd-run --scope --user -p "Delegate=yes" "${CREATE[@]}")
    else
      warn "Can't reach your systemd user session (logged in via su/sudo?), so kind runs without its own scope."
      warn "If it fails with a 'Delegate=yes' error: log in directly as yourself and run this script again."
    fi
  fi
  LOG=$(mktemp)
  if ! "${CREATE[@]}" 2>&1 | tee "$LOG"; then
    echo
    explain_failure "$LOG"
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    rm -f "$LOG"
    die "kind could not create the cluster (full output above)."
  fi
  rm -f "$LOG"
fi
kubectl wait --for=condition=Ready nodes --all --timeout=300s \
  || die "Nodes are not Ready after 5 minutes. Look at: kubectl get nodes; kubectl -n kube-system get pods
       Slow machine or slow image pulls? Run this script again - it continues where it stopped."

# Podman caps the processes in a container (pids_limit, 2048 by default). A kind node is one
# container holding every Pod on that node, so the default is too low once lessons scale things up.
if $IS_PODMAN; then
  PIDS=$("$CTR" inspect -f '{{.HostConfig.PidsLimit}}' "$CLUSTER_NAME-control-plane" 2>/dev/null || true)
  if [ -n "$PIDS" ] && [ "$PIDS" -gt 0 ] 2>/dev/null && [ "$PIDS" -lt 16384 ] 2>/dev/null; then
    warn "Podman limits each node to $PIDS processes. Lessons that scale up (13, capstone) can hit that:"
    warn "Pods then fail with 'fork/exec ... resource temporarily unavailable'. To raise it:"
    warn "  mkdir -p ~/.config/containers"
    warn "  printf '[containers]\\npids_limit = 65536\\n' >> ~/.config/containers/containers.conf"
    warn "  ./scripts/cluster-down.sh && ./scripts/cluster-up.sh     (the limit is fixed when a node is created)"
  fi
fi

RERUN="Run this script again - it is safe to re-run and continues where it stopped."

step "Installing Gateway API CRDs"
kubectl apply --server-side --force-conflicts -f "$ROOT/platform/gateway-api-crds.yaml" >/dev/null
kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null

step "Installing Traefik (the cluster's front door on http://localhost:8080)"
kubectl apply -f "$ROOT/platform/traefik.yaml"
kubectl -n traefik rollout status deploy/traefik --timeout=300s \
  || die "Traefik isn't ready. Usually a slow or blocked image pull: kubectl -n traefik describe pods
       (ImagePullBackOff? See the proxy and rate-limit rows in lessons/00-setup/README.md.) $RERUN"

step "Installing metrics-server (for 'kubectl top' and autoscaling)"
kubectl apply -f "$ROOT/platform/metrics-server.yaml" >/dev/null
if ! kubectl -n kube-system rollout status deploy/metrics-server --timeout=120s; then
  warn "metrics-server is not ready yet. Only lessons 09 and 13 need it; check later with:"
  warn "  kubectl -n kube-system get pods -l k8s-app=metrics-server"
fi

step "Done"
kubectl get nodes
echo
echo "Cluster is ready. kubectl context: kind-$CLUSTER_NAME"
if engine_is_rootless 2>/dev/null && [ ! -e "/var/lib/systemd/linger/$(id -un)" ] && [ -d /run/systemd/system ]; then
  echo "Rootless reminder: the cluster stops when you log out, unless you run: loginctl enable-linger"
fi
if $IS_PODMAN; then
  echo "Podman doesn't restart nodes after a reboot. Run this script again to bring the cluster back."
fi
echo "Delete it any time with: ./scripts/cluster-down.sh"
