# Lesson 00: Set up your machine

**Time:** 30-60 minutes (mostly downloads) · **You will end with:** a working 3-node Kubernetes cluster running on your laptop.

## What you are installing and why

| Tool | What it is | Why you need it |
|---|---|---|
| **Docker** | Runs containers | kind runs each Kubernetes "node" as a Docker container |
| **kind** | "Kubernetes IN Docker" | Creates a real, certified Kubernetes cluster on your laptop in about a minute |
| **kubectl** | The Kubernetes command-line tool | How you talk to *any* Kubernetes cluster: local, AWS EKS, Azure AKS, Google GKE |
| **Helm** | Kubernetes package manager | Used from lesson 11 onward |
| **Git** | Version control | To clone this repo |

> **Why kind and not minikube / Docker Desktop's built-in Kubernetes?** kind behaves the same on
> Windows, Linux and macOS, gives you multiple nodes (needed to see scheduling, failover and
> spreading), starts in about a minute, and is what many teams use in CI pipelines. Everything you
> learn transfers directly to cloud clusters: only the cluster creation step changes.

**Hardware:** 8 GB RAM minimum (16 GB is comfortable), about 10 GB free disk space. The cluster itself uses around 2-3 GB of RAM.

---

## Windows (10 22H2+ or 11)

Open **PowerShell as Administrator** for the installs.

### 1. WSL2 (Docker Desktop needs it)

```powershell
wsl --install
```

Reboot if it asks you to. If WSL is already installed, `wsl --update` brings it up to date.

### 2. Install the tools with winget

```powershell
winget install -e --id Docker.DockerDesktop
winget install -e --id Kubernetes.kubectl
winget install -e --id Kubernetes.kind
winget install -e --id Helm.Helm
winget install -e --id Git.Git
winget install -e --id Microsoft.PowerShell   # PowerShell 7, strongly recommended
```

Then:

1. **Close and reopen your terminal** so the new tools are on your `PATH`.
2. Start **Docker Desktop** from the Start menu and wait until it says "Engine running".
3. In Docker Desktop → Settings → General, make sure **"Use the WSL 2 based engine"** is ticked.
4. Docker Desktop has its own "Enable Kubernetes" option. **Leave it off.** We use kind instead.

> **Use PowerShell 7 (`pwsh`), not the old "Windows PowerShell" 5.1.** The course works with both,
> but PowerShell 5.1 mangles double quotes inside arguments passed to programs like `kubectl`. That
> causes confusing errors with JSON. In Windows Terminal, pick "PowerShell" (black icon), not
> "Windows PowerShell" (blue icon).

### 3. Allow the course scripts to run

Windows blocks downloaded `.ps1` scripts by default. Run this once in your normal (non-admin) terminal:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

If your company's group policy blocks that, run each script like this instead:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\cluster-up.ps1
```

---

## Linux (Ubuntu/Debian shown; Fedora/Arch are similar)

### 1. Docker Engine

Use Docker's official convenience script, or follow your distro's guide at <https://docs.docker.com/engine/install/>:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
```

**Log out and back in** (or reboot) so the `docker` group membership applies. Check it with:

```bash
docker run --rm hello-world
```

### 2. kubectl, kind, Helm

```bash
# kubectl (latest stable)
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# kind v0.33.0
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
sudo install -m 0755 kind /usr/local/bin/kind && rm kind

# Helm (official installer script)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash
```

On ARM machines (Raspberry Pi, Graviton, etc.) replace `amd64` with `arm64`.

**Optional but useful:** enable kubectl tab completion:

```bash
echo 'source <(kubectl completion bash)' >> ~/.bashrc   # or: kubectl completion zsh
```

---

## macOS (bonus: works the same)

```bash
brew install --cask docker   # or Rancher Desktop / OrbStack / Colima
brew install kubectl kind helm
```

---

## Check everything

Run the checker from the root of this repo:

**bash:**
```bash
./scripts/check-prereqs.sh
```

**PowerShell:**
```powershell
.\scripts\check-prereqs.ps1
```

You should see a ✔ next to each tool. Any version of kubectl within one minor version of the
cluster (1.36-1.38 for the default kind v0.33 cluster, which runs Kubernetes 1.37) is fine.

