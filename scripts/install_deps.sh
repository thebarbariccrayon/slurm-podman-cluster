#!/usr/bin/env bash

# install_deps.sh
#
# Installs what the host needs to build and run the cluster with Podman:
# podman, Docker Compose v2 (the provider behind `podman compose`; the stack
# uses inline `configs:` content, which needs Compose >= 2.23), make, git (the
# Slurm-web images build from a git URL), an OpenSSH client, curl and python3
# (used by the smoke test).
#
# Supported hosts: macOS (Homebrew), RHEL/Fedora family (dnf/yum),
# Debian/Ubuntu family (apt) and Arch Linux family (pacman). On Windows, run
# scripts/install_deps.ps1, which sets up WSL2 and then runs this script there.
#
# On macOS it also creates and starts a Podman machine. On Linux it sets up
# rootless Podman: subordinate UID/GID ranges, the user's Podman API socket
# (which docker-compose talks to) and cgroup v2 controller delegation so Slurm
# can enforce memory and CPU limits.
#
# Usage: scripts/install_deps.sh [-y|--yes] [--skip-machine] [-h|--help]
#
# Environment:
#   PODMAN_MACHINE_CPUS    vCPUs for a new Podman machine (default 4)
#   PODMAN_MACHINE_MEMORY  memory in MiB for a new Podman machine (default 8192)
#   PODMAN_MACHINE_DISK    disk in GiB for a new Podman machine (default 100)
#   COMPOSE_VERSION        Docker Compose release to download when the package
#                          manager has no usable one, e.g. 2.40.3 (default latest)

set -euo pipefail

MIN_COMPOSE=2.23.0
MIN_PODMAN=4.7.0

ASSUME_YES=0
SKIP_MACHINE=0

usage() { sed -n '3,/^$/{s/^# \{0,1\}//;p;}' "$0"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    -y|--yes) ASSUME_YES=1 ;;
    --skip-machine) SKIP_MACHINE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# version_ge A B: true if version A >= version B (numeric dotted versions).
version_ge() {
  local -a a b
  local i
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    (( ${a[i]:-0} > ${b[i]:-0} )) && return 0
    (( ${a[i]:-0} < ${b[i]:-0} )) && return 1
  done
  return 0
}

SUDO=
if [[ $(id -u) -ne 0 ]]; then
  if [[ $(uname -s) != Darwin ]]; then
    have sudo || die "sudo is required to install packages (or run as root)"
    SUDO=sudo
  fi
fi

podman_version() { podman version --format '{{.Client.Version}}' 2>/dev/null | sed 's/[^0-9.].*//' || true; }

# Prints the version of the first Docker Compose v2 binary podman can find,
# or nothing.
compose_bin() {
  local c
  for c in "$(command -v docker-compose 2>/dev/null)" \
           "$HOME/.docker/cli-plugins/docker-compose" \
           /usr/local/lib/docker/cli-plugins/docker-compose \
           /usr/local/libexec/docker/cli-plugins/docker-compose \
           /usr/lib/docker/cli-plugins/docker-compose \
           /usr/libexec/docker/cli-plugins/docker-compose; do
    [[ -n $c && -x $c ]] && { echo "$c"; return; }
  done
}

compose_version() {
  local bin
  bin=$(compose_bin)
  [[ -n $bin ]] || return 0
  "$bin" version --short 2>/dev/null | sed 's/^v//; s/[^0-9.].*//'
}

# Downloads the official static docker-compose binary into the system-wide
# CLI plugin directory (where podman looks for it) and links it into PATH.
install_compose_binary() {
  local arch url dir=/usr/local/lib/docker/cli-plugins tmp
  case $(uname -m) in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "no Docker Compose release for $(uname -m); install Compose >= $MIN_COMPOSE manually" ;;
  esac
  if [[ -n ${COMPOSE_VERSION:-} ]]; then
    url=https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION#v}/docker-compose-linux-$arch
  else
    url=https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch
  fi
  info "Downloading Docker Compose from $url"
  tmp=$(mktemp -d)
  # The published checksum file names the asset, so keep that file name.
  if ! { curl -fsSL -o "$tmp/docker-compose-linux-$arch" "$url" &&
         curl -fsSL -o "$tmp/sha256" "$url.sha256" &&
         (cd "$tmp" && sha256sum -c sha256 >/dev/null); }; then
    rm -rf "$tmp"
    die "Docker Compose download or checksum verification failed"
  fi
  $SUDO install -d -m 755 "$dir"
  $SUDO install -m 755 "$tmp/docker-compose-linux-$arch" "$dir/docker-compose"
  rm -rf "$tmp"
  $SUDO ln -sf "$dir/docker-compose" /usr/local/bin/docker-compose
}

