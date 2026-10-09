# Dockerfile

FROM ubuntu:22.04

# Single image for every Slurm role (controller, compute, slurmdbd, slurmrestd);
# the role is chosen at runtime by entrypoint.sh via $ROLE.
LABEL maintainer="David Lewellyn <dlewell@ncsu.edu>" \
      org.opencontainers.image.authors="David Lewellyn <dlewell@ncsu.edu>" \
      org.opencontainers.image.title="slurm-podman-cluster" \
      org.opencontainers.image.description="Slurm controller and compute node Docker image." \
      org.opencontainers.image.version="1.1.0" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# Build toolchain and the libraries for the Slurm features configured below
# (MUNGE, MariaDB accounting, JWT, slurmrestd, hwloc, PMIx), plus editors.
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    vim \
    nano \
    python3 \
    python3-pip \
    ca-certificates \
    munge \
    libmunge-dev \
    libssl-dev \
    libpam0g-dev \
    libmariadb-dev \
    libmariadb-dev-compat \
    mariadb-client \
    libdbus-1-dev \
    hwloc \
    libhwloc-dev \
    libnuma-dev \
    liblz4-dev \
    libjson-c-dev \
    libjwt-dev \
    libhttp-parser-dev \
    libyaml-dev \
    libevent-dev \
    libpmix-dev \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged account that slurmctld and slurmdbd run as (SlurmUser).
RUN groupadd -r slurm && \
    useradd -r -g slurm -d /var/lib/slurm -s /bin/bash slurm

# slurmrestd will not run as root or SlurmUser, so it gets its own account.
RUN groupadd restgroup && \
    useradd -r -g restgroup -d /home/restuser -s /bin/bash restuser

ARG SLURM_VERSION=25.11.7
ENV SLURM_VERSION=${SLURM_VERSION}

RUN echo "Building Slurm version ${SLURM_VERSION}"

WORKDIR /opt

# Compile the requested release from SchedMD's tarball in one layer, so the
# sources and build tree never end up in the image.
RUN wget -q https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2 && \
    tar -xjf slurm-${SLURM_VERSION}.tar.bz2 && \
    cd slurm-${SLURM_VERSION} && \
    ./configure --prefix=/usr --sysconfdir=/etc/slurm --with-munge --with-hwloc --with-json --with-http-parser --with-jwt --enable-slurmrestd --enable-multiple-slurmd --with-pmix && \
    make -j$(nproc) && \
    make install && \
    cd /opt && rm -rf slurm-${SLURM_VERSION} slurm-${SLURM_VERSION}.tar.bz2

# SSH server for the login node, and the cluster user that submits jobs. The
# user exists in every container with the same UID so jobs run as that user on
# the compute nodes; its home lives on the /shared volume.
ARG CLUSTER_USER=hpcuser
ARG CLUSTER_UID=2000
ENV CLUSTER_USER=${CLUSTER_USER}
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server && \
    rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* && \
    mkdir -p /run/sshd && \
    groupadd -g ${CLUSTER_UID} ${CLUSTER_USER} && \
    useradd -u ${CLUSTER_UID} -g ${CLUSTER_USER} -d /shared/home/${CLUSTER_USER} -M -s /bin/bash ${CLUSTER_USER}

# LDAP users and groups: nslcd resolves them for NSS (so slurmctld and slurmd
# see the same UIDs everywhere) and PAM (password SSH on the login node, home
# directory creation). entrypoint.sh writes /etc/nslcd.conf from $LDAP_*.
RUN apt-get update && apt-get install -y --no-install-recommends nslcd libnss-ldapd libpam-ldapd ldap-utils && \
    rm -rf /var/lib/apt/lists/* && \
    sed -ri 's/^(passwd|group|shadow):.*/\1:         files ldap/' /etc/nsswitch.conf && \
    pam-auth-update --enable ldap mkhomedir

# Runtime, spool and log directories owned by SlurmUser.
RUN mkdir -p /var/log/slurm /var/spool/slurmd /var/spool/slurmctld /var/run/slurm /etc/slurm \
    && chown -R slurm:slurm /var/log/slurm /var/spool/slurmd /var/spool/slurmctld /var/run/slurm /etc/slurm

# munged runs as slurm (see entrypoint.sh), so it owns MUNGE's directories.
RUN mkdir -p /etc/munge /var/log/munge /var/lib/munge /run/munge && \
    chown -R slurm:slurm /etc/munge /var/log/munge /var/lib/munge /run/munge

# Create /etc/slurm/cgroup.conf with cgroup settings. Containers have no
# systemd, so slurmd must manage its cgroup v2 tree directly (IgnoreSystemd).
RUN mkdir -p /etc/slurm /config && \
    echo "CgroupPlugin=autodetect"   >> /etc/slurm/cgroup.conf && \
    echo "IgnoreSystemd=yes"         >> /etc/slurm/cgroup.conf && \
    echo "ConstrainCores=yes"        >> /etc/slurm/cgroup.conf && \
    echo "ConstrainRAMSpace=yes"     >> /etc/slurm/cgroup.conf && \
    echo "ConstrainDevices=no"       >> /etc/slurm/cgroup.conf

# Bake in the cluster config; entrypoint.sh installs it with the ownership and
# modes Slurm requires. Copied (not bind-mounted) so the repo can live anywhere,
# e.g. on a volume the Podman/Docker VM does not share. Rebuild after edits.
COPY slurm.conf slurm-dc2.conf slurmdbd.conf /config/

# Slurm-web gateway logos and favicon. Configs can only carry text, so
# secrets-init copies these into the slurm-web-branding volume instead.
COPY branding/ /config/slurm-web-branding/

# Picks the daemon to start from $ROLE.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /root

ENTRYPOINT ["/entrypoint.sh"]