Besides the tools, the checker inspects **how Docker is set up**, because that's where most
"kind create cluster failed" problems come from:

| Check | Why it matters |
|---|---|
| **cgroup v2** | Kubernetes 1.37 refuses to start on cgroup v1 hosts. Old Linux distros, or an outdated WSL, can still be on v1 |
| **Rootless Docker** | kind supports it, but only with extra host settings (below). Some corporate Linux machines run Docker rootless |
| **Podman posing as `docker`** | kind must be told to use Podman explicitly |

Every problem it finds comes with the exact command to fix it. `cluster-up` runs the same checks
first and stops with that advice, instead of failing halfway through with a kind stack trace.

## Create the cluster

**bash:**
```bash
./scripts/cluster-up.sh
```

**PowerShell:**
```powershell
.\scripts\cluster-up.ps1
```

This creates the cluster from [`platform/kind-config.yaml`](../../platform/kind-config.yaml) and
installs three platform pieces you will use later (Gateway API, Traefik, metrics-server). Expect
output ending with:

```
NAME                    STATUS   ROLES           AGE   VERSION
lessons-control-plane   Ready    control-plane   1m    v1.37.0
lessons-worker          Ready    <none>          1m    v1.37.0
lessons-worker2         Ready    <none>          1m    v1.37.0
```

**You now have a Kubernetes cluster.** Each "node" is a Docker container. Run `docker ps` and you
will see `lessons-control-plane`, `lessons-worker` and `lessons-worker2`.

To delete it (e.g. to free RAM, or to start fresh if you break something):

```bash
./scripts/cluster-down.sh        # bash
.\scripts\cluster-down.ps1       # PowerShell
```

Deleting and recreating is cheap. **When in doubt, recreate the cluster.** That's one of the
habits Kubernetes teaches: treat infrastructure as disposable.

---

## Things that go wrong at work (and fixes)

These are real issues people hit on corporate laptops:

| Symptom | Likely cause | Fix |
|---|---|---|
| `x509: certificate signed by unknown authority` when pulling images | Corporate TLS-inspecting proxy (Zscaler, Netskope, etc.) | Docker Desktop picks up the Windows certificate store automatically. For the kind nodes, ask IT for the root CA `.crt` and see "Corporate proxy" below |
| `kind create cluster` hangs or nodes stay `NotReady` | VPN client hijacking Docker's network range | Try off VPN once to confirm, then ask IT about split tunnelling for `172.16.0.0/12` |
| `port is already allocated` on 8080 | Something else uses port 8080 | Change `hostPort: 8080` in `platform/kind-config.yaml` to e.g. `8081` and use that port wherever lessons say `8080` |
| `toomanyrequests: You have reached your unauthenticated pull rate limit` | Docker Hub limits anonymous pulls per IP, and an office shares one IP | Wait (the limit resets within hours), `docker login` with a free Docker Hub account for pulls on your machine, or ask whether your company has a registry mirror. Pods show this as `ImagePullBackOff` |
| `kind create cluster` fails with an error mentioning **rootless** | Docker runs in rootless mode without the host settings kind needs | Run `check-prereqs`: it says exactly what's missing. Details in "Rootless Docker" below |
| `running kind with rootless provider requires cgroup v2` | Rootless Docker/Podman on a cgroup v1 host (typically RHEL 8) | See "Red Hat (RHEL) machines with Podman" below |
| kubelet fails with `cgroup v1 support is unsupported` | The host (or WSL) uses cgroup v1 | `check-prereqs` shows the fix: enable cgroup v2 on Linux, or `wsl --update` on Windows |
| `Cannot connect to the Docker daemon` | Docker Desktop not started / Linux user not in `docker` group | Start Docker Desktop / log out and back in |
| Script says `running scripts is disabled on this system` | PowerShell execution policy | See "Allow the course scripts to run" above |
| `\r: command not found` running a `.sh` file | File got Windows line endings | This repo's `.gitattributes` prevents this; re-clone, or run `git config core.autocrlf input` and re-checkout |

**Docker Desktop licensing:** Docker Desktop is free for personal use, education and small
companies. Larger companies (more than 250 employees *or* more than $10M annual revenue) need a
paid Docker subscription. If your company doesn't have one, **Rancher Desktop** (free, open source)
works with this course: install it, choose the "dockerd (moby)" container engine in its settings,
and disable its built-in Kubernetes.

