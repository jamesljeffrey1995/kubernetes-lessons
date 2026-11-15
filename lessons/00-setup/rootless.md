# Rootless Docker and Podman: everything that can go wrong

Read this if `check-prereqs` says your containers run in **ROOTLESS mode**, or you're on Red Hat
(RHEL, Rocky, Alma, Fedora), where Podman is rootless by default.

## First: do you need rootless at all?

Rootless mode is the hardest way to run this course. kind supports it, but kind labels its Podman
support *experimental*, and rootless needs about ten host settings that ordinary Docker doesn't.
Each one is a separate way to fail. Pick the easiest option you're actually allowed to use:

| Your situation | Easiest route |
|---|---|
| Your own Linux machine | Ordinary ("rootful") Docker Engine. None of this page applies |
| Windows or macOS | Docker Desktop, Rancher Desktop, or Podman Desktop with a **rootful** machine (`podman machine set --rootful`) |
| Work machine, you can get a VM or cloud instance | A small Ubuntu 22.04+/RHEL 9+ VM with rootful Docker (4 CPU, 8 GB) |
| Work machine, RHEL 9 / Fedora, rootless Podman required | Works. Follow "The short path" below |
| Work machine, **RHEL 8**, rootless Podman required | The hard case. Read "RHEL 8" at the bottom before spending time on it |

## How rootless differs, in four sentences

Normally the container engine runs as root. In rootless mode it runs as *you*, so everything a
Kubernetes node needs from the kernel (resource limits, networking, mounting filesystems, many
user IDs) has to be something an ordinary user is allowed to do. The kernel allows it only if an
admin has switched on the right settings beforehand. A kind "node" is a container that runs
systemd, containerd and all your Pods inside it, so it needs every one of those settings at once.

## The short path

```bash
./scripts/check-prereqs.sh      # run it, fix every ✘ it prints, repeat until none are left
./scripts/cluster-up.sh         # recognises the common kind errors and prints the fix
```

The scripts need no `docker` command: with only `podman` installed they use it directly and set
`KIND_EXPERIMENTAL_PROVIDER=podman`. **Never run them with `sudo`** (see row 2).

When you run `kind` by hand with Podman, always set the provider and, on RHEL, use a systemd scope:

```bash
export KIND_EXPERIMENTAL_PROVIDER=podman
systemd-run --scope --user -p "Delegate=yes" kind create cluster --config platform/kind-config.yaml
```

## The catalogue

**Caught by** says how you find out: `✘` and `!` are `check-prereqs` results (fail / warning),
*hint* means `cluster-up` recognises the error and prints the fix, *docs* means only this page
knows. **Source** says how sure this is: *kind* = kind's documentation or source code, *vendor* =
Docker/Podman/Red Hat/systemd documentation, *reported* = commonly reported but not reproduced
while writing this course.

### A. Before any container runs

| # | Symptom | Cause | Fix | Caught by | Source |
|---|---|---|---|---|---|
| 1 | `docker: command not found` | RHEL ships Podman only | Nothing: the scripts use `podman`. Where a lesson says `docker`, type `podman` (or `sudo dnf install podman-docker`) | handled | kind |
| 2 | Cluster "disappears", `kubectl` shows nothing, or permission errors in `~/.kube` | A script was run with `sudo`: the cluster lives in root's Podman, the kubeconfig in `/root` | `sudo kind delete cluster --name lessons`, `sudo chown -R "$USER" ~/.kube`, then run as yourself | ✘ sudo | kind |
| 3 | `cannot clone: Invalid argument`, `user namespaces are not enabled` | `user.max_user_namespaces=0`, a common security-hardening (CIS/STIG) setting | Admin: `echo 'user.max_user_namespaces=28633' \| sudo tee /etc/sysctl.d/99-userns.conf && sudo sysctl --system` | ✘ engine | vendor |
| 4 | `newuidmap: not found`, or `potentially insufficient UIDs or GIDs available in user namespace ... lchown: invalid argument` while pulling the node image | No sub-UID range for your account. **Normal for LDAP / Active Directory accounts**, which `useradd` never touched | Add a range to `/etc/subuid` and `/etc/subgid` (commands in the `✘ subuid` output), then `podman system migrate` | ✘ subuid, hint | vendor |
| 5 | Pulls fail with `lchown ... operation not permitted`, or storage errors mentioning NFS | Home directory on NFS/CIFS/GPFS. Rootless image storage can't live on a network filesystem | Point `graphroot` in `~/.config/containers/storage.conf` at a local disk, then `podman system reset` | ✘ storage | vendor |
| 6 | Everything is extremely slow, disk fills up | Storage driver `vfs` (no overlay support): every layer is a full copy | Install `fuse-overlayfs`, then `podman system reset` | ! storage | vendor |
| 7 | `no space left on device` | Images live in your home directory, which often has a quota | `podman system prune`, or move `graphroot` (row 5) | ! storage, hint | reported |
| 8 | `permission denied` when containers start, storage is fine | `/home` mounted `noexec` (hardening) | Move `graphroot` to a filesystem without `noexec` | ! storage | reported |
| 9 | Docker: `permission denied ... /var/run/docker.sock` although rootless Docker is installed | Your shell talks to the system Docker socket, not your rootless one | `export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock` | ✘ daemon | vendor |
| 10 | Ubuntu 24.04+: rootless Docker won't start, `permission denied` creating a user namespace | AppArmor restricts unprivileged user namespaces | Add the AppArmor profile for `rootlesskit` from Docker's rootless troubleshooting page | ✘ daemon | vendor |
| 11 | Rootless checks fail oddly on WSL2 | The distro doesn't run systemd | `/etc/wsl.conf`: `[boot]` `systemd=true`, then `wsl --shutdown` | ✘ systemd | vendor |

