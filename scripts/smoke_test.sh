#!/bin/bash

# smoke_test.sh
#
# Quick end-to-end check of a running cluster: all nodes registered, a job
# runs on every partition, jobs land in a Slurm cgroup with memory limits
# enforced, accounting records jobs, slurmrestd answers, the login node accepts
# SSH key and password logins and can submit jobs, LDAP users resolve on every
# node and can log in and run jobs, Slurm-web refuses anonymous access, and
# after an LDAP login it serves data. Exits non-zero on the first failure.

set -euo pipefail

ENGINE=${ENGINE:-podman}
SSH_KEY=${SSH_KEY:-.ssh/cluster_ed25519}
SSH_PORT=${SSH_PORT:-2222}
SSH_PASSWORD=${SSH_PASSWORD-hpcuser}
# Directory user for the LDAP checks (SSH, jobs, Slurm-web); defaults to a demo
# user of the in-stack directory. Set LDAP_TEST_USER= to skip them.
LDAP_TEST_USER=${LDAP_TEST_USER-alice}
LDAP_TEST_PASSWORD=${LDAP_TEST_PASSWORD-${DEMO_USER_PASSWORD:-demo}}
SLURMWEB_USER=${SLURMWEB_USER-$LDAP_TEST_USER}
SLURMWEB_PASSWORD=${SLURMWEB_PASSWORD-$LDAP_TEST_PASSWORD}

ctl() { "$ENGINE" exec slurm-controller "$@"; }
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; exit 1; }

echo "Waiting for 5 idle compute nodes..."
for _ in $(seq 1 60); do
  idle=$(ctl sinfo -h -N -p all -t idle -o '%N' | sort -u | wc -l | tr -d ' ')
  [[ "$idle" == "5" ]] && break
  sleep 2
done
if [[ "$idle" != "5" ]]; then
  ctl sinfo
  fail "only $idle nodes idle; the test needs a quiet cluster (cancel jobs with: scancel -u hpcuser)"
fi
pass "5 compute nodes idle"

for part in debug batch gpu all; do
  out=$(ctl srun -p "$part" -N1 hostname) || fail "srun on $part"
  pass "srun on $part -> $out"
done

cgroup=$(ctl srun -p debug -c1 cat /proc/self/cgroup) || fail "read job cgroup"
[[ "$cgroup" == *job_* ]] || fail "job not in a Slurm cgroup: $cgroup"
pass "job runs inside a Slurm cgroup ($cgroup)"

if ctl srun -p debug --mem=50M python3 -c 'bytearray(300 * 1024 * 1024)' >/dev/null 2>&1; then
  fail "job exceeded --mem=50M without being killed"
fi
pass "memory limit enforced (300MB under --mem=50M is OOM-killed)"

jobs=$(ctl sacct -n -X -o JobID) || fail "sacct"
[[ -n "$jobs" ]] || fail "sacct shows no jobs"
pass "accounting records jobs"

token=$(ctl scontrol token username=root | sed 's/^SLURM_JWT=//')
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-SLURM-USER-NAME: root" -H "X-SLURM-USER-TOKEN: $token" \
  http://localhost:6820/slurm/v0.0.42/ping)
[[ "$code" == "200" ]] || fail "slurmrestd ping returned HTTP $code"
pass "slurmrestd ping (HTTP $code)"

ssh_opts=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

who=$(ssh "${ssh_opts[@]}" -i "$SSH_KEY" -o BatchMode=yes -o PasswordAuthentication=no \
  hpcuser@localhost 'srun -p debug -N1 id -un') || fail "SSH key login + srun"
[[ "$who" == "hpcuser" ]] || fail "job from login node ran as '$who', expected hpcuser"
pass "SSH key login to login node, srun runs as hpcuser"

