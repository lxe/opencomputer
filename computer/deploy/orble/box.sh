#!/usr/bin/env bash
# Run the OpenComputer host's systemd and rootless Podman inside an Orble box.
set -euo pipefail

root=/var/lib/machines/opencomputer
data=/.oldroot/mnt/opencomputer-data
cgroup=/sys/fs/cgroup/orble-opencomputer
leader_file=$cgroup/payload/init.scope/cgroup.procs
ready=/run/orble-opencomputer.ready
lock=/run/lock/orble-opencomputer.lock
veth=ve-opencomputer
host_ip=10.239.65.1
computer_ip=10.239.65.2

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 && -x /usr/local/sbin/sbx-agent ]] || die 'Run this with sudo inside a dedicated Orble box.'

leader() {
  [[ -r $leader_file ]] && head -n 1 "$leader_file"
}

lock_box() {
  mkdir -p "${lock%/*}"
  exec 9>"$lock"
  flock -n 9 || die 'OpenComputer is already starting, running, or being initialized.'
}

install_proc_service() {
  # Lingering starts the runner's user manager on boot. The extra procfs
  # must be mounted before it can create Podman's rootless pause namespace.
  local units=$root/etc/systemd/system
  mkdir -p "$units/user@1500.service.d"
  cat >"$units/orble-podman-proc.service" <<'EOF'
[Unit]
Description=Mount procfs for rootless Podman

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/install -d -m 0700 /run/orble-proc /run/orble-proc/proc
ExecStart=/usr/bin/mount -t proc -o rw,nosuid,nodev,noexec proc /run/orble-proc/proc
EOF
  cat >"$units/user@1500.service.d/10-orble-podman-proc.conf" <<'EOF'
[Unit]
Requires=orble-podman-proc.service
After=orble-podman-proc.service
EOF
}

init() {
  lock_box
  [[ ! -f $root/.orble-ready ]] || return 0
  [[ ! -e $root ]] || die "An unfinished or existing filesystem is at $root."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q --no-install-recommends debootstrap systemd-container
  mkdir -p "${root%/*}"
  local staging
  staging=$(mktemp -d "${root%/*}/.opencomputer.XXXXXXXX")
  chmod 0755 "$staging"
  if ! debootstrap --variant=minbase --include=systemd-sysv,dbus,dbus-user-session,ca-certificates,sudo,git,iptables,procps \
    trixie "$staging" http://deb.debian.org/debian; then
    die "Debian bootstrap failed in $staging. Run box.sh init to retry."
  fi
  chroot "$staging" update-alternatives --set iptables /usr/sbin/iptables-legacy
  chroot "$staging" update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
  printf 'opencomputer\n' > "$staging/etc/hostname"
  printf '127.0.0.1 localhost opencomputer\n::1 localhost\n' > "$staging/etc/hosts"
  touch "$staging/.orble-ready"
  mv -T "$staging" "$root"
}

start() (
  lock_box
  [[ -f $root/.orble-ready ]] || die 'Run box.sh init first.'
  mountpoint -q "${data%/*}" || die "The Orble data disk is not mounted at ${data%/*}."
  # Native rootless overlay storage needs the underlying ext4 disk. A FUSE
  # mount on the VM's overlay root can die with the runner's systemd unit.
  install -d -m 0755 "$data"
  install_proc_service
  rm -f "$ready"
  iface=$(ip -4 route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p')
  [[ -n $iface ]] || die 'The box has no IPv4 uplink.'
  previous_forward=$(sysctl -n net.ipv4.ip_forward)
  if [[ -d $cgroup ]]; then
    find "$cgroup" -depth -type d -exec rmdir {} +
  fi
  mkdir "$cgroup"
  # Pasta needs the device open as the rootless runner user. Creating the tap
  # still requires CAP_NET_ADMIN in the runner's network namespace.
  chmod 0666 /dev/net/tun
  (
    printf '%s\n' "$BASHPID" > "$cgroup/cgroup.procs"
    exec systemd-nspawn --boot --keep-unit --register=no --console=pipe \
      --directory="$root" --machine=opencomputer --network-veth \
      --bind="$data:/data:norbind" --resolv-conf=copy-host --system-call-filter=keyctl
  ) &
  nspawn=$! pid=''
  nat=(-s "$computer_ip/32" -o "$iface" -j MASQUERADE)
  nat_added=false
  cleanup() {
    rm -f "$ready"
    kill -TERM "$nspawn" 2>/dev/null || true
    wait "$nspawn" || true
    if "$nat_added"; then
      iptables-legacy -t nat -D POSTROUTING "${nat[@]}" 2>/dev/null || true
    fi
    sysctl -qw "net.ipv4.ip_forward=$previous_forward"
  }
  trap cleanup EXIT
  trap 'exit 0' INT TERM
  for _ in {1..100}; do
    pid=$(leader || true)
    [[ -n $pid ]] && ip link show "$veth" >/dev/null 2>&1 && break
    kill -0 "$nspawn" 2>/dev/null || die 'systemd-nspawn exited before boot.'
    sleep .1
  done
  [[ -n $pid ]] && ip link show "$veth" >/dev/null 2>&1 || die 'Timed out waiting for systemd and its network.'
  ip address replace "$host_ip/30" dev "$veth"
  ip link set "$veth" up
  nsenter -t "$pid" -n -- ip address replace "$computer_ip/30" dev host0
  nsenter -t "$pid" -n -- ip link set host0 up
  nsenter -t "$pid" -n -- ip route replace default via "$host_ip"
  sysctl -qw net.ipv4.ip_forward=1
  if ! iptables-legacy -t nat -C POSTROUTING "${nat[@]}" 2>/dev/null; then
    iptables-legacy -t nat -A POSTROUTING "${nat[@]}"
    nat_added=true
  fi

  for _ in {1..100}; do
    state=$(nsenter -t "$pid" -a -- systemctl is-system-running 2>/dev/null || true)
    [[ $state == running || $state == degraded ]] && break
    kill -0 "$nspawn" 2>/dev/null || die 'systemd-nspawn exited during boot.'
    sleep .2
  done
  [[ $state == running || $state == degraded ]] || die 'Timed out waiting for the systemd manager.'
  nsenter -t "$pid" -a -- systemctl start orble-podman-proc.service
  touch "$ready"
  wait "$nspawn"
)

case "${1:-}" in
  init) init ;;
  start) start ;;
  exec)
    shift
    [[ $# -gt 0 ]] || die 'Pass a command to run inside the Computer.'
    [[ -f $ready ]] || die 'Wait for box.sh start to finish booting the Computer.'
    pid=$(leader) || die 'Start the Computer first.'
    [[ -n $pid ]] || die 'Start the Computer first.'
    # A transient unit places the command in the Computer's cgroup.
    exec nsenter -t "$pid" -a -- systemd-run --wait --pipe --collect --quiet -- "$@"
    ;;
  stop)
    pid=$(leader) || die 'The Computer is stopped.'
    [[ -n $pid ]] || die 'The Computer is stopped.'
    exec nsenter -t "$pid" -a -- systemctl poweroff
    ;;
  *) die 'Usage: box.sh init | start | exec COMMAND [ARG ...] | stop' ;;
esac