### B. `kind create cluster` fails

| # | kind's error contains | Cause | Fix | Caught by | Source |
|---|---|---|---|---|---|
| 12 | `rootless provider requires cgroup v2` | Host on cgroup v1 (RHEL 8 default) | Boot with `systemd.unified_cgroup_hierarchy=1` (commands in the `✘ cgroup` output). Needs a reboot, and IT's blessing on a managed machine | ✘ cgroup, hint | kind |
| 13 | `requires setting systemd property "Delegate=yes"` | The `cpu`, `memory` or `pids` controller isn't delegated to your user (systemd older than 252) | Create `delegate.conf` (commands in the `✘ delegate` output), then **reboot or log out of every session** | ✘ delegate, hint | kind |
| 14 | Same error, although `delegate.conf` exists | Your user's systemd instance is still the old one. It only restarts when your *last* session ends: an open SSH session, VS Code remote or `tmux` keeps it alive | Reboot. Check with `cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers` (must list `cpu memory pids`) | ✘ delegate | vendor |
| 15 | Same error, although the file above lists the controllers | kind was started from a login session, whose own cgroup doesn't have them | Start kind with `systemd-run --scope --user -p "Delegate=yes" ...`. `cluster-up` does this | handled | kind |
| 16 | `Failed to connect to bus: No medium found` | No systemd user session: you became this user with `su` or `sudo -u` | Log in directly (new SSH/desktop login). `cluster-up` restores `XDG_RUNTIME_DIR` when it can and otherwise runs kind without a scope | ! session, hint | vendor |
| 17 | `could not find a log line that matches "Reached target .*Multi-User System.*"` | (a) Rootless Podman's log relay misses the boot message, or (b) the node really failed to boot, most often because inotify limits are too low for three nodes | (a) `log_driver = "k8s-file"` under `[containers]` in `~/.config/containers/containers.conf`; (b) raise `fs.inotify.max_user_instances` to 512 and `max_user_watches` to 524288 | hint, · inotify | kind |
| 18 | `/dev/fuse: no such file or directory` | kind gives every rootless node `/dev/fuse`; the `fuse` module isn't loaded | `sudo modprobe fuse` | ✘ fuse, hint | kind |
| 19 | `slirp4netns` or `pasta` ... `not found` | Rootless networking helper not installed | `sudo dnf install passt slirp4netns` | hint | vendor |
| 20 | Workers never join; warnings about `aardvark-dns` | Podman has no DNS for its networks, so nodes can't find the control plane by name | `sudo dnf install aardvark-dns` | hint | reported |
| 21 | `address already in use` / port 8080 | Something uses 8080. Often an older cluster created with `sudo` or with the other engine | `ss -ltnp \| grep :8080`; delete the old cluster, or change `hostPort` in `platform/kind-config.yaml` | checked before create | kind |
| 22 | `toomanyrequests` | Docker Hub rate limit, shared by everyone behind the office IP | Wait, or `podman login docker.io` | hint | vendor |
| 23 | `x509: certificate signed by unknown authority` | TLS-inspecting corporate proxy | "Corporate proxy" in the [setup lesson](README.md) | hint | kind |
| 24 | Image pulls inside the nodes fail: `proxyconnect tcp: dial tcp 127.0.0.1:3128: connection refused` | `HTTPS_PROXY` points at a proxy on `localhost` (cntlm, px). kind copies the variable into the nodes, where localhost is the node | Make the local proxy listen on your LAN address and use that in `HTTPS_PROXY` | ! proxy | kind |
| 25 | `kubectl`: `Unable to connect to the server: Forbidden` or a proxy error page | Proxy set, but `NO_PROXY` lacks `localhost,127.0.0.1`, so kubectl asks the proxy for your local cluster | `export NO_PROXY="localhost,127.0.0.1,.localhost,$NO_PROXY"` | ! proxy | reported |

### C. The cluster is up, but something's off

