# Federation: Two Data Centers

This setup runs two Slurm clusters side by side, as if they were in two data centers, and joins them in a [Slurm federation](https://slurm.schedmd.com/federation.html). Users submit jobs exactly as they would to one cluster. Each job is offered to every cluster that has the requested partition, and it runs on whichever cluster can start it first.

    make up FEDERATION=1     # both clusters, federated as "homelab"
    make fed-demo            # watch jobs spread across them

## Layout

| | Data center 1 | Data center 2 |
|---|---|---|
| Cluster name | `odin` | `freya` |
| Config | [slurm.conf](../slurm.conf) | [slurm-dc2.conf](../slurm-dc2.conf) |
| Controller | `slurm-controller` (172.30.0.2) | `dc2-controller` (172.30.1.2) |
| Compute nodes | `compute1`–`compute5` | `dc2-compute1`–`dc2-compute3` |
| `debug` | compute[1-2] | dc2-compute1 |
| `batch` | compute[3-4] | dc2-compute[2-3] |
| `gpu` | compute5 | — |
| `all` | compute[1-5] | dc2-compute[1-3] |
| slurmrestd | `slurmrestd` (localhost:6820) | `dc2-slurmrestd` (internal only) |
| Slurm-web agent | `slurm-web-agent` ("Odin") | `dc2-slurm-web-agent` ("Freya") |

Shared by both clusters:

- **slurmdbd and MariaDB.** A federation is defined in the accounting database, so its members must use the same slurmdbd. It also gives one job history: `sacct --federation`.
- **The munge key.** The controllers forward jobs to each other and must trust each other's credentials.
- **The LDAP directory.** Nodes in both clusters resolve users through `nslcd` with the same `LDAP_*` settings. `directory-sync` creates each LDAP group's Slurm account and its members' associations on both clusters, so every directory user can run jobs in either data center. One Slurm-web login shows both clusters.
- **`/shared`.** Home directories are on one volume, standing in for a filesystem replicated between the sites. A job's input and output are in the same place whichever cluster runs it.
- **One network (`172.30.0.0/16`).** Each data center has its own address block. Federation needs the controllers to reach each other, and interactive jobs need every compute node to be reachable from the submit host.

Without `FEDERATION=1`, none of the `dc2-*` services start, and `directory-sync` deletes the federation, so the first cluster runs on its own. Run `make down` before switching between the two setups. `make down` and `make clean` always include the second cluster.

## How a federated job runs

1. A user on the login node (data center 1) runs `sbatch -p batch job.sh`. Their own cluster is the job's **origin**.
2. The origin gives the job a federation-wide ID and sends a **sibling** copy to every member cluster. Bits 26 and up of the ID hold the origin cluster's ID, so jobs from `homelab-cluster` (ID 1) are numbered from 67108865 (2²⁶ + 1).
3. Each cluster schedules its copy independently. A cluster without the requested partition rejects its copy, so a `gpu` job only ever has a copy in data center 1.
4. When a cluster can start the job, it checks with the origin that no other cluster is starting it, starts it, and the other copies are **revoked**.

Clusters start sibling copies on their periodic scheduling passes. Both configs set `SchedulerParameters=bf_interval=5,sched_interval=10` (defaults 30 s and 60 s), so a job moves to the other data center within seconds rather than up to a minute.

## The demo

`make fed-demo` runs [scripts/federation_demo.sh](../scripts/federation_demo.sh). As LDAP user `alice` on the login node, it submits six jobs that each fill a whole node to `batch` (two nodes per cluster), plus one `gpu` job:

    JOBID       CLUSTER          PARTITION NAME      ST  NODELIST        ACTIVE_SIBLINGS
    67108889    odin  batch     fed-demo  PD                  odin,freya
    67108890    odin  batch     fed-demo  PD                  odin,freya
    67108887    freya      batch     fed-demo  R   -compute2    freya
    67108888    freya      batch     fed-demo  R   -compute3    freya
    67108885    odin  batch     fed-demo  R   compute3        odin
    67108886    odin  batch     fed-demo  R   compute4        odin
    67108891    odin  gpu       fed-gpu   R   compute5        odin

Four batch jobs run at once, two in each data center. The other two wait with copies on both clusters, and each goes to whichever cluster frees a node first. The script then shows where every job ran (`sacct --federation`) and the revoked copies (`sacct --federation -D`). It exits non-zero unless the batch jobs used both clusters and the gpu job stayed in data center 1. Change the load with `JOBS=10 DURATION=30 make fed-demo` and the user with `DEMO_USER=carol`.

## Commands

Run these on the login node (`make ssh`) or the controller (`make shell`).

| Task | Command |
|---|---|
| Federation members and state | `sacctmgr show federation` |
| Nodes and partitions of both clusters | `sinfo --federation -O "Cluster,Partition,Nodes,StateCompact,NodeList"` |
| Queue across both clusters | `squeue --federation -O "JobID,Cluster,Partition,StateCompact,NodeList,SiblingsActive"` |
| Job history across both clusters | `sacct --federation -X -o JobID,Cluster,Partition,State,NodeList` |
| Include revoked sibling copies | `sacct --federation -D ...` |
| Run only in data center 2 | `sbatch -M homelab-dc2 ...` |
| Offer to a subset of clusters | `sbatch --clusters=homelab-cluster,homelab-dc2 ...` |
| A user's associations on both clusters | `sacctmgr show association where user=alice format=cluster,account,user` |

`squeue --federation` reports a job running in the other data center only when you filter by user, name or partition. With `-j <id>` it shows the origin cluster's record instead. Interactive `srun` and `salloc` jobs are federated too. When data center 1's `batch` nodes are busy, `srun -p batch` on the login node runs on `dc2-compute2` and streams its output back.

To make the federated view the default for `squeue`, `sinfo` and `sacct`, add `FederationParameters=fed_display` to both slurm configs. It is left off so the single-cluster commands, and the smoke test, keep their usual output.

## Settings

| Variable | Default | Effect |
|---|---|---|
| `FEDERATION` | unset | `1` starts the second cluster and federates it (`make up FEDERATION=1`) |
| `FEDERATION_NAME` | `homelab` | Name of the federation in slurmdbd |

`make` sets `COMPOSE_PROFILES=federation` from `FEDERATION`. For plain `podman compose`, set both, on the command line or in `.env`:

    FEDERATION=1 COMPOSE_PROFILES=federation podman compose up -d

To do this on a real site, adding a new cluster next to one that is already in production, see [Federating a Live Cluster](./federation-live.md).

## Adding a third data center

1. Copy `slurm-dc2.conf` to `slurm-dc3.conf` with a new `ClusterName`, `ControlMachine` and nodes, and add it to the `COPY` line in the Dockerfile.
2. Copy the `dc2-*` services in `docker-compose.yml` with new names, addresses (e.g. `172.30.2.0/24`) and `SLURM_CONF_SOURCE` / `SLURM_CONF_SERVER`, plus a `dc3-slurmctld-state` volume.
3. Add the cluster name to `SLURM_CLUSTERS` in the `directory-sync` service. It creates the LDAP accounts on the new cluster and adds it to the federation on the next `make up`.
