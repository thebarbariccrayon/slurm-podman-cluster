# Slurm Podman Cluster

Maintained by David Lewellyn.

A complete [Slurm](https://slurm.schedmd.com/) installation in containers: scheduler, compute nodes, accounting, REST API, an SSH login node, LDAP users and the Slurm-web dashboard, all on one laptop or workstation. Use it to learn Slurm, try configuration changes, or demonstrate multi-site scheduling, without touching a real cluster. Slurm's own [documentation](https://slurm.schedmd.com/documentation.html) and [quick start guide](https://slurm.schedmd.com/quickstart.html) cover the commands used below.

|               |                |
|---------------|----------------|
| **Tested on** | macOS (rootless Podman 6.1, Apple Silicon), Ubuntu 20.04.6 (Docker) |
| **Source**    | [github.com/SchedMD/slurm](https://github.com/SchedMD/slurm) |
| **Releases**  | [download.schedmd.com/slurm](https://download.schedmd.com/slurm/) |


## Project Structure

The project structure looks like this:

    slurm-podman-cluster/
    ├── Dockerfile
    ├── entrypoint.sh
    ├── slurm.conf
    ├── slurm-dc2.conf      # second cluster for the federation demo
    ├── slurmdbd.conf
    ├── docker-compose.yml
    ├── Makefile
    ├── .env.example        # optional site settings (LDAP, passwords)
    ├── ldap/Dockerfile     # OpenLDAP demo directory image
    └── scripts/
        ├── install_deps.sh # host dependencies for macOS, RHEL, Debian, Arch
        ├── install_deps.ps1 # Windows: sets up WSL2, then runs install_deps.sh
        ├── federation_demo.sh # make fed-demo
        └── smoke_test.sh

Containers started by `make up`:

- `slurm-controller`: the scheduler (`slurmctld`)
- `compute1`–`compute5`: compute nodes (`slurmd`), 4 CPUs and 1 GiB each
- `slurmdbd` and `mariadb`: job accounting and its database
- `slurmrestd`: Slurm's HTTP/JSON API on `localhost:6820`
- 1 SSH login node (`login`) for submitting jobs as the local user `hpcuser` or any LDAP user
- 1 OpenLDAP directory (`ldap`) with a local admin and demo users, resolved on every Slurm node; `directory-sync` turns its groups into Slurm accounts
- [Slurm-web](https://github.com/rackslab/Slurm-web) dashboard: agent, gateway, Redis cache and Prometheus metrics

Every Slurm container mounts the `shared-data` volume at `/shared`. It holds the users' home directories, so a job's files are visible on whichever node runs it, much like a cluster's network filesystem.


## How It Is Put Together

### Fixed Addresses

Slurm daemons find each other by hostname, and a node that comes back with a different address can be marked down or lose its jobs. The containers therefore have fixed addresses on the `slurm-net` network (`172.30.0.0/16`): data center 1 uses `172.30.0.x` and the optional second cluster uses `172.30.1.x`. Container hostnames match the node names in `slurm.conf`.

### Configless Compute Nodes

The compute nodes have no `slurm.conf` of their own. `slurmd` starts with `--conf-server` pointing at its controller, which has `SlurmctldParameters=enable_configless` and sends `slurm.conf` and `cgroup.conf` at startup (see Slurm's [configless guide](https://slurm.schedmd.com/configless_slurm.html)). To change the cluster, edit `slurm.conf` and run `make up`: the controller installs the new file and the nodes fetch it as they start.

### `slurmrestd` Capabilities

`slurmrestd` runs as an unprivileged user (`restuser`), because it refuses to run as root or as `SlurmUser`. Its container adds the `SYS_ADMIN` and `IPC_LOCK` capabilities and runs without a seccomp profile so the daemon can start under rootless Podman. It is published on `127.0.0.1:6820` only, and every request needs a Slurm JWT.


## Getting Started

### Prerequisites

- Podman (default) or Docker, with Docker Compose v2.23 or newer as the `podman compose` provider (the stack uses inline `configs:` content). The Makefile uses Podman; run `make <target> ENGINE=docker` for Docker.
- `make`, `git` (the Slurm-web images build from a tagged git URL), an OpenSSH client, `curl` and `python3` (for the smoke test).
- No registry login is needed: the Slurm image is built locally and is never pulled.

- The repo can live anywhere (including an external volume the Podman machine doesn't share): nothing is bind-mounted from the host.

Install all of these with:

    make deps          # same as: ./scripts/install_deps.sh  (add -y to skip package-manager prompts)

The script supports macOS (Homebrew), RHEL/Fedora/Rocky/Alma (dnf), Debian/Ubuntu (apt) and Arch Linux (pacman); for Windows see [Windows (WSL2)](#windows-wsl2). On macOS it also creates and starts a Podman machine (size it with `PODMAN_MACHINE_CPUS`, `PODMAN_MACHINE_MEMORY` and `PODMAN_MACHINE_DISK`; defaults 4 CPUs, 8192 MiB, 100 GiB). On Linux it uses `sudo` for packages and sets up rootless Podman: subordinate UID/GID ranges, the user's `podman.socket` (which docker-compose talks to), and delegation of the `cpu cpuset io memory pids` cgroup controllers so Slurm can enforce job limits; log in again afterwards if it says so. Where the distribution has no Compose v2 package (RHEL, Debian 12, Ubuntu 22.04) it downloads the official release binary and verifies its checksum. Podman older than 4.7 (Debian 12, Ubuntu 22.04) has no `podman compose`; the script prints how to run `make up COMPOSE=docker-compose` against the Podman socket instead.

### Windows (WSL2)

On Windows the cluster runs inside a WSL2 Linux distribution, where the Makefile and scripts work unchanged. From PowerShell in the repo:

    powershell -ExecutionPolicy Bypass -File scripts\install_deps.ps1     # add -Yes to skip prompts, -Distro <name> to pick a distribution

It installs WSL2 if needed (run it from an Administrator prompt the first time, then reboot and run it again), forces cgroup v2 with `kernelCommandLine = cgroup_no_v1=all` in `%UserProfile%\.wslconfig` (applying this runs `wsl --shutdown`, which stops every WSL distribution, including Docker Desktop's), and installs `Ubuntu-24.04` if it's missing. Create your Linux user when asked. It then enables systemd and Linux file permissions on Windows drives in `/etc/wsl.conf`, so the SSH private key can be `0600`, and runs `scripts/install_deps.sh` inside the distribution. Afterwards:

    wsl -d Ubuntu-24.04 --cd C:\path\to\slurm-podman-cluster
    make up && make test

Ports are forwarded to Windows' `localhost`, so http://localhost:5011 and `ssh -p 2222 hpcuser@localhost` work from Windows too. `.gitattributes` keeps LF line endings, so a Windows git checkout doesn't break the scripts or the image entrypoint. Builds run faster when the repo is in the distribution's own filesystem (e.g. `~/slurm-podman-cluster`) instead of under `/mnt/c`.

### Authentication

Slurm daemons and commands prove who they are with [MUNGE](https://dun.github.io/munge/) credentials, which only validate between hosts holding the same secret key.

The key is generated automatically: on first start the one-shot `secrets-init` service writes a random key into the `munge-key` volume, which every Slurm container mounts at `/etc/munge`. It also creates the Slurm JWT signing key (shared by `slurmctld`, `slurmdbd` and the Slurm-web agent) and the home directory of `hpcuser` on the shared volume. It is reused on later starts and removed only by `make clean` (`podman compose down -v`).

### Build and Launch

Build the image and start all the containers (the first build compiles Slurm and takes several minutes):

    make up            # same as: podman compose up -d --build

To build a different Slurm release, pass `SLURM_VERSION` (any version listed at [download.schedmd.com/slurm](https://download.schedmd.com/slurm/)):

    make up SLURM_VERSION=24.11.7

`slurm.conf` and `slurmdbd.conf` are copied into the image and installed with the ownership and permissions Slurm requires when each container starts. After editing them, run `make up` again (it rebuilds; only the last layers change).

Other targets: `make down`, `make clean` (also deletes volumes), `make logs`, `make shell` (root on the controller), `make ssh`, `make web`, `make test`, `make sync-users` (after changing the directory).

### Two Data Centers (Federation)

    make up FEDERATION=1
    make fed-demo

This adds a second cluster, `homelab-dc2` (controller and 3 compute nodes, standing in for another data center), and federates it with the first as `homelab`. Both clusters share the accounting database and the LDAP directory, so every LDAP user can run jobs in both. A job submitted to a partition that both clusters have (`debug`, `batch`, `all`) runs on whichever cluster can start it first; `gpu` exists only in the first cluster. `make fed-demo` shows this happening. Run `make down` before switching between the federated and single-cluster setups. See [Federation](./docs/federation.md).

### Login Node (SSH)

The `login` container runs `sshd` on `localhost:2222`. The local user `hpcuser` can log in two ways:

- **Key pair:** `make up` creates a project key in `.ssh/cluster_ed25519` (gitignored) and authorises it. To use your own key instead, run `make up SSH_KEY=~/.ssh/id_ed25519`.
- **Password:** defaults to `hpcuser`. Override it with `SSH_PASSWORD=... make up`, or set `SSH_PASSWORD=` (empty) to lock hpcuser's password.

LDAP users log in with their directory password, for example `alice` / `demo`. See [LDAP Users and Login](./docs/ldap-auth.md) for the demo users and their groups.

```
make ssh                                  # hpcuser, key login
ssh -p 2222 hpcuser@localhost             # hpcuser, password login
ssh -p 2222 alice@localhost               # LDAP user (password: demo)
```

From the login node, submit jobs as usual. Every user exists on every node with the same UID, and home directories (`/shared/home/<user>`) are shared, so job output is visible everywhere:

```
sbatch --wrap "hostname; sleep 30"
squeue
srun -p all -N5 hostname
```

The port is published on `127.0.0.1` only. Change it with `SSH_PORT`.

### Slurm-web Dashboard

Open http://localhost:5011 (`make web`); `127.0.0.1` or any other host that reaches the port works too. Signing in is mandatory and there is no anonymous access. Users log in with their LDAP account and see only their own jobs; the local admin (`admin` / `admin`) sees everything. By default the in-stack demo directory is used; to use an existing LDAP or Active Directory server instead, copy `.env.example` to `.env` and fill in the `LDAP_*` settings. See [LDAP Users and Login](./docs/ldap-auth.md). The agent signs its own short-lived tokens for `slurmrestd` with the shared Slurm JWT key, caches responses in Redis, and Prometheus (http://localhost:9090) scrapes the agent for the dashboard charts.

Upstream only publishes amd64 images, so the agent and gateway are built from the tagged Slurm-web source (`SLURMWEB_VERSION`, default `7.0.0`). The first build takes several minutes. Their configuration is inline in `docker-compose.yml` under `configs:`.

### Smoke Test

    make test

This checks that all 5 compute nodes are idle, that jobs run on every partition inside a Slurm cgroup, that memory limits are enforced, that accounting records jobs, that `slurmrestd` responds, that SSH key and password logins work and can submit jobs, that the LDAP user `alice` resolves on every node and can log in over SSH and run jobs, that Slurm-web refuses anonymous access, and that alice can sign in to Slurm-web and read cluster stats and job history. Use another account with `LDAP_TEST_USER=... LDAP_TEST_PASSWORD=... make test`.

### cgroups on Podman and cgroup v2

Compute nodes run `privileged` in a private cgroup namespace and `cgroup.conf` sets `IgnoreSystemd=yes`, so `task/cgroup` and `proctrack/cgroup` work on cgroup v2 hosts without bind-mounting the host's `/sys/fs/cgroup`. Each node declares `RealMemory=1024` and the scheduler tracks memory (`CR_Core_Memory`), so `--mem` requests are honoured and enforced.

Rootless Podman on macOS only delegates the `cpu io memory pids` controllers to containers, not `cpuset`. Memory limits work, but CPU pinning (`ConstrainCores` in `cgroup.conf`) does not, and `slurmd` logs `Controller cpuset is not enabled!`. To enable it, add `cpuset` to the machine's delegation and restart the machine. This stops every running Podman container:

    podman machine ssh "printf '[Service]\nDelegate=memory pids cpu cpuset io\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf"
    podman machine stop && podman machine start

All published ports (MariaDB 3307, REST 6820, SSH 2222, LDAP 3389, Slurm-web 5011, Prometheus 9090) are bound to `127.0.0.1` only.

### Check the Cluster

Open a root shell on the controller and list the partitions:

    make shell        # or: podman exec -it slurm-controller bash
    sinfo

    PARTITION AVAIL  TIMELIMIT  NODES  STATE  NODELIST
    debug*       up  1:00:00      2    idle   compute[1-2]
    batch        up  1-00:00:00   2    idle   compute[3-4]
    gpu          up  2-00:00:00   1    idle   compute5
    all          up  infinite     5    idle   compute[1-5]

| Partition | Nodes | Time limit | Intended for |
|---|---|---|---|
| `debug` (default, marked `*`) | compute1–2 | 1 hour | quick tests; jobs without `-p` land here |
| `batch` | compute3–4 | 1 day | longer batch jobs |
| `gpu` | compute5 | 2 days | stand-in for a GPU node (it has no GPU) |
| `all` | compute1–5 | none | jobs that need the whole cluster |

`sinfo`, `squeue` and the other commands work in every Slurm container; they ask the controller on port 6817.


## Documentation

| Topic                                        | Description |
|----------------------------------------------|-------------|
| [LDAP Users and Login](./docs/ldap-auth.md)  | Demo users and groups, adding users, dashboard roles, using a site LDAP or Active Directory |
| [Federation](./docs/federation.md)           | Two clusters in two "data centers" sharing jobs through a Slurm federation |
| [Federating a Live Cluster](./docs/federation-live.md) | Runbook: bring up a new cluster next to a production one and federate them |


## License

[MIT](./LICENSE), Copyright (c) 2026 David Lewellyn.
