# Runbook: Adding a Cluster to a Live Slurm Site

For a production cluster that is already configured and in use, with its own slurmdbd, users and accounts, when a second cluster (for example in another data center) is added and the two are federated. The examples use `prod` for the existing cluster, `newdc` for the new one and `site` for the federation. The demo in [federation.md](./federation.md) shows the end result. This page is for doing it on real systems.

## What changes on the live cluster

| | On `prod` |
|---|---|
| `slurm.conf`, `slurmdbd.conf` | No change required |
| Daemons | No restart; `slurmctld` and `slurmdbd` stay up |
| Running and queued jobs | Untouched; jobs already queued are not federated |
| Accounting database | New records only: the `newdc` cluster, its associations, the federation |
| Firewall | `prod`'s controller accepts `newdc`'s controller on 6817, and `prod`'s slurmdbd accepts it on 6819 |
| Users | New jobs get larger IDs and may run on `newdc` |

All the work is on the new cluster and in `sacctmgr`, and one command rolls it back (see [Back out or retire](#back-out-or-retire)).

## Before you start

What both clusters need:


| Requirement | Why |
|---|---|
| **One slurmdbd for both clusters.** `newdc` sets `AccountingStorageHost` to the existing slurmdbd. | The federation is stored in the accounting database, so its members must share it. |
| **Compatible versions.** slurmdbd must be the same release as the controllers or newer. Keep `newdc` on the same release as `prod`. | slurmdbd accepts older controllers but not newer ones. Mixed releases also complicate later upgrades. |
| **Same MUNGE key** on both clusters' controllers, nodes and submit hosts. | The controllers forward jobs to each other, and commands such as `squeue --federation` contact both. |
| **Same users** with the same UIDs and GIDs (the same LDAP or AD directory). | A job runs as the submitting UID wherever it lands. |
| **A unique `ClusterName`.** | It keys the cluster in accounting, and a running cluster cannot be renamed. |
| **Network.** Controllers reach each other on `SlurmctldPort` (6817). `newdc` reaches slurmdbd (6819). Submit hosts reach both controllers. For interactive jobs, submit hosts and the remote compute nodes reach each other on `SlurmdPort` and `SrunPortRange`. | Federated jobs are passed between controllers, and an interactive `srun` can be allocated on the other cluster. |
| **Data.** The job's working directory and input exist on `newdc` (shared or replicated filesystem, or staged). | A job can start on either cluster. |
| **Tooling.** Check job ID parsing. | Once federated, job IDs carry the origin cluster in bits 26–31, so they start at 67108865 (2²⁶ + 1) for cluster ID 1. Scripts that assume small IDs may break. |

## 0. Pre-flight on the live cluster

1. **Back up the accounting database** (on the database host):

       mysqldump --single-transaction slurm_acct_db > slurm_acct_db-$(date +%F).sql

2. **Record the current state** for the change ticket:

       sacctmgr show cluster
       sacctmgr show federation              # expected: empty
       scontrol show config | grep -E 'ClusterName|SLURM_VERSION|AccountingStorageEnforce|FederationParameters|MaxJobId'
       slurmdbd -V                           # on the slurmdbd host

   If `prod` already belongs to a federation, use `clusters+=` in step 4.

3. **Firewall:** open the ports listed under [Before you start](#before-you-start) in both directions between the two sites. Test them with `nc -zv <host> <port>` from the new controller.

4. **MUNGE:** copy `prod`'s key to `newdc`'s hosts. Never replace `prod`'s key to match the new cluster.

5. **Tell users** that new job IDs will be much larger (about 67 million and up). Status commands gain a `CLUSTER` column with `--federation`, and jobs may run in the other data center, so their data must be reachable there.

## 1. Build the new cluster standalone

In `newdc`'s `slurm.conf`, set its own `ClusterName` and `SlurmctldHost`, and point accounting at the shared slurmdbd:

    ClusterName=newdc
    AccountingStorageType=accounting_storage/slurmdbd
    AccountingStorageHost=<existing slurmdbd host>

Use the same partition names as `prod` for the work that should flow between sites. A job is only eligible on clusters that have its partition, so partition names decide what can move between sites. A partition only `prod` has, such as `gpu`, keeps those jobs local.

Start `slurmctld`. It registers itself with slurmdbd:

    sacctmgr show cluster          # newdc is listed

## 2. Copy accounts and users

Give `newdc` the same accounts, users, limits and QOS as `prod`:

    sacctmgr dump prod file=prod.cfg
    sacctmgr load file=prod.cfg cluster=newdc

`load` only adds what is missing ("Nothing new added" on a repeat). From now on, create accounts and users on both clusters, e.g. `sacctmgr add user alice account=physics cluster=prod,newdc`. If `AccountingStorageEnforce` includes `associations`, a user with no association on `newdc` has their copy of the job rejected there, and their jobs run only on `prod`.

## 3. Test it on its own

Before federating, run jobs directly on the new cluster from a `prod` submit host. This checks MUNGE, users, data and networking in one go:

    sbatch -M newdc -p batch --wrap 'id; hostname; pwd'
    srun -M newdc -p batch hostname

## 4. Federate

If there is no federation yet:

    sacctmgr add federation site clusters=prod,newdc

If `prod` is already in one:

    sacctmgr modify federation site set clusters+=newdc

The controllers pick this up from slurmdbd within seconds; no restart is needed. Check from each controller:

    scontrol show federation       # Self and Sibling lines, FedState:ACTIVE, Synced:Yes

Jobs submitted from now on are offered to both clusters and run on whichever starts them first. Jobs that were already queued stay on their own cluster.

## 5. Bring traffic over gradually (optional)

- **Hold the new cluster back.** Run `sacctmgr modify cluster newdc set fedstate=INACTIVE` right after joining, and `fedstate=ACTIVE` when ready. An inactive cluster accepts and schedules no jobs.
- **Opt in by feature.** Tag the clusters (`sacctmgr modify cluster newdc set features=newdc`) and let early users choose with `--cluster-constraint=newdc`. `-M newdc` targets the cluster directly.
- **Start sibling jobs promptly.** A cluster starts the copies it receives on its periodic scheduling passes (backfill 30 s and main scheduler 60 s by default). Shorter intervals, such as `SchedulerParameters=bf_interval=...,sched_interval=...`, make jobs move between sites faster.
- **Make the federated view the default** for `squeue`, `sinfo` and `sacct` with `FederationParameters=fed_display`, once users know what the `CLUSTER` column means.

## Back out or retire

| Goal | Command |
|---|---|
| Stop new federated jobs; let running ones finish | `sacctmgr modify cluster newdc set fedstate=DRAIN` |
| Same, then leave the federation automatically | `sacctmgr modify cluster newdc set fedstate=DRAIN+REMOVE` |
| Leave the federation now | `sacctmgr modify federation site set clusters-=newdc` |
| Resume | `sacctmgr modify cluster newdc set fedstate=ACTIVE` |

Leaving the federation does not touch `newdc`'s accounting data, and `prod` keeps running as a single cluster.

## Checklist

- [ ] `sacctmgr show cluster` lists both clusters with their controller addresses
- [ ] `sacctmgr show association where user=<someone>` shows them on both clusters
- [ ] `sbatch -M newdc` and `srun -M newdc` work from a `prod` submit host
- [ ] `scontrol show federation` on each controller: both `ACTIVE`, `Synced:Yes`
- [ ] A burst of jobs to a shared partition runs on both clusters (`sacct --federation -X -o JobID,Cluster,State`); `make fed-demo` does this in the demo setup
- [ ] Job ID consumers (scripts, dashboards, billing) handle the larger IDs