### Rootless Docker

In rootless mode the Docker daemon runs as *your* user instead of root. It's more secure, and
kind supports it, but the host needs three things. `./scripts/check-prereqs.sh` checks all
three and prints the fix for whichever is missing:

1. **cgroup v2.** `docker info` shows `Cgroup Version: 2`.
2. **cgroup delegation** lets your user's services manage CPU and memory limits. It's on by
   default with systemd 252 or newer (`systemctl --version`). On older systemd:
   ```bash
   sudo mkdir -p /etc/systemd/system/user@.service.d/
   printf '[Service]\nDelegate=yes\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
   sudo systemctl daemon-reload
   systemctl --user restart docker
   ```
3. **iptables kernel modules.** Without them, Services and the Traefik gateway don't route traffic:
   ```bash
   printf 'ip6_tables\nip6table_nat\nip_tables\niptable_nat\n' | sudo tee /etc/modules-load.d/iptables.conf
   sudo systemctl restart systemd-modules-load.service
   ```

Then re-run `./scripts/check-prereqs.sh` and `./scripts/cluster-up.sh`.

**On your own machine, normal ("rootful") Docker is simpler.** To switch back from rootless:
`dockerd-rootless-setuptool.sh uninstall`, install Docker as in step 1 above, then
`docker context use default`. On a work machine where rootless is the policy, use the steps above
rather than fighting it. Source: [kind's rootless guide](https://kind.sigs.k8s.io/docs/user/rootless/).

### Red Hat (RHEL) machines with Podman

RHEL ships **Podman** instead of Docker, often with a `docker` command that's really Podman
(`docker --version` prints `podman version ...`). It runs **rootless** by default. kind can use it:

- `cluster-up` and the capstone `build` script set `KIND_EXPERIMENTAL_PROVIDER=podman` for you
  when they detect Podman. Set it yourself (`export KIND_EXPERIMENTAL_PROVIDER=podman`) if you run `kind` by hand.
- **RHEL 8 (and Rocky/Alma/CentOS 8) default to cgroup v1**, and kind refuses rootless mode on
  cgroup v1 (`running kind with rootless provider requires cgroup v2`). RHEL 9 and later use v2.
  Switching RHEL 8 to v2 needs a kernel boot setting and a reboot:
  ```bash
  sudo grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"
  sudo reboot
  ```
  Afterwards, run `./scripts/check-prereqs.sh` again. RHEL 8's systemd is older than 252, so you'll
  most likely also need the **delegation** step from the rootless section above (the checker tells you).
- **On a company-managed machine, ask before changing boot settings.** It affects other software
  on the machine, and IT may manage those settings centrally. If that's not possible, practical
  alternatives are: a machine with Docker Desktop (Windows/macOS), a RHEL 9+ or Ubuntu VM, or a
  small cloud VM.

The course is tested with Docker. kind's Podman support is labelled *experimental* by kind itself,
so if something behaves differently under Podman, tell whoever maintains this repo.

### Corporate proxy: trusting a custom root CA inside kind nodes

If image pulls fail inside the cluster with `x509` errors but `docker pull` works on your machine,
mount your company's root CA into the nodes. Save it as `platform/corp-ca.crt`, then add this under
**each** node in `platform/kind-config.yaml`:

```yaml
    extraMounts:
      # Use the FULL path to the file. On Windows use forward slashes, e.g.
      # C:/Users/you/kubernetes-lessons/platform/corp-ca.crt
      - hostPath: /home/you/kubernetes-lessons/platform/corp-ca.crt
        containerPath: /usr/local/share/ca-certificates/corp-ca.crt
        readOnly: true
```

Then recreate the cluster, and run this once per node (`lessons-control-plane`, `lessons-worker`, `lessons-worker2`):

```bash
docker exec lessons-control-plane sh -c "update-ca-certificates && systemctl restart containerd"
```

---

## Recommended editor setup

[VS Code](https://code.visualstudio.com/) with:

- **YAML** (Red Hat): autocomplete and validation for Kubernetes YAML. This catches most typos before you apply.
- **Kubernetes** (Microsoft): browse your cluster in a side panel.

---

**Next:** [Lesson 01: What Kubernetes actually is](../01-concepts/README.md)
