# OpenComputer on Orble

An Orble box can host one organization's OpenComputer runtime. The gateway and app still run where you deploy them. The Computer connects to the gateway over an outbound WebSocket and runs each session in its own rootless Podman container.

Orble boots the VM with tini. The launcher below starts a Debian systemd environment inside that VM so OpenComputer can use its usual systemd runner units and cgroup limits. It mounts a directory from the box's ext4 disk at `/data` for Podman images and workspaces.

## Prepare a box and a release

Create a dedicated box with at least 8 GiB of RAM. From a machine with SSH access to the box, copy the launcher and initialize Debian. Replace `<box-host>` with the hostname printed by `orble new`.

```bash
orble new -s m --name opencomputer
ssh <box-host> 'sudo install -m 0755 /dev/stdin /usr/local/sbin/opencomputer-box' \
  < computer/deploy/orble/box.sh
ssh <box-host> 'sudo opencomputer-box init'
ssh <box-host> 'sudo sh -c "nohup opencomputer-box start </dev/null >/var/log/opencomputer-box.log 2>&1 &"'
ssh <box-host> 'timeout 30 sh -c "until test -f /run/orble-opencomputer.ready; do sleep 1; done"'
```

Build the release from a committed checkout on your workstation. Go builds the model proxy, and an authenticated GitHub CLI verifies the upstream session image attestation before the release records the image digest.

```bash
computer/deploy/orble/build-release.sh /tmp/opencomputer.bundle
ssh <box-host> 'sudo opencomputer-box exec install -d -m 0755 /opt/bootstrap'
ssh <box-host> 'sudo opencomputer-box exec install -m 0644 /dev/stdin /opt/bootstrap/calvin.bundle' \
  < /tmp/opencomputer.bundle
ssh <box-host> 'sudo opencomputer-box exec git clone --branch main /opt/bootstrap/calvin.bundle /opt/bootstrap/calvin-src'
ssh <box-host> 'sudo opencomputer-box exec env CLOUD=none FORMAT_IF_BLANK=0 BLOCK_METADATA_ALL=1 REPO_URL=/opt/bootstrap/calvin.bundle bash /opt/bootstrap/calvin-src/deploy/vm/provision.sh'
```

## Connect the gateway

Follow OpenComputer's [self-hosting guide](../../../docs/self-hosting/overview.mdx) to deploy the gateway with `COMPUTER_VMS=self-managed`. Use the organization's host token and gateway URL to make a local `opencomputer-host.env` file with the following values. Keep the file private.

```dotenv
SP_GATEWAY_URL=wss://<gateway>/api/machine/host?organizationId=<encoded-organization-id>
SP_HOST_TOKEN=<organization-host-token>
SP_HOST_ID=<organization-id>
SP_LAUNCH=podman
```

```bash
ssh <box-host> 'sudo opencomputer-box exec install -m 0600 /dev/stdin /etc/slack-presence/host.env' \
  < opencomputer-host.env
ssh <box-host> 'sudo opencomputer-box exec systemctl enable --now slack-presence-host.service slack-presence-wire.service'
ssh <box-host> 'sudo opencomputer-box exec journalctl -u slack-presence-host -n 30 --no-pager'
```

The Computer should appear online in OpenComputer. Enable **Keep awake** in Orble for a box that needs to receive new work through its gateway connection. If Orble cold-boots the VM, rerun the launcher command to bring systemd and the host service back up.

## Run the standalone Slack gateway on Orble

The standalone Slack gateway can run alongside the Computer on the same box. Slack sends HTTPS callbacks to an Orble shared port. The Computer connects to the gateway over its local loopback interface, and the gateway stores Slack credentials and session routing in SQLite under `/var/lib/opencomputer-gateway`.

1. Enable **Keep awake**, then share the port with `orble port <box> 3170 --public`. Use the resulting HTTPS address as `SP_ORIGIN`.
2. Inside the Computer, create the system user and group `sp-gateway` and install `opencomputer-gateway.service` in `/etc/systemd/system/`. In the root-only `/etc/slack-presence/gateway.env`, set `PORT=3170`, `SP_ORIGIN`, and `SP_DB=/var/lib/opencomputer-gateway/gateway.db`. Generate a separate random value for each of `SP_STORE_KEY`, `SETUP_TOKEN`, and `SP_HOST_TOKENS` with `openssl rand -hex 32`. Set `SP_PEOPLE` to the JSON list of Slack users allowed to start sessions.
3. In the Computer's `/etc/slack-presence/host.env`, set `SP_GATEWAY_URL=ws://127.0.0.1:3170/host`, `SP_LAUNCH=podman`, a stable `SP_HOST_ID`, and `SP_HOST_TOKEN` to the value of `SP_HOST_TOKENS`. Enable and start `opencomputer-gateway.service` and `slack-presence-host.service`.
4. In the outer Orble box, install `socat` and place the executable `40-opencomputer-slack` in `/etc/orble/on-resume.d/`. Run it once to connect Orble's shared port to the Computer. On resume, the hook checks whether the Computer needs to start and restores the port bridge.
5. Use the gateway's protected `/setup` page to configure Slack and the model credential. The [Calvin README](../../README.md#running-it-for-a-team) describes the gateway, host, and credential setup.

The gateway's `/healthz` lists connected hosts. After installing the Slack app, send it a direct message from an allowed account to verify that the gateway can start a session and deliver its reply.
