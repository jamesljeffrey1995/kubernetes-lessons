# Rootful mode: root's container engine, through sudo

Read this if you're on Linux at work, rootless Podman (or rootless Docker) keeps failing, and
you have `sudo`. In rootful mode the container engine runs as **root**, and the kind nodes are
root's containers. You stay yourself: `kubectl`, `helm` and every lesson command run without
`sudo`. The course scripts call `sudo` themselves, and only for the engine and `kind`.

You switch it on with one variable, `ENGINE_SUDO=1`. Don't put `sudo` in front of the scripts
instead. The next section explains why that breaks.

## First: should you?

**Ask before you do this on a company machine.** It has real security consequences:

- kind runs every node as a **privileged** container. Rootless, "privileged" still means only
  your own user's rights. Rootful, it means root's. Anything that breaks out of a node, or a Pod
  with `hostPath` or `privileged: true`, is root on your laptop.
- Anyone who can run root's Podman can do anything as root. Here that's just you, through `sudo`,
  but it's still a root-level tool running on a managed machine.
- Endpoint security software may flag privileged root containers. If your company's rule is
  "rootless containers only", this is exactly what the rule is meant to stop.

If the answer is no, the alternatives are in [rootless.md](rootless.md): fix rootless with IT's
help, or ask for a small VM (4 CPUs, 8 GB RAM).

