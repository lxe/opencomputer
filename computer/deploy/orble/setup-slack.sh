#!/usr/bin/env bash
# Provision a Computer and run the upstream gateway image on its Orble box.
set -euo pipefail

if [[ $# != 2 || ! $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ || ! $2 =~ ^[UW][A-Z0-9]+$ ]]; then
  printf 'Usage: %s BOX SLACK_MEMBER_ID\n' "${0##*/}" >&2
  exit 2
fi
box=$1
slack_user_id=$2
deploy_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$deploy_dir/../../.." && pwd)
version=$(git -C "$repo" rev-parse --short HEAD)

if ! orble ssh "$box" 'test -f /run/orble-opencomputer.ready'; then
  orble ssh "$box" 'sudo install -m 0755 /dev/stdin /usr/local/sbin/opencomputer-box' <"$deploy_dir/box.sh"
  orble ssh "$box" 'sudo opencomputer-box init &&
    sudo sh -c "nohup opencomputer-box start </dev/null >/var/log/opencomputer-box.log 2>&1 &"'
  orble ssh "$box" 'timeout 30 sh -c "until test -f /run/orble-opencomputer.ready; do sleep 1; done"'
fi
orble ssh "$box" 'set -e; host_ip=$(sudo opencomputer-box host-address)
  sudo opencomputer-box exec /bin/bash -c '\''
    if [[ -e /etc/slack-presence/host.env ]] &&
        ! grep -Fxq "SP_GATEWAY_URL=$1" /etc/slack-presence/host.env; then
      printf "This Computer already uses a different gateway.\n" >&2
      exit 1
    fi
  '\'' bash "ws://$host_ip:3170/host"'

if ! orble ssh "$box" 'sudo opencomputer-box exec systemctl is-enabled --quiet slack-presence-host.service'; then
  bundle=$(mktemp)
  trap 'unlink "$bundle" 2>/dev/null || true' EXIT
  "$deploy_dir/build-release.sh" "$bundle"
  orble ssh "$box" 'sudo opencomputer-box exec install -d -m 0755 /opt/bootstrap &&
    sudo opencomputer-box exec install -m 0644 /dev/stdin /opt/bootstrap/calvin.bundle' <"$bundle"
  orble ssh "$box" 'sudo opencomputer-box exec /bin/bash -c "
    set -e
    if [[ ! -d /opt/bootstrap/calvin-src/.git ]]; then
      git clone --branch main /opt/bootstrap/calvin.bundle /opt/bootstrap/calvin-src
    fi
    export CLOUD=none FORMAT_IF_BLANK=0 BLOCK_METADATA_ALL=1 REPO_URL=/opt/bootstrap/calvin.bundle
    bash /opt/bootstrap/calvin-src/deploy/vm/provision.sh
  "'
fi

orble ssh "$box" 'sudo apt-get update -qq &&
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends acl podman uidmap passt'
origin=$(orble port "$box" 3170 --public | awk '$1 ~ /^https:\/\// { print $1 }')
if [[ ! $origin =~ ^https://[a-zA-Z0-9.-]+$ ]]; then
  printf 'Could not read the HTTPS address for the shared port.\n' >&2
  exit 1
fi

orble ssh "$box" 'mkdir -p "$HOME/.local/share/opencomputer-gateway/source"'
git -C "$repo" archive HEAD computer | orble ssh "$box" 'tar -xf - -C "$HOME/.local/share/opencomputer-gateway/source"'

orble ssh "$box" "bash -s -- '$origin' '$slack_user_id' '$version'" <<'REMOTE'
set -euo pipefail
umask 077
origin=$1
slack_user_id=$2
version=$3
host_ip=$(sudo opencomputer-box host-address)
host_url=ws://$host_ip:3170/host
host_env=/etc/slack-presence/host.env
config="$HOME/.config/opencomputer"
storage=/.oldroot/mnt/opencomputer-gateway
gateway_env=$config/gateway.env
image=localhost/opencomputer-gateway:$version
container=opencomputer-gateway
people="SP_PEOPLE=[{\"slackUserId\":\"$slack_user_id\",\"dir\":\"operator\",\"gitName\":\"OpenComputer\",\"gitEmail\":\"opencomputer@localhost\"}]"

mkdir -p "$config"
exec 9>"$config/setup.lock"
flock 9
sudo setfacl -m "u:$(id -u):rw" /dev/net/tun
mountpoint -q /.oldroot/mnt
sudo install -d -m 0700 -o "$(id -u)" -g "$(id -g)" "$storage"
podman() { command podman --root "$storage/storage" "$@" 9>&-; }

if [[ -e $gateway_env ]]; then
  if ! grep -Fxq "SP_ORIGIN=$origin" "$gateway_env" || ! grep -Fxq "$people" "$gateway_env"; then
    printf 'The gateway configuration has a different origin or Slack member in %s.\n' "$gateway_env" >&2
    exit 1
  fi
else
  store_key=$(openssl rand -hex 32)
  setup_token=$(openssl rand -hex 32)
  host_token=$(openssl rand -hex 32)
  pending=$(mktemp "$config/.gateway.env.XXXXXXXX")
  trap 'unlink "$pending" 2>/dev/null || true' EXIT
  printf '%s\n' "SP_ORIGIN=$origin" "SP_STORE_KEY=$store_key" "SETUP_TOKEN=$setup_token" \
    "SP_HOST_TOKENS=$host_token" "$people" >"$pending"
  mv "$pending" "$gateway_env"
  trap - EXIT
fi

host_token=$(sed -n 's/^SP_HOST_TOKENS=//p' "$gateway_env")
[[ $host_token =~ ^[a-f0-9]{64}$ ]]
sudo opencomputer-box exec /bin/bash -c '
  set -euo pipefail
  read -r token
  if [[ -e $2 ]]; then
    if ! grep -Fxq "SP_GATEWAY_URL=$1" "$2" ||
        [[ $(sed -n "s/^SP_HOST_TOKEN=//p" "$2") != "$token" ]]; then
      printf "The Computer already has a different gateway configuration in %s.\n" "$2" >&2
      exit 1
    fi
  else
    umask 077
    pending=$(mktemp /etc/slack-presence/.host.env.XXXXXXXX)
    trap '\''unlink "$pending" 2>/dev/null || true'\'' EXIT
    printf "%s\n" "SP_GATEWAY_URL=$1" "SP_HOST_TOKEN=$token" SP_HOST_ID=opencomputer SP_LAUNCH=podman >"$pending"
    mv "$pending" "$2"
  fi
' bash "$host_url" "$host_env" <<<"$host_token"

if podman container exists "$container"; then
  if [[ $(podman inspect --format '{{.ImageName}}' "$container") != "$image" ]]; then
    printf 'The existing gateway container uses a different image.\n' >&2
    exit 1
  fi
  podman start "$container"
else
  if ! podman image exists "$image"; then
    podman build --build-arg "SP_VERSION=$version" --tag "$image" "$HOME/.local/share/opencomputer-gateway/source/computer"
  fi
  podman run -d --name "$container" --restart unless-stopped --security-opt no-new-privileges \
    --env-file "$gateway_env" --publish 127.0.0.1:3170:8080 --publish "$host_ip:3170:8080" \
    --volume opencomputer-gateway-data:/data "$image"
fi
sudo opencomputer-box exec systemctl enable --now slack-presence-host.service
REMOTE

for attempt in {1..30}; do
  health=$(curl --max-time 3 -fsS "$origin/healthz" 2>/dev/null || true)
  if [[ $health == *'"hosts":["opencomputer"]'* ]]; then break; fi
  sleep 1
done
if [[ $health != *'"hosts":["opencomputer"]'* ]]; then
  printf 'The gateway has not reported a connection from the Computer. Check %s/healthz and the host logs.\n' "$origin" >&2
  exit 1
fi
printf '%s\n\nOpen this private URL to connect Slack and configure a model.\n' "$health"
orble ssh "$box" 'origin=$(sed -n "s/^SP_ORIGIN=//p" "$HOME/.config/opencomputer/gateway.env")
  token=$(sed -n "s/^SETUP_TOKEN=//p" "$HOME/.config/opencomputer/gateway.env")
  printf "%s/setup?token=%s\n" "$origin" "$token"'
