#!/bin/bash

# federation_demo.sh
#
# Shows federated scheduling across the two clusters started with
# `make up FEDERATION=1`. As an LDAP user on the login node of the first
# cluster, it submits more whole-node jobs to the common batch partition than
# one cluster can run at once, plus a job for the gpu partition, which only the
# first cluster has. It then shows where each job ran and exits non-zero unless
# the batch jobs used both clusters and the gpu job stayed on the first.

set -euo pipefail

ENGINE=${ENGINE:-podman}
DEMO_USER=${DEMO_USER:-alice}
JOBS=${JOBS:-6}
DURATION=${DURATION:-20}
FEDERATION_NAME=${FEDERATION_NAME:-homelab}
CLUSTER1=homelab-cluster
CLUSTER2=homelab-dc2

ctl() { "$ENGINE" exec slurm-controller "$@"; }
# Runs a shell command on the login node as the LDAP user.
as_user() { "$ENGINE" exec login su - "$DEMO_USER" -c "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
section() { printf '\n== %s\n' "$1"; }

"$ENGINE" inspect dc2-controller >/dev/null 2>&1 ||
  fail "the second cluster is not running; start it with: make up FEDERATION=1"

section "Federation $FEDERATION_NAME"
# sacctmgr may end single-column parsable output with a stray '|'.
members=$(ctl sacctmgr -n -P show federation "$FEDERATION_NAME" format=cluster | tr -d '|')
ctl sacctmgr show federation "$FEDERATION_NAME" format=federation,cluster,id,fedstate
{ grep -qx "$CLUSTER1" <<<"$members" && grep -qx "$CLUSTER2" <<<"$members"; } ||
  fail "federation $FEDERATION_NAME does not contain $CLUSTER1 and $CLUSTER2 (see: podman logs directory-sync)"

section "Partitions across both data centers"
ctl sinfo --federation -O "Cluster:18,Partition:10,Nodes:7,CPUs:6,StateCompact:8,NodeList:24"

section "LDAP user $DEMO_USER has associations on both clusters"
ctl sacctmgr -n -P show association where user="$DEMO_USER" format=cluster,account,user |
  awk -F'|' '{ printf "  %-17s account %-10s user %s\n", $1, $2, $3 }'

section "Submitting $JOBS whole-node jobs to batch (2 nodes in each cluster) and 1 gpu job"
ids=$(as_user "for i in \$(seq 1 $JOBS); do sbatch --parsable -p batch -c 4 --mem=256M -J fed-demo -o /dev/null --wrap 'sleep $DURATION'; done; \
               sbatch --parsable -p gpu -c 1 --mem=64M -J fed-gpu -o /dev/null --wrap 'sleep $DURATION'" | paste -sd, -)
echo "  job IDs: ${ids//,/ }"

# squeue filters by user and name, not job ID: with -j, squeue --federation
# reports the origin cluster's record, which never shows the job running
# elsewhere. Each cluster starts the sibling copies it receives on its next scheduling
# pass (every 5-10 s, see SchedulerParameters), so wait until both have.
for _ in $(seq 1 30); do
  running=$(ctl squeue --federation -h -u "$DEMO_USER" -n fed-demo -t R -O Cluster | sort -u | wc -l | tr -d ' ')
  [[ "$running" == 2 ]] && break
  sleep 2
done
section "Queue across the federation"
echo "CLUSTER is where the job runs (or its origin while pending); ACTIVE_SIBLINGS"
echo "are the clusters still holding a copy. The gpu job has none on homelab-dc2:"
echo "its copy there is rejected because that cluster has no gpu partition."
echo
squeue_fmt="JobID:12,Cluster:17,Partition:10,Name:10,StateCompact:4,NodeList:16,SiblingsActive:30"
ctl squeue --federation -u "$DEMO_USER" -n fed-demo,fed-gpu -O "$squeue_fmt"

echo
echo "Waiting for the jobs to finish..."
for _ in $(seq 1 $(( (JOBS * DURATION) / 2 + 60 ))); do
  left=$(ctl squeue --federation -h -u "$DEMO_USER" -n fed-demo,fed-gpu | wc -l | tr -d ' ')
  [[ "$left" == 0 ]] && break
  sleep 2
done
[[ "$left" == 0 ]] || fail "jobs still queued after the timeout"

section "Where the jobs ran (sacct --federation)"
ran=$(ctl sacct --federation -n -X -P -j "$ids" -o JobID,Cluster,Partition,JobName,State,NodeList)
ctl sacct --federation -X -j "$ids" -o JobID,Cluster%17,Partition,JobName,State,NodeList%16

section "Losing copies: once one cluster starts a job, the other copies are revoked"
ctl sacct --federation -D -X -j "$ids" -o JobID,Cluster%17,State,NodeList%16 |
  awk 'NR <= 2 || /REVOKED/'

batch_clusters=$(awk -F'|' '$3 == "batch" && $5 == "COMPLETED" { print $2 }' <<<"$ran" | sort -u | paste -sd' ' -)
gpu_clusters=$(awk -F'|' '$3 == "gpu" && $5 == "COMPLETED" { print $2 }' <<<"$ran" | sort -u)

echo
[[ "$batch_clusters" == "$CLUSTER1 $CLUSTER2" ]] ||
  fail "batch jobs did not run on both clusters (ran on: ${batch_clusters:-none})"
echo "ok   batch jobs ran in both data centers: $batch_clusters"
[[ "$gpu_clusters" == "$CLUSTER1" ]] || fail "gpu job ran on '${gpu_clusters:-nowhere}', expected $CLUSTER1"
echo "ok   gpu job ran only on $CLUSTER1, the only cluster with a gpu partition"
