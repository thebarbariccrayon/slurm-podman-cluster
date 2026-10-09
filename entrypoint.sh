#!/bin/bash

# entrypoint.sh
#
# Starts the Slurm daemon selected by $ROLE. Config files are baked into the
# image under /config and installed here with the ownership/permissions Slurm
# insists on, so the host needs no sudo/chown steps.

set -euo pipefail

MUNGE_KEY=/etc/munge/munge.key
# Slurm JWT signing key shared by slurmctld, slurmdbd and the Slurm-web agent.
JWT_KEY_SHARED=/etc/slurm-jwt/jwt_hs256.key
JWT_KEY=/etc/slurm/jwt_hs256.key
SLURMWEB_DIR=/var/lib/slurm-web
SLURMWEB_UID=1000
CLUSTER_USER=${CLUSTER_USER:-hpcuser}

echo "[ENTRYPOINT] Role: ${ROLE:-unset}"

# Generate the cluster-wide munge key once; all nodes share the volume.
init_munge_key() {
  if [[ -s "$MUNGE_KEY" ]]; then
    echo "Munge key already exists, leaving it untouched."
  else
    echo "Generating munge key..."
    dd if=/dev/urandom bs=1 count=1024 of="$MUNGE_KEY" status=none
  fi
  chown slurm:slurm "$MUNGE_KEY"
  chmod 0400 "$MUNGE_KEY"
}

# Generate the Slurm JWT key once and hand a copy to the Slurm-web agent.
init_jwt_key() {
  if [[ ! -s "$JWT_KEY_SHARED" ]]; then
    echo "Generating Slurm JWT signing key..."
    dd if=/dev/urandom bs=32 count=1 of="$JWT_KEY_SHARED" status=none
  fi
  chown slurm:slurm "$JWT_KEY_SHARED"
  chmod 0600 "$JWT_KEY_SHARED"
  if [[ -d "$SLURMWEB_DIR" ]]; then
    chown "$SLURMWEB_UID:$SLURMWEB_UID" "$SLURMWEB_DIR"
    install -o "$SLURMWEB_UID" -g "$SLURMWEB_UID" -m 0400 "$JWT_KEY_SHARED" "$SLURMWEB_DIR/slurmrestd.key"
  fi
}

# Create the cluster user's home on the shared volume.
init_cluster_home() {
  local home=/shared/home/$CLUSTER_USER
  if [[ ! -d "$home" ]]; then
    mkdir -p "$home"
    cp -rT /etc/skel "$home"
  fi
  chown -R "$CLUSTER_USER:$CLUSTER_USER" "$home"
  chmod 0700 "$home"
}

# Refresh the Slurm-web branding volume from the image on every start, so a
# rebuild picks up changed logos.
init_slurm_web_branding() {
  local dest=/slurm-web-branding
  [[ -d "$dest" ]] || return 0
  find "$dest" -mindepth 1 -delete
  cp -r /config/slurm-web-branding/. "$dest/"
  chmod -R a+rX "$dest"
}

# Resolve directory users and groups through nslcd (NSS and PAM), using the
# same LDAP_* settings as the Slurm-web gateway. Skipped when LDAP_URI is empty.
start_nslcd() {
  [[ -n "${LDAP_URI:-}" ]] || return 0
  {
    echo "uid nslcd"
    echo "gid nslcd"
    echo "uri $LDAP_URI"
    echo "base passwd $LDAP_USER_BASE"
    echo "base shadow $LDAP_USER_BASE"
    echo "base group $LDAP_GROUP_BASE"
    if [[ -n "${LDAP_BIND_DN:-}" ]]; then
      echo "binddn $LDAP_BIND_DN"
      echo "bindpw $LDAP_BIND_PASSWORD"
    fi
    if [[ "${LDAP_STARTTLS:-no}" == "yes" ]]; then
      echo "ssl start_tls"
    fi
    echo "tls_cacertfile /etc/ssl/certs/ca-certificates.crt"
    echo "bind_timelimit 5"
    echo "timelimit 10"
  } >/etc/nslcd.conf
  chown root:nslcd /etc/nslcd.conf
  chmod 0640 /etc/nslcd.conf
  install -d -o nslcd -g nslcd /run/nslcd
  echo "Starting nslcd ($LDAP_URI)..."
  /usr/sbin/nslcd
}