ensure_compose() {
  local v
  v=$(compose_version)
  if [[ -n $v ]] && version_ge "$v" "$MIN_COMPOSE"; then
    info "Docker Compose $v found at $(compose_bin)"
    return
  fi
  [[ $OS == Darwin ]] && die "Docker Compose >= $MIN_COMPOSE not found; run: brew upgrade docker-compose"
  [[ -n $v ]] && info "Docker Compose $v is older than $MIN_COMPOSE"
  install_compose_binary
  v=$(compose_version)
  version_ge "${v:-0}" "$MIN_COMPOSE" || die "Docker Compose >= $MIN_COMPOSE still not available"
  info "Docker Compose $v installed"
}

# --- package installation per platform -------------------------------------

install_macos() {
  have brew || die "Homebrew is required: see https://brew.sh"
  xcode-select -p >/dev/null 2>&1 || {
    info "Installing Xcode Command Line Tools (provides make and git)"
    xcode-select --install || true
    die "re-run this script once the Command Line Tools installer finishes"
  }
  info "Installing packages with Homebrew"
  brew install podman docker-compose
  # Homebrew's docker-compose is the v2 plugin binary; podman finds it in PATH.
}

install_rhel() {
  local pm=dnf
  have dnf || pm=yum
  local -a yes=()
  (( ASSUME_YES )) && yes=(-y)
  # RHEL's default curl-minimal conflicts with the curl package; either works.
  local curl=curl
  have curl && curl=
  info "Installing packages with $pm"
  $SUDO "$pm" install ${yes[@]+"${yes[@]}"} podman git make openssh-clients $curl python3 shadow-utils
  # Rootless networking helpers; package names vary between releases.
  $SUDO "$pm" install -y passt >/dev/null 2>&1 ||
    $SUDO "$pm" install -y slirp4netns >/dev/null 2>&1 || true
  # Fedora packages Compose v2; RHEL does not, so ensure_compose downloads it.
  $SUDO "$pm" install -y docker-compose >/dev/null 2>&1 || true
}

install_debian() {
  local -a yes=()
  (( ASSUME_YES )) && yes=(-y)
  info "Installing packages with apt"
  $SUDO apt-get update
  $SUDO apt-get install ${yes[@]+"${yes[@]}"} podman git make openssh-client curl python3 \
    uidmap slirp4netns dbus-user-session
  local p
  for p in passt fuse-overlayfs; do
    $SUDO apt-get install -y "$p" >/dev/null 2>&1 || true
  done
  # Ubuntu >= 24.04 ships Compose v2 as docker-compose-v2; Debian >= 13 as
  # docker-compose. Older releases only have v1, so ensure_compose downloads v2.
  $SUDO apt-get install -y docker-compose-v2 >/dev/null 2>&1 ||
    { apt-cache policy docker-compose 2>/dev/null | grep -q 'Candidate: 2' &&
      $SUDO apt-get install -y docker-compose >/dev/null 2>&1; } || true
}

install_arch() {
  local -a yes=()
  (( ASSUME_YES )) && yes=(--noconfirm)
  info "Installing packages with pacman (full sync: Arch does not support partial upgrades)"
  $SUDO pacman -Syu --needed ${yes[@]+"${yes[@]}"} podman docker-compose git make openssh curl python passt
}

# --- post-install setup -----------------------------------------------------

setup_macos_machine() {
  (( SKIP_MACHINE )) && { info "Skipping Podman machine setup"; return; }
  if ! podman machine inspect >/dev/null 2>&1; then
    info "Creating Podman machine (${PODMAN_MACHINE_CPUS:-4} CPUs, ${PODMAN_MACHINE_MEMORY:-8192} MiB, ${PODMAN_MACHINE_DISK:-100} GiB)"
    podman machine init \
      --cpus "${PODMAN_MACHINE_CPUS:-4}" \
      --memory "${PODMAN_MACHINE_MEMORY:-8192}" \
      --disk-size "${PODMAN_MACHINE_DISK:-100}"
  fi
  if [[ $(podman machine inspect --format '{{.State}}' 2>/dev/null) != running ]]; then
    info "Starting Podman machine"
    podman machine start
  fi
}

