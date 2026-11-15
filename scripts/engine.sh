#!/usr/bin/env bash
# Sourced (not run) by the course's bash scripts. Works out which container engine to use and
# sets up the environment kind needs for it:
#
#   CTR        the command to run containers with: "docker" or "podman"
#   IS_PODMAN  true when that command is Podman - including a 'docker' command that is really
#              Podman's podman-docker shim, as on RHEL
#
# kind itself only looks at KIND_EXPERIMENTAL_PROVIDER (default: docker), so we follow the same
# rule, and fall back to Podman when there is no 'docker' command at all.
CTR=docker
case "${KIND_EXPERIMENTAL_PROVIDER:-}" in
  podman) CTR=podman ;;
  *) command -v docker >/dev/null 2>&1 || { command -v podman >/dev/null 2>&1 && CTR=podman; } ;;
esac
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