# Make directory users usable on every cluster in $SLURM_CLUSTERS: create
# missing home directories under /shared/home, mirror the LDAP groups in
# $SLURM_ACCOUNT_GROUPS into Slurm accounts with their members, and make members
# of $SLURM_ADMIN_GROUP Slurm administrators. Safe to rerun; existing accounts
# and users are kept.
sync_directory() {
  local admin_group=${SLURM_ADMIN_GROUP:-admins} group user uid gid home cluster
  local clusters
  clusters=$(tr -s ' ' ',' <<<"${SLURM_CLUSTERS:-homelab-cluster}" | sed 's/^,//; s/,$//')
  for _ in $(seq 1 30); do
    getent group "$admin_group" >/dev/null && break
    sleep 1
  done
  getent group "$admin_group" >/dev/null || { echo "Group $admin_group not found in LDAP" >&2; exit 1; }
  # Each slurmctld registers its cluster with slurmdbd when it starts.
  for cluster in ${SLURM_CLUSTERS:-homelab-cluster}; do
    for _ in $(seq 1 90); do
      sacctmgr -n -P show cluster format=cluster 2>/dev/null | tr -d '|' | grep -qx "$cluster" && break
      sleep 2
    done
    sacctmgr -n -P show cluster format=cluster | tr -d '|' | grep -qx "$cluster" ||
      { echo "Cluster $cluster never registered with slurmdbd" >&2; exit 1; }
  done

  getent passwd | while IFS=: read -r user _ uid gid _ home _; do
    [[ "$uid" -ge 1000 && "$home" == /shared/home/* && ! -d "$home" ]] || continue
    echo "Creating home directory $home"
    mkdir -p "$home"
    cp -rT /etc/skel "$home"
    chown -R "$uid:$gid" "$home"
    chmod 0700 "$home"
  done

  members() { getent group "$1" | cut -d: -f4 | tr ',' ' '; }
  for group in ${SLURM_ACCOUNT_GROUPS:-}; do
    if ! getent group "$group" >/dev/null; then
      echo "Group $group not found in LDAP, skipping" >&2
      continue
    fi
    sacctmgr -i add account "$group" Cluster="$clusters" Description="LDAP group $group" Organization="$group" >/dev/null || true
    for user in $(members "$group"); do
      sacctmgr -i add user "$user" Cluster="$clusters" Account="$group" >/dev/null || true
    done
  done
  for user in $(members "$admin_group"); do
    sacctmgr -i add user "$user" Cluster="$clusters" Account=root AdminLevel=Administrator >/dev/null || true
    sacctmgr -i modify user "$user" set AdminLevel=Administrator >/dev/null || true
  done
  sacctmgr -n -P show association format=Cluster,Account,User where clusters="$clusters" users="$(getent passwd | awk -F: '$3 >= 3000 && $3 < 60000 {print $1}' | paste -sd, -)" |
    awk -F'|' 'BEGIN { print "Slurm associations:" } { print "  " $1 ": " $3 " -> " $2 }'
  sacctmgr -n -P show user format=User,DefaultAccount,AdminLevel | awk -F'|' '$3 == "Administrator" { print "Slurm administrator: " $1 }'
}

# Federate the clusters in $SLURM_CLUSTERS under $FEDERATION_NAME when there
# is more than one, so jobs are copied to every cluster that has the requested
# partition and run on whichever can start them first. With a single cluster,
# delete the federation, so the remaining cluster does not keep waiting on a
# sibling that is no longer running.
sync_federation() {
  local name=${FEDERATION_NAME:-homelab} clusters current
  local -a list
  read -r -a list <<<"${SLURM_CLUSTERS:-homelab-cluster}"
  clusters=$(printf '%s\n' "${list[@]}" | sort | paste -sd, -)
  # sacctmgr may end single-column parsable output with a stray '|'.
  if (( ${#list[@]} > 1 )); then
    if sacctmgr -n -P show federation format=federation | tr -d '|' | grep -qx "$name"; then
      # Setting the members it already has is an error, so compare first.
      current=$(sacctmgr -n -P show federation "$name" format=cluster | tr -d '|' | sort | paste -sd, -)
      [[ "$current" == "$clusters" ]] ||
        sacctmgr -i modify federation "$name" set clusters="$clusters" >/dev/null
    else
      sacctmgr -i add federation "$name" clusters="$clusters" >/dev/null
    fi
    echo "Federation $name:"
    sacctmgr -n -P show federation "$name" format=cluster,fedstate |
      awk -F'|' '{ print "  " $1 " (" $2 ")" }'
  elif sacctmgr -n -P show federation format=federation | tr -d '|' | grep -qx "$name"; then
    echo "Single cluster: deleting federation $name"
    sacctmgr -i delete federation "$name" >/dev/null
  fi
}

# Install the shared JWT key where slurm.conf/slurmdbd.conf expect it.
install_jwt_key() {
  install -o slurm -g slurm -m 0600 "$JWT_KEY_SHARED" "$JWT_KEY"
}

# Configure and start sshd. The local cluster user gets a password when
# $SSH_PASSWORD is set and public keys from $SSH_AUTHORIZED_KEYS; LDAP users
# sign in with their directory password through PAM (pam_mkhomedir creates a
# missing home). Host keys are kept in a volume so the fingerprint survives
# container recreation.
start_sshd() {
  local hostkeys=/etc/ssh/hostkeys home=/shared/home/$CLUSTER_USER
  mkdir -p "$hostkeys"
  for type in ed25519 rsa; do
    [[ -f "$hostkeys/ssh_host_${type}_key" ]] ||
      ssh-keygen -q -N "" -t "$type" -f "$hostkeys/ssh_host_${type}_key"
  done

  if [[ -n "${SSH_PASSWORD:-}" ]]; then
    echo "$CLUSTER_USER:$SSH_PASSWORD" | chpasswd
  else
    passwd -l "$CLUSTER_USER" >/dev/null
  fi

  install -d -o "$CLUSTER_USER" -g "$CLUSTER_USER" -m 0700 "$home/.ssh"
  printf '%s\n' "${SSH_AUTHORIZED_KEYS:-}" >"$home/.ssh/authorized_keys"
  chown "$CLUSTER_USER:$CLUSTER_USER" "$home/.ssh/authorized_keys"
  chmod 0600 "$home/.ssh/authorized_keys"

  cat >/etc/ssh/sshd_config.d/cluster.conf <<SSHD
HostKey $hostkeys/ssh_host_ed25519_key
HostKey $hostkeys/ssh_host_rsa_key
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
SSHD
  echo "Starting sshd..."
  exec /usr/sbin/sshd -D -e
}

# Start munged as the slurm user and wait until it can issue credentials.
start_munge() {
  if [[ ! -s "$MUNGE_KEY" ]]; then
    echo "Missing $MUNGE_KEY (did secrets-init run?)" >&2
    exit 1
  fi
  echo "Starting munge..."
  su -s /bin/bash slurm -c "/usr/sbin/munged --log-file=/var/log/munge/munged.log"
  for _ in $(seq 1 20); do
    if munge -n | unmunge >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "munged did not become ready" >&2
  exit 1
}

# Install a config file from /config into /etc/slurm, optionally from a
# differently named source (e.g. slurm-dc2.conf -> slurm.conf).
install_config() {
  local name=$1 mode=$2 source=${3:-$1}
  if [[ -f "/config/$source" ]]; then
    install -o slurm -g slurm -m "$mode" "/config/$source" "/etc/slurm/$name"
  fi
}

# Which cluster this container belongs to: its slurm.conf in /config.
install_slurm_conf() {
  install_config slurm.conf 0644 "${SLURM_CONF_SOURCE:-slurm.conf}"
}

# cgroup v2 forbids enabling controllers for children of a cgroup that still
# holds processes, so move everything into a leaf cgroup and delegate all
# available controllers to the namespace root's subtree for slurmd to use.
setup_cgroup_v2() {
  local root=/sys/fs/cgroup
  [[ -f "$root/cgroup.controllers" && -w "$root/cgroup.subtree_control" ]] || return 0
  mkdir -p "$root/init"
  xargs -rn1 <"$root/cgroup.procs" >"$root/init/cgroup.procs" 2>/dev/null || true
  local controllers
  read -r -a controllers <"$root/cgroup.controllers"
  for controller in "${controllers[@]}"; do
    echo "+$controller" >"$root/cgroup.subtree_control" 2>/dev/null || true
  done
}

case "${ROLE:-}" in
  secrets-init)
    init_munge_key
    init_jwt_key
    init_cluster_home
    init_slurm_web_branding
    ;;
  controller)
    install_slurm_conf
    install_jwt_key
    start_munge
    start_nslcd

    echo "Starting slurmctld..."
    exec su -s /bin/bash slurm -c "exec /usr/sbin/slurmctld -D -vvvv"
    ;;
  compute)
    setup_cgroup_v2
    start_munge
    start_nslcd
    echo "Starting slurmd..."
    exec /usr/sbin/slurmd -D -vvvv --conf-server="${SLURM_CONF_SERVER:-slurm-controller}"
    ;;
  slurmdbd)
    install_config slurmdbd.conf 0600
    install_jwt_key
    start_munge
    echo "Starting slurmdbd..."
    exec su -s /bin/bash slurm -c "exec /usr/sbin/slurmdbd -D -vvvv"
    ;;
  rest)
    install_slurm_conf
    start_munge
    # slurmrestd resolves job owners' names itself.
    start_nslcd
    # Set the default JWT user
    export SLURM_JWT=restadmin

    echo "Starting slurmrestd..."
    exec su -s /bin/bash restuser -c "exec /usr/sbin/slurmrestd -a rest_auth/jwt 0.0.0.0:6820 -vvvv"
    ;;
  login)
    install_slurm_conf
    start_munge
    start_nslcd
    start_sshd
    ;;
  directory-sync)
    install_slurm_conf
    start_munge
    start_nslcd
    sync_directory
    sync_federation
    ;;
  *)
    echo "Unknown role: ${ROLE:-unset}"
    exec "$@"
    ;;
esac