| # | Symptom | Cause | Fix | Caught by | Source |
|---|---|---|---|---|---|
| 26 | Services and `http://localhost:8080` don't answer; kube-proxy logs iptables errors | A rootless container can't load kernel modules, so `ip_tables`, `ip6_tables`, `iptable_nat`, `ip6table_nat` must be loaded on the host already | `/etc/modules-load.d/iptables.conf` (commands in the `✘ iptables` output) | ✘ iptables | kind |
| 27 | Pods fail with `fork/exec ... resource temporarily unavailable` when a lesson scales up | Podman's `pids_limit` (2048 by default) applies to a whole node, which holds every Pod on it | `pids_limit = 65536` under `[containers]` in `containers.conf`, then recreate the cluster | warning after create | kind |
| 28 | Same error, `pids_limit` is fine | Your user's process limit (`ulimit -u`). Every process in every Pod runs under your user ID | Admin raises `nproc` in `/etc/security/limits.d/` | ! nproc | reported |
| 29 | Pods report `too many open files` | inotify limits (row 17b) | Raise them | · inotify, hint | kind |
| 30 | `ErrImageNeverPull` / `ImagePullBackOff` for `pulse:v1` in the capstone | `kind load docker-image` always calls the `docker` binary, and Podman names local images `localhost/pulse`, which Kubernetes doesn't look for | Use `capstone/scripts/build.sh`: it builds `docker.io/library/pulse`, saves a tar and uses `kind load image-archive` | handled | kind |
| 31 | NetworkPolicy lesson: the "intruder" isn't blocked | Policy enforcement needs kernel features the rootless node may not be able to set up | No reliable fix. Carry on: the capstone demo prints a warning and continues, and `tests/lessons-test.sh` accepts `SKIP_NETPOL=1` | docs | reported |
| 32 | A lesson says `docker exec` / `docker ps` | Only Podman installed | Type `podman` instead; the arguments are the same | · docker | - |

### D. Later

| # | Symptom | Cause | Fix | Caught by | Source |
|---|---|---|---|---|---|
| 33 | Cluster gone after you log out or the SSH connection drops | systemd stops all of a user's processes when their last session ends | `loginctl enable-linger` (or `sudo loginctl enable-linger "$USER"`) | ! linger | vendor |
| 34 | After a reboot: `The connection to the server 127.0.0.1:... was refused` | Podman has no daemon, so nothing restarts the node containers. (Docker does restart them) | `./scripts/cluster-up.sh`: it starts stopped nodes. If the cluster doesn't recover, recreate it; that takes two minutes | handled | kind |
| 35 | `kind get clusters` shows nothing although `podman ps` shows the nodes | `KIND_EXPERIMENTAL_PROVIDER=podman` isn't set in this shell | `export KIND_EXPERIMENTAL_PROVIDER=podman` (put it in `~/.bashrc`) | ! podman | kind |

## RHEL 8

RHEL 8 stacks four separate problems, and it's worth knowing that before you start:

1. **cgroup v1 by default.** Kubernetes 1.37 needs v2. Switching is a kernel boot parameter and a
   reboot, and it changes behaviour for everything else on the machine. Ask IT first.
2. **systemd 239** doesn't delegate controllers to users by default (that came with 252), so you
   need `delegate.conf` and a full logout. It also can't delegate `cpuset` in older minor
   releases. That one is fine: kind only requires `cpu`, `memory` and `pids`, and the checker
   only fails on those three.
3. **Kernel 4.18.** Kubernetes documents kernel 5.8 as the minimum for cgroup v2. Red Hat
   backports a great deal, so it may work, but nobody tests current Kubernetes on it, and this
   course doesn't either. `check-prereqs` warns rather than fails.
4. **Rootless Podman**, which kind calls experimental.

If the machine can't be changed or it still fails after the checker is green, stop fighting it.
The time is better spent on a VM: any hypervisor or cloud instance running RHEL 9, Rocky 9 or
Ubuntu 22.04+ with 4 CPUs and 8 GB runs this course without any of the above.

## Getting more information out of a failure

```bash
export KIND_EXPERIMENTAL_PROVIDER=podman          # if you use Podman
kind create cluster --retain --config platform/kind-config.yaml   # --retain keeps the failed nodes
kind export logs ./kind-logs --name lessons       # journal, kubelet and containerd logs per node
podman logs lessons-control-plane | tail -50      # the node's own boot output
kind delete cluster --name lessons                # clean up afterwards
```

In `kind-logs/lessons-control-plane/`, look at `journal.log` first (did systemd finish booting?)
and then `kubelet.log`.

Sources: [kind's rootless guide](https://kind.sigs.k8s.io/docs/user/rootless/),
[kind's known issues](https://kind.sigs.k8s.io/docs/user/known-issues/),
[Docker's rootless mode docs](https://docs.docker.com/engine/security/rootless/),
[Podman's troubleshooting guide](https://github.com/containers/podman/blob/main/troubleshooting.md).

---

**Back to:** [Lesson 00: Set up your machine](README.md)
