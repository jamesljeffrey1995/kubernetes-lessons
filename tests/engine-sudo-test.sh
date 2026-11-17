#!/usr/bin/env bash
# Tests ENGINE_SUDO=1 in scripts/engine.sh with fake 'sudo', 'podman' and 'kind' commands:
#   - engine and kind calls go through sudo, with the FULL path (sudo's secure_path on RHEL
#     doesn't include /usr/local/bin) and -H (root must not write your ~/.kube)
#   - KIND_EXPERIMENTAL_PROVIDER and the proxy variables survive sudo's environment reset
#   - the cluster's kubeconfig entry ends up in YOUR kubeconfig, merged, mode 600 (needs kubectl)
#   - cluster-down removes it again
# For root, ENGINE_SUDO does nothing (there's nothing to sudo to), so the test pretends to be
# an ordinary user with ENGINE_UID.
# The snippets given to run() must expand in ITS shell, after engine.sh is sourced: hence single quotes.
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/roothome" "$WORK/home"
KUBECTL=$(command -v kubectl || true)

# Fake sudo: like the real one it resets the environment (PATH included) and, with -H, sets HOME
# to root's. Every call is logged, so the test can see exactly what was run.
cat > "$WORK/bin/sudo" <<FAKE
#!/bin/sh
echo "sudo \$*" >> "$WORK/sudo.log"
[ "\$1" = "-v" ] && exit 0
[ "\$1" = "-H" ] && shift
exec env -i PATH=/usr/bin:/bin HOME="$WORK/roothome" FAKE_AS_ROOT=1 "\$@"
FAKE
cat > "$WORK/bin/podman" <<'FAKE'
#!/bin/sh
case "$*" in
  --version) echo "podman version 5.4.0" ;;
  *) echo "podman $* as_root=${FAKE_AS_ROOT:-0}" ;;
esac
FAKE
cat > "$WORK/bin/kind" <<'FAKE'
#!/bin/sh
case "$*" in
  "get kubeconfig --name lessons")
    [ "${FAKE_AS_ROOT:-}" = 1 ] || { echo "not root: no such cluster" >&2; exit 1; }
    cat <<'YAML'
apiVersion: v1
kind: Config
clusters:
- cluster: {server: "https://127.0.0.1:41234"}
  name: kind-lessons
contexts:
- context: {cluster: kind-lessons, user: kind-lessons}
  name: kind-lessons
current-context: kind-lessons
users:
- name: kind-lessons
  user: {token: fake}
YAML
    ;;
  *) echo "kind $* as_root=${FAKE_AS_ROOT:-0} provider=${KIND_EXPERIMENTAL_PROVIDER:-} proxy=${HTTPS_PROXY:-} home=$HOME" ;;
esac
FAKE
chmod +x "$WORK/bin/"*

PASSED=0
check() {   # check <description> <command...>
  if "${@:2}"; then echo "ok   $1"; PASSED=$((PASSED + 1)); else echo "FAIL $1"; exit 1; fi
}

run() {     # run <bash code>: sources engine.sh with ENGINE_SUDO=1 in a clean environment
  env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" ENGINE_SUDO=1 ENGINE_UID=1000 \
    KIND_EXPERIMENTAL_PROVIDER=podman HTTPS_PROXY=http://proxy.corp:8080 NO_PROXY=localhost,127.0.0.1 \
    bash -c "set -euo pipefail; source '$ROOT/scripts/engine.sh'; $1"
}

out=$(run 'kind get clusters')
check "kind runs as root"                          grep -q "as_root=1" <<<"$out"
check "kind is called by its full path"            grep -q "sudo -H env .* $WORK/bin/kind get clusters" "$WORK/sudo.log"
check "KIND_EXPERIMENTAL_PROVIDER survives sudo"   grep -q "provider=podman" <<<"$out"
check "the proxy survives sudo"                    grep -q "proxy=http://proxy.corp:8080" <<<"$out"
check "root gets its own HOME (-H)"                grep -q "home=$WORK/roothome" <<<"$out"
check "the password is asked for up front"         grep -qx "sudo -v" "$WORK/sudo.log"

out=$(run '"$CTR" ps')
check "the engine runs as root"                    grep -q "podman ps as_root=1" <<<"$out"

out=$(run 'echo "$ENGINE_SUDO"')
check "ENGINE_SUDO is reported as on"              test "$out" = 1
out=$(env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" bash -c "source '$ROOT/scripts/engine.sh'; kind get clusters")
check "without ENGINE_SUDO nothing uses sudo"      grep -q "as_root=0" <<<"$out"

if [ -n "$KUBECTL" ]; then
  ln -s "$KUBECTL" "$WORK/bin/kubectl"
  # An existing kubeconfig with another cluster in it, which must survive the merge.
  mkdir -p "$WORK/home/.kube"
  cat > "$WORK/home/.kube/config" <<'YAML'
apiVersion: v1
kind: Config
clusters:
- cluster: {server: "https://work.example:6443"}
  name: work
contexts:
- context: {cluster: work, user: me}
  name: work
current-context: work
users:
- name: me
  user: {token: mine}
YAML
  run 'engine_kubeconfig_sync lessons'
  CFG="$WORK/home/.kube/config"
  check "the cluster is in YOUR kubeconfig"        grep -q "https://127.0.0.1:41234" "$CFG"
  check "your other clusters are kept"             grep -q "https://work.example:6443" "$CFG"
  check "the current context is kind-lessons"      test "$(KUBECONFIG=$CFG kubectl config current-context)" = kind-lessons
  check "your kubeconfig stays private (600)"      test "$(stat -c %a "$CFG")" = 600
  check "root's HOME was not used for yours"       test ! -e "$WORK/roothome/.kube/config"

  env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" ENGINE_SUDO=1 ENGINE_UID=1000 KIND_EXPERIMENTAL_PROVIDER=podman "$ROOT/scripts/cluster-down.sh" >/dev/null
  check "cluster-down removes the entry again"     bash -c "! grep -q kind-lessons '$CFG'"
  check "and keeps your other clusters"            grep -q "https://work.example:6443" "$CFG"
else
  echo "skip kubeconfig merge checks (no kubectl on PATH)"
fi

echo "PASS: $PASSED checks"
