# OpenComputer on Orble

An Orble box can host one organization's OpenComputer runtime. The Computer connects to a gateway over an outbound WebSocket and runs each session in its own rootless Podman container. Use an existing OpenComputer gateway or run the standalone Slack gateway on the same box.

Orble boots the VM with tini. OpenComputer's host uses systemd user units to start and limit rootless Podman sessions. The launcher starts that systemd environment inside the box and mounts ext4 storage at `/data` for the session images and workspaces. It also blocks requests from the Computer to Orble's Self API, which authorizes requests based on the calling box.

## Run the standalone Slack gateway on Orble

From a committed checkout, run these commands. Replace `U0123456789` with the Slack member ID allowed to start sessions. The release builder needs Go and an authenticated GitHub CLI to verify the session image attestation.

```bash
orble new -s m --name opencomputer &&
  computer/deploy/orble/setup-slack.sh opencomputer U0123456789
```

The script builds the upstream [gateway image](../../Dockerfile) from the committed checkout and runs it with rootless Podman. Podman publishes the gateway on loopback for Orble's HTTPS shared port and on the Computer's private link for its outbound WebSocket. The SQLite database is stored in a Podman volume on the ext4 disk. The script grants the gateway's Linux user access to `/dev/net/tun` for Podman's network and keeps the gateway configuration in `~/.config/opencomputer/gateway.env` with mode `0600`.

Orble can wake a suspended box on a shared-port request. Slack expects an HTTP acknowledgement within three seconds, so enable **Keep awake** if your gateway needs to answer every request within that window. After a cold boot, rerun `setup-slack.sh` with the same checkout and member ID to start the host and the saved gateway container.

### Install the Slack app

1. Open the private setup URL printed by the script.
2. On the [Slack app settings page](https://api.slack.com/apps), expand **Your App Configuration Tokens** and generate a token for the workspace that will use OpenComputer. Copy the refresh token, which starts with `xoxe-1-`, into the gateway's setup page and select **Create the Slack app**.
3. Select **Point the app at this origin** to register the Slack events, interactivity, and OAuth callback URLs. The gateway can reuse the refresh token from the previous step.
4. Follow **Install the app into the workspace**. Verify the workspace shown in Slack before selecting **Allow**. Return to the setup page and check that the Slack app is marked **installed** and shows the expected workspace ID.

### Configure a model

For Claude Code, run `claude setup-token` on your workstation and open the authorization page in the browser profile signed in to the intended Claude account. Enter the one-time code in the CLI, then paste the full setup token into **Claude credential** on the gateway. A terminal may display the token on multiple lines. Copy it as a single continuous value. The setup page also accepts an Anthropic API key.

Codex uses `OPENAI_API_KEY` in the gateway container's environment and starts a new Slack task with `+codex`. See the [Calvin README](../../README.md#running-it-for-a-team) for model routing details.

### Verify Slack delivery

Retrieve the public address and check the gateway. The response should list `opencomputer` under `hosts` and report `"mode":"slack"` once Slack is installed.

```bash
gateway_origin=$(orble port opencomputer | awk '$1 == 3170 { print $3 }')
curl -fsS "$gateway_origin/healthz"
```

Send Computer a direct message from the Slack account you supplied to the script. Ask it to write and run a shell script that prints the current UTC time. The thread should show the task and its output.

If Slack shows `401 OAuth access token is invalid` after a runner starts, check that the Claude setup token was copied in full and save it again. Start a new Slack thread to verify the new credential. Use these commands to check the container and host logs.

```bash
orble ssh opencomputer 'podman --root /.oldroot/mnt/opencomputer-gateway/storage logs --tail 50 opencomputer-gateway'
orble ssh opencomputer 'sudo opencomputer-box exec journalctl -u slack-presence-host -n 50 --no-pager'
```

## Use a Cloudflare gateway

The Cloudflare gateway can acknowledge and queue Slack events while the Computer is offline. The Computer opens the connection outbound, and the Worker delivers queued work when it reconnects. In self-managed mode, Orble controls when the box wakes.

### Prepare a box and a release

Create a dedicated box with at least 8 GiB of RAM. Use `orble ssh` with the box name to copy the launcher and initialize Debian. The examples use the name `opencomputer`.

```bash
orble new -s m --name opencomputer
orble ssh opencomputer 'sudo install -m 0755 /dev/stdin /usr/local/sbin/opencomputer-box' \
  < computer/deploy/orble/box.sh
orble ssh opencomputer 'sudo opencomputer-box init'
orble ssh opencomputer 'sudo sh -c "nohup opencomputer-box start </dev/null >/var/log/opencomputer-box.log 2>&1 &"'
orble ssh opencomputer 'timeout 30 sh -c "until test -f /run/orble-opencomputer.ready; do sleep 1; done"'
```

Build the release from a committed checkout on your workstation. Go builds the model proxy, and an authenticated GitHub CLI verifies the upstream session image attestation before the release records the image digest.

```bash
computer/deploy/orble/build-release.sh /tmp/opencomputer.bundle
orble ssh opencomputer 'sudo opencomputer-box exec install -d -m 0755 /opt/bootstrap'
orble ssh opencomputer 'sudo opencomputer-box exec install -m 0644 /dev/stdin /opt/bootstrap/calvin.bundle' \
  < /tmp/opencomputer.bundle
orble ssh opencomputer 'sudo opencomputer-box exec git clone --branch main /opt/bootstrap/calvin.bundle /opt/bootstrap/calvin-src'
orble ssh opencomputer 'sudo opencomputer-box exec env CLOUD=none FORMAT_IF_BLANK=0 BLOCK_METADATA_ALL=1 REPO_URL=/opt/bootstrap/calvin.bundle bash /opt/bootstrap/calvin-src/deploy/vm/provision.sh'
```

### Connect the gateway

Follow OpenComputer's [self-hosting guide](../../../docs/self-hosting/overview.mdx) to deploy the gateway with `COMPUTER_VMS=self-managed`. Use the organization's host token and gateway URL to make a local `opencomputer-host.env` file with the following values. Keep the file private.

```dotenv
SP_GATEWAY_URL=wss://<gateway>/api/machine/host?organizationId=<encoded-organization-id>
SP_HOST_TOKEN=<organization-host-token>
SP_HOST_ID=<organization-id>
SP_LAUNCH=podman
```

```bash
orble ssh opencomputer 'sudo opencomputer-box exec install -m 0600 /dev/stdin /etc/slack-presence/host.env' \
  < opencomputer-host.env
orble ssh opencomputer 'sudo opencomputer-box exec systemctl enable --now slack-presence-host.service slack-presence-wire.service'
orble ssh opencomputer 'sudo opencomputer-box exec journalctl -u slack-presence-host -n 30 --no-pager'
```

The Computer should appear online in OpenComputer. Enable **Keep awake** in Orble for a box that needs to receive new work through its gateway connection. If Orble cold-boots the VM, rerun the launcher command to bring systemd and the host service back up.