**What rootful fixes.** These rows of the [rootless catalogue](rootless.md#the-catalogue) no
longer apply:

| Rootless problem | Row |
|---|---|
| No sub-UIDs (LDAP / Active Directory accounts) | 4 |
| Home directory on NFS, quota, `noexec`, `vfs` storage driver | 5-8 |
| cgroup delegation, `Delegate=yes`, the reboot it needs | 13-15 |
| No systemd user session (`su`, `sudo -i`) | 16 |
| Podman's log relay (`could not find a log line`, cause a) | 17a |
| `/dev/fuse`, `slirp4netns`, `pasta` | 18, 19 |
| iptables kernel modules not loaded | 26 |
| Your user's process limit (`ulimit -u`) | 28 |
| The cluster stops when you log out (lingering) | 33 |

**What it doesn't fix:**

- **cgroup v1** (RHEL 8's default). Kubernetes 1.37 needs cgroup v2 either way.
- **Probably not RHEL 8's realtime problem** ([row 15b](rootless.md#rhel-8)). If the kernel
  refuses the `cpu` controller at the top of the cgroup tree, root's containers don't get it
  either. `check-prereqs` warns when it sees this. This course hasn't been able to test it.
- Company proxy, custom CA, Docker Hub rate limits, port 8080 already in use. Those are the same
  in both modes.

## Why plain `sudo` doesn't work

`sudo ./scripts/cluster-up.sh` creates a cluster, but here's what goes wrong. The `ENGINE_SUDO=1`
column shows what the scripts do instead:

| Problem with plain `sudo` | What you see | What `ENGINE_SUDO=1` does |
|---|---|---|
| kind writes the kubeconfig to **root's** home (`/root/.kube/config`) | `kubectl get nodes` as yourself: `connection refused` on `localhost:8080`, or the wrong cluster | Copies the `kind-lessons` entry into **your** kubeconfig and leaves your other clusters alone. kubectl works as you: the API server listens on `127.0.0.1`, which every user can reach |
| On RHEL, sudo's `secure_path` is `/sbin:/bin:/usr/sbin:/usr/bin`, without `/usr/local/bin` | `sudo: kind: command not found` | Calls `kind` and `podman` by full path |
| sudo resets the environment | kind falls back to Docker (no `KIND_EXPERIMENTAL_PROVIDER`), and image pulls inside the nodes lose your proxy settings | Passes `KIND_EXPERIMENTAL_PROVIDER`, `HTTP(S)_PROXY` and `NO_PROXY` through explicitly |
| Some sudo setups keep your `HOME` | Root writes **your** `~/.kube/config` and leaves it owned by root. Every later `kubectl` fails with `permission denied` | Uses `sudo -H`, so root gets its own `HOME` |
| Every script run as root | `helm` and `kubectl` also run as root, with root's config | Only the engine and kind run as root |

The scripts also run `sudo -v` once at the start, so the password prompt comes first and not
halfway through the output.

## Set it up

### 0. Clear up earlier attempts

A half-made rootless cluster holds port 8080. Delete it as yourself, *without* `ENGINE_SUDO`:

```bash
ENGINE_SUDO=0 ./scripts/cluster-down.sh
```

If you ever ran the scripts with plain `sudo`, also delete that cluster and give `~/.kube` back
to yourself:

```bash
sudo env KIND_EXPERIMENTAL_PROVIDER=podman "$(command -v kind)" delete cluster --name lessons
sudo chown -R "$USER" ~/.kube
```

### 1. Check what you're allowed to do

```bash
sudo -v && sudo -l
```

You need permission to run **any** command as root (`(ALL) ALL` or similar in `sudo -l`). The
scripts run `sudo -H env ... /usr/local/bin/kind` and `sudo -H env ... /usr/bin/podman`. If your
sudo rules only allow a fixed list of commands, this mode won't work. Show IT that list of
commands, or go with the VM.

Also check that the machine is on cgroup v2. This must print `cgroup2fs`:

```bash
stat -fc %T /sys/fs/cgroup
```

### 2. Turn it on, permanently

```bash
cat >> ~/.bashrc <<'EOF'
export ENGINE_SUDO=1                       # course scripts: use root's engine through sudo
export KIND_EXPERIMENTAL_PROVIDER=podman   # kind: use Podman, not Docker
EOF
source ~/.bashrc
```

### 3. Two host settings (once, as root)

Both are optional for the first lessons, but lessons 13 and the capstone need them:

```bash
# A 3-node cluster needs more inotify handles than most distros allow by default.
printf 'fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512\n' \
  | sudo tee /etc/sysctl.d/99-kind.conf
sudo sysctl --system

# Podman caps each container at 2048 processes. One kind node holds every Pod on it, so raise it.
# (Podman only. Docker has no default limit.)
sudo mkdir -p /etc/containers/containers.conf.d
printf '[containers]\npids_limit = 65536\n' \
  | sudo tee /etc/containers/containers.conf.d/90-kind.conf
```

### 4. Check, then create the cluster

```bash
./scripts/check-prereqs.sh
./scripts/cluster-up.sh
```

Run both **as yourself**. They ask for your sudo password once. `check-prereqs` should show:

```
  ✔ sudo      ENGINE_SUDO=1: podman and kind will run as root through sudo; kubectl and helm as you
  ...
  ✔ rootful   root's podman, used through sudo (ENGINE_SUDO=1)
```

`cluster-up` prints `ENGINE_SUDO=1: podman and kind run as root ...` at the start, and
`Copying the cluster's entry from root's kubeconfig into yours` after kind finishes.

### 5. Confirm it

```bash
kubectl get nodes          # no sudo: three Ready nodes
sudo podman ps             # the nodes are root's containers
podman ps                  # your own Podman: the nodes are NOT here, and that's correct
```

## Day to day: what needs `sudo`

| What | `sudo`? |
|---|---|
| `kubectl`, `helm`, and everything else in the lessons | **No** |
| `./scripts/*.sh` and `./capstone/scripts/*.sh` | **No.** They use `sudo` themselves when `ENGINE_SUDO=1` is set |
| A lesson's `docker ps`, `docker exec lessons-control-plane ...`, `docker stop lessons-worker2` | **Yes:** `sudo podman ps`, `sudo podman exec ...`, `sudo podman stop ...` |
| Building an image for the cluster by hand | **Yes:** `sudo podman build ...` (see "Two image stores") |
| Lesson 01's `docker run ... nginx` | Either. It doesn't involve the cluster. If rootless `podman run` fails for you, use `sudo podman run` |
| `kind` by hand (rarely needed) | **Yes**, with the full path. See below |

For `kind` commands you type yourself, add this to `~/.bashrc` and use `skind` instead of `kind`:

```bash
skind() { sudo -H env KIND_EXPERIMENTAL_PROVIDER=podman "$(command -v kind)" "$@"; }
```

```bash
skind get clusters               # lessons
skind export logs ./kind-logs --name lessons
```

Don't run `skind export kubeconfig`: it writes root's kubeconfig, not yours. To get the
cluster's kubeconfig entry back, run `./scripts/cluster-up.sh`. It reuses the existing cluster and
copies the entry again.

### Two image stores

Your Podman and root's Podman are separate. Each has its own images: yours in
`~/.local/share/containers`, root's in `/var/lib/containers`. An image you built with plain
`podman build` doesn't exist for root's Podman, so `kind load` can't find it.
`capstone/scripts/build.sh` builds with root's Podman when `ENGINE_SUDO=1` is set. If you build by
hand, use `sudo podman build` and `skind load image-archive`.

That also means root's images use space on `/var`, not in your home directory. On a work machine
with a home quota, that helps.

### After a reboot

Podman doesn't restart containers by itself, rootful or rootless, so the nodes are stopped after
a reboot. Run `./scripts/cluster-up.sh` again: it starts them and updates your kubeconfig.
Logging out doesn't stop root's containers, so lingering doesn't matter in this mode.

## When something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `sudo: kind: command not found` | You typed `sudo kind`. `/usr/local/bin` isn't on sudo's `secure_path` | Use `skind` (above), or the full path: `sudo "$(command -v kind)" ...` |
| `kubectl`: `connection refused` on `localhost:8080`, or it talks to the wrong cluster | Your kubeconfig has no `kind-lessons` entry, for example because the cluster was made with plain `sudo` | `./scripts/cluster-up.sh` with `ENGINE_SUDO=1` set. It reuses the cluster and copies the entry |
| `kubectl`: `permission denied` on `~/.kube/config` | An earlier plain `sudo` run left it owned by root | `sudo chown -R "$USER" ~/.kube`. `check-prereqs` reports this as `✘ kubecfg` |
| `ENGINE_SUDO=1 needs sudo, and sudo was refused` | No sudo rights, or only for specific commands | Check with `sudo -l`. Talk to IT, or use a VM |
| `sudo: a terminal is required to read the password` | A script started from something with no terminal (an IDE task, a git hook) | Run it from a terminal, or run `sudo -v` in that terminal first. sudo remembers the password for a few minutes |
| `Port 8080 ... is already in use` | A rootless `lessons` cluster still exists in your own Podman | `ENGINE_SUDO=0 ./scripts/cluster-down.sh` |
| Pulls inside the cluster fail (`proxyconnect`, timeouts), but worked rootless | You set the proxy for your own Podman in `~/.config/containers/`. Root's Podman doesn't read that file | Export `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` in `~/.bashrc`. The scripts pass them on |
| `x509: certificate signed by unknown authority` | Company TLS-inspecting proxy | "Corporate proxy" in the [setup lesson](README.md). Replace `docker exec` there with `sudo podman exec` |
| `capstone/scripts/build.sh`: `permission denied` reading files in `app/` | Home directory on NFS with `root_squash`: root counts as "nobody" there and can't read your files | Clone the repo to a local disk, for example `/var/tmp/$USER/kubernetes-lessons` |
| Pods fail with `fork/exec ... resource temporarily unavailable` | Podman's `pids_limit` | Step 3, then `./scripts/cluster-down.sh && ./scripts/cluster-up.sh` (the limit is set when a node is created) |
| `check-prereqs`: `! cpu ... realtime processes` | The RHEL 8 kernel restriction described above | See "RHEL 8" in [rootless.md](rootless.md) for what to ask IT |

## Docker Engine instead of Podman

`ENGINE_SUDO=1` works the same way with a rootful Docker Engine that you aren't allowed to use
directly (you aren't in the `docker` group). Set `KIND_EXPERIMENTAL_PROVIDER=docker` or leave it
unset, and type `sudo docker ...` wherever a lesson says `docker ...`. Being in the `docker`
group is equivalent to having root, so the security points at the top apply there as well.

## Going back to rootless

```bash
./scripts/cluster-down.sh            # with ENGINE_SUDO=1 still set: deletes root's cluster AND your kubeconfig entry
sed -i '/ENGINE_SUDO=1/d' ~/.bashrc
unset ENGINE_SUDO
```

If nothing else on the machine uses root's Podman, you can free its disk space with
`sudo podman system prune -a`. This deletes **every** unused image in root's store, not only the
course's.

## How this is tested

CI runs a job called "root's Podman through sudo" on Ubuntu 24.04. It removes Docker, sets sudo's
`secure_path` the way RHEL does, and then, as an ordinary user with `ENGINE_SUDO=1`, creates the
cluster, runs the host-sensitive lessons and the capstone, simulates a reboot and deletes the
cluster again. `tests/engine-sudo-test.sh` checks the sudo wrapper and the kubeconfig merge on
their own. None of this runs on real RHEL, so RHEL-specific surprises are possible. If you hit
one, `check-prereqs` output and the failing command's output are what to look at first.

---

**Back to:** [Lesson 00: Set up your machine](README.md) · [Rootless mode](rootless.md)