askpass=$(mktemp)
trap 'rm -f "$askpass"' EXIT
chmod 700 "$askpass"
# ssh_password USER PASSWORD COMMAND: run COMMAND on the login node with a
# password login.
ssh_password() {
  printf '#!/bin/sh\necho "%s"\n' "$2" >"$askpass"
  SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force ssh "${ssh_opts[@]}" \
    -o PubkeyAuthentication=no -o PreferredAuthentications=password "$1@localhost" "$3" </dev/null
}

if [[ -n "$SSH_PASSWORD" ]]; then
  jobid=$(ssh_password hpcuser "$SSH_PASSWORD" 'sbatch --parsable -p batch --wrap "sleep 1"') ||
    fail "SSH password login + sbatch"
  pass "SSH password login, sbatch submitted job $jobid"
fi

if [[ -n "$LDAP_TEST_USER" ]]; then
  for node in slurm-controller compute1 compute5 login slurmrestd; do
    "$ENGINE" exec "$node" id "$LDAP_TEST_USER" >/dev/null || fail "LDAP user $LDAP_TEST_USER unknown on $node"
  done
  pass "LDAP user $LDAP_TEST_USER resolves on controller, compute, login and slurmrestd"
  out=$(ssh_password "$LDAP_TEST_USER" "$LDAP_TEST_PASSWORD" 'srun -p debug -N1 sh -c "id -un; echo \$SLURM_JOB_ACCOUNT"') ||
    fail "SSH password login as LDAP user $LDAP_TEST_USER + srun"
  read -r who account <<<"$(echo $out)"
  [[ "$who" == "$LDAP_TEST_USER" ]] || fail "job ran as '$who', expected $LDAP_TEST_USER"
  pass "SSH login as LDAP user $LDAP_TEST_USER, srun runs as $who (account $account)"
fi

# Slurm-web requires an LDAP login. Check anonymous access is refused, then
# sign in as SLURMWEB_USER (the LDAP test user by default) and read data.
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5011/api/anonymous)
[[ "$code" == "401" ]] || fail "Slurm-web anonymous access returned HTTP $code, expected 401"
pass "Slurm-web refuses anonymous access (HTTP $code)"

if [[ -z "${SLURMWEB_USER:-}" || -z "${SLURMWEB_PASSWORD:-}" ]]; then
  echo "  skip Slurm-web data checks (no SLURMWEB_USER / SLURMWEB_PASSWORD)"
else
  web_auth=$(USER_NAME=$SLURMWEB_USER PASSWORD=$SLURMWEB_PASSWORD python3 -c \
    'import json,os; print(json.dumps({"user": os.environ["USER_NAME"], "password": os.environ["PASSWORD"]}))' |
    curl -sf -X POST -H 'Content-Type: application/json' --data-binary @- http://localhost:5011/api/login) ||
    fail "Slurm-web LDAP login as $SLURMWEB_USER"
  pass "Slurm-web LDAP login as $SLURMWEB_USER"
  web_token=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<<"$web_auth")
  # The cluster name comes from the agent's [service] cluster setting; listing
  # clusters also makes the gateway register the agent.
  clusters=$(curl -sf -H "Authorization: Bearer $web_token" http://localhost:5011/api/clusters) ||
    fail "Slurm-web cluster list"
  CLUSTER=$(python3 -c 'import json,sys,urllib.parse; print(urllib.parse.quote(json.load(sys.stdin)[0]["name"], safe=""))' <<<"$clusters")
  stats=$(curl -sf -H "Authorization: Bearer $web_token" "http://localhost:5011/api/agents/$CLUSTER/stats") ||
    fail "Slurm-web stats for $CLUSTER"
  pass "Slurm-web gateway -> agent -> slurmrestd ($stats)"
  curl -sf -H "Authorization: Bearer $web_token" "http://localhost:5011/api/agents/$CLUSTER/jobs/past?hours=24" >/dev/null ||
    fail "Slurm-web job history (slurmrestd -> slurmdbd)"
  pass "Slurm-web job history via slurmdbd"
fi

echo "Smoke test passed."