setup_linux_rootless() {
  local user
  user=$(id -un)
  if [[ $(id -u) -eq 0 ]]; then
    warn "running as root: the cluster will use rootful Podman; skipping rootless setup"
    return
  fi

  if ! grep -q "^$user:" /etc/subuid 2>/dev/null || ! grep -q "^$user:" /etc/subgid 2>/dev/null; then
    info "Adding subordinate UID/GID ranges for $user"
    $SUDO usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$user"
    podman system migrate >/dev/null 2>&1 || true
  fi

  if (( IS_WSL )) && [[ ! -d /run/systemd/system ]]; then
    die "systemd is not running in this WSL distribution; run scripts/install_deps.ps1 from Windows first"
  fi

  # docker-compose reaches Podman through its Docker-compatible API socket.
  if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
    info "Enabling the Podman API socket for $user"
    systemctl --user enable --now podman.socket
  else
    warn "no systemd user session; start the Podman API yourself: podman system service --time=0 &"
  fi

  if [[ $(stat -fc %T /sys/fs/cgroup 2>/dev/null) != cgroup2fs ]]; then
    if (( IS_WSL )); then
      warn "WSL is not on cgroup v2; Slurm cannot enforce job limits in rootless containers." \
           "Run scripts/install_deps.ps1 from Windows (it sets cgroup_no_v1=all in .wslconfig)."
    else
      warn "host is not on cgroup v2; Slurm cannot enforce job limits in rootless containers." \
           "Enable it with the kernel argument systemd.unified_cgroup_hierarchy=1 and reboot."
    fi
    return
  fi

  local uid ctrls
  uid=$(id -u)
  ctrls=$(cat "/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers" 2>/dev/null || true)
  if [[ " $ctrls " != *" memory "* || " $ctrls " != *" cpu "* || " $ctrls " != *" cpuset "* ]]; then
    info "Delegating cpu, cpuset, io, memory and pids cgroup controllers to user sessions"
    $SUDO mkdir -p /etc/systemd/system/user@.service.d
    printf '[Service]\nDelegate=cpu cpuset io memory pids\n' |
      $SUDO tee /etc/systemd/system/user@.service.d/delegate.conf >/dev/null
    $SUDO systemctl daemon-reload
    NEED_RELOGIN=1
  fi
}

# --- main -------------------------------------------------------------------

NEED_RELOGIN=0
OS=$(uname -s)
IS_WSL=0
grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null && IS_WSL=1

case $OS in
  Darwin)
    install_macos
    ensure_compose
    setup_macos_machine
    ;;
  Linux)
    [[ -r /etc/os-release ]] || die "cannot identify this Linux distribution (/etc/os-release missing)"
    # shellcheck disable=SC1091
    . /etc/os-release
    family=" ${ID:-} ${ID_LIKE:-} "
    case $family in
      *" arch "*|*" archlinux "*|*" manjaro "*|*" endeavouros "*) install_arch ;;
      *" debian "*|*" ubuntu "*) install_debian ;;
      *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*) install_rhel ;;
      *) die "unsupported distribution '${ID:-unknown}'; supported: RHEL/Fedora, Debian/Ubuntu, Arch Linux, macOS" ;;
    esac
    ensure_compose
    setup_linux_rootless
    ;;
  *) die "unsupported OS '$OS'; supported: RHEL/Fedora, Debian/Ubuntu, Arch Linux, macOS" ;;
esac

# --- verification -----------------------------------------------------------

pv=$(podman_version)
[[ -n $pv ]] || die "podman is not working after installation; check: podman info"
info "Podman $pv"
for tool in make git ssh ssh-keygen curl python3; do
  have "$tool" || die "$tool is not on PATH after installation"
done

if ! version_ge "$pv" "$MIN_PODMAN"; then
  warn "Podman $pv has no 'podman compose' (needs >= $MIN_PODMAN). Drive docker-compose directly:"
  warn "  export DOCKER_HOST=unix://\${XDG_RUNTIME_DIR}/podman/podman.sock"
  warn "  make up COMPOSE=docker-compose"
elif ! podman compose version >/dev/null 2>&1; then
  warn "'podman compose' did not find the Compose provider; check 'podman compose version'"
fi

echo
info "Dependencies installed."
if (( NEED_RELOGIN )) && (( IS_WSL )); then
  info "From Windows, run 'wsl --terminate ${WSL_DISTRO_NAME:-<distro>}' so the cgroup delegation takes effect, then: make up"
elif (( NEED_RELOGIN )); then
  info "Log out and back in (or reboot) so the cgroup delegation takes effect, then run: make up"
else
  info "Next: make up && make test"
fi
