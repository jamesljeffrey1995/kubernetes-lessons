#!/usr/bin/env bash
# Sourced (not run) by the course's bash scripts. Works out which container engine to use and
# sets up the environment kind needs for it:
#
#   CTR          the command to run containers with: "docker" or "podman"
#   IS_PODMAN    true when that command is Podman - including a 'docker' command that is really
#                Podman's podman-docker shim, as on RHEL
#   ENGINE_SUDO  "1" when the engine and kind run as root through sudo, while you (and kubectl,
#                helm) stay yourself. Opt-in: export ENGINE_SUDO=1. See lessons/00-setup/rootful.md
#
# kind itself only looks at KIND_EXPERIMENTAL_PROVIDER (default: docker), so we follow the same
# rule, and fall back to Podman when there is no 'docker' command at all.
CTR=docker
case "${KIND_EXPERIMENTAL_PROVIDER:-}" in
  podman) CTR=podman ;;
  *) command -v docker >/dev/null 2>&1 || { command -v podman >/dev/null 2>&1 && CTR=podman; } ;;
esac

# ---- ENGINE_SUDO=1: rootful engine, through sudo ---------------------------------------------
# Plain 'sudo kind ...' goes wrong in three ways on a typical work machine, so it isn't used:
#   - sudo's secure_path (RHEL: /sbin:/bin:/usr/sbin:/usr/bin) doesn't include /usr/local/bin,
#     so 'sudo kind' is "command not found". We call the full path instead.
#   - sudo drops the environment: KIND_EXPERIMENTAL_PROVIDER, and the proxy variables that kind
#     copies into the nodes for image pulls. We pass those through explicitly.
#   - with an old sudo that keeps HOME, root writes YOUR ~/.kube/config and leaves it owned by
#     root. -H gives root its own HOME; engine_kubeconfig_sync copies the entry over instead.
# The wrappers are shell functions named like the commands, so '"$CTR" build' and 'kind load'
# in the scripts go through sudo without each call site having to know.
# (ENGINE_UID exists only so tests/engine-sudo-test.sh can run as root.)
if [ "${ENGINE_SUDO:-}" = "1" ] && [ "${ENGINE_UID:-$(id -u)}" != "0" ]; then
  ENGINE_SUDO=1
  ENGINE_BIN=$(command -v "$CTR" 2>/dev/null || true)
  KIND_BIN=$(command -v kind 2>/dev/null || true)

  as_root() {
    local envs=() v
    for v in KIND_EXPERIMENTAL_PROVIDER HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
      [ -n "${!v:-}" ] && envs+=("$v=${!v}")
    done
    sudo -H env "${envs[@]}" "$@"
  }
  if [ -n "$ENGINE_BIN" ]; then
    case "$CTR" in
      podman) podman() { as_root "$ENGINE_BIN" "$@"; } ;;
      docker) docker() { as_root "$ENGINE_BIN" "$@"; } ;;
    esac
  fi
  if [ -n "$KIND_BIN" ]; then
    kind() { as_root "$KIND_BIN" "$@"; }
  fi

  # Ask for the password once, up front, rather than in the middle of the output.
  if ! sudo -v; then
    echo "ENGINE_SUDO=1 needs sudo, and sudo was refused. Check with: sudo -v" >&2
    exit 1
  fi
else
  ENGINE_SUDO=0
fi

IS_PODMAN=false
if grep -qi podman <<<"$("$CTR" --version 2>/dev/null)"; then
  IS_PODMAN=true
  export KIND_EXPERIMENTAL_PROVIDER=podman
fi

# Shells opened with 'su' or 'sudo -u' lose these two variables. Rootless engines and
# 'systemd-run --user' need them, so put them back when the user's runtime directory exists.
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
  XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export XDG_RUNTIME_DIR
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

# Docker installed as a snap can't read /tmp, where kind puts temporary files (a kind known issue).
case "$(command -v docker 2>/dev/null)" in
  /snap/*) if [ -z "${TMPDIR:-}" ]; then mkdir -p "$HOME/.cache/kind-tmp" && export TMPDIR="$HOME/.cache/kind-tmp"; fi ;;
esac

# True when the engine runs containers as your user instead of root.
engine_is_rootless() {
  if $IS_PODMAN; then
    [ "$("$CTR" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]
  else
    grep -q rootless <<<"$("$CTR" info --format '{{.SecurityOptions}}' 2>/dev/null)"
  fi
}

# Points kubectl at cluster <name>. Normally kind writes your kubeconfig itself. With ENGINE_SUDO,
# kind runs as root and writes ROOT's, so we fetch the entry and merge it into yours. kubectl can
# then run as you: the API server listens on 127.0.0.1, which every user on the machine can reach.
engine_kubeconfig_sync() {
  local name=$1
  if [ "$ENGINE_SUDO" != "1" ]; then
    kind export kubeconfig --name "$name" >/dev/null
    return
  fi
  local target=${KUBECONFIG:-$HOME/.kube/config}
  target=${target%%:*}
  local new merged
  new=$(mktemp) merged=$(mktemp)
  if ! kind get kubeconfig --name "$name" >"$new"; then
    rm -f "$new" "$merged"
    return 1
  fi
  mkdir -p "$(dirname "$target")"
  # The new file comes first, so its entries (with the current API port) win over stale ones.
  if KUBECONFIG="$new:$target" kubectl config view --flatten >"$merged"; then
    chmod 600 "$merged"
    mv "$merged" "$target"
  else
    rm -f "$new" "$merged"
    return 1
  fi
  rm -f "$new"
  KUBECONFIG="$target" kubectl config use-context "kind-$name" >/dev/null
}

# Removes cluster <name> from YOUR kubeconfig. With ENGINE_SUDO, 'kind delete' only cleans root's.
engine_kubeconfig_forget() {
  [ "$ENGINE_SUDO" = "1" ] || return 0
  local name="kind-$1"
  kubectl config delete-context "$name" >/dev/null 2>&1 || true
  kubectl config delete-cluster "$name" >/dev/null 2>&1 || true
  kubectl config delete-user "$name" >/dev/null 2>&1 || true
  if [ "$(kubectl config current-context 2>/dev/null)" = "$name" ]; then
    kubectl config unset current-context >/dev/null 2>&1 || true
  fi
}
