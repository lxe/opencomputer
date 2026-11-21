# OpenComputer on Orble

One Orble box can run both the OpenComputer host and its Slack gateway. Slack sends callbacks to the box's shared HTTPS port. The Computer connects to the gateway over a private link and runs each session in its own rootless Podman container.

## Run the standalone Slack gateway on Orble

Run these commands from the repository root of a committed checkout. You'll need the Orble CLI signed in to an account that can publish a port, Go, and an authenticated GitHub CLI to verify the session image attestation. Replace `U0123456789` with the Slack member ID allowed to start sessions.

```bash
orble new -s m --name opencomputer &&
  computer/deploy/orble/setup-slack.sh opencomputer U0123456789
```

The installer builds the [gateway image](../../Dockerfile) and runs it with rootless Podman. It creates a private setup URL and waits for the Computer to connect. Gateway credentials are stored in `~/.config/opencomputer/gateway.env` on the box with mode `0600`. The gateway database lives in a Podman volume on the ext4 disk.

Orble wakes a suspended box when Slack calls its shared port. Leave **Keep awake** off for normal sleep and wake. Enable it if wake latency causes callbacks to miss [Slack's three-second acknowledgement window](https://docs.slack.dev/apis/events-api/#responding). If a cold boot leaves the services stopped, rerun `setup-slack.sh` from the same commit with the same box name and Slack member ID.

### Install the Slack app

1. Open the setup URL printed by the installer. Keep that URL private.
2. On the [Slack app settings page](https://api.slack.com/apps), expand **Your App Configuration Tokens** and generate a token for the workspace that will use OpenComputer. Copy the refresh token, which starts with `xoxe-1-`, into the gateway's setup page and select **Create the Slack app**.
3. Select **Point the app at this origin** to register the Slack events, interactivity, and OAuth callback URLs. The gateway can reuse the refresh token from the previous step.
4. Follow **Install the app into the workspace**. Verify the workspace shown in Slack before selecting **Allow**. Return to the setup page and check that the Slack app is marked **installed** and shows the expected workspace ID.

### Configure a model

For Claude Code, run `claude setup-token` on your workstation and open the authorization page in the browser profile signed in to the intended Claude account. Enter the one-time code in the CLI, then paste the full setup token into **Claude credential** on the gateway. A terminal may display the token on multiple lines. Copy it as a single continuous value. The setup page also accepts an Anthropic API key.

To use Codex, configure `OPENAI_API_KEY` in the gateway container's environment at creation and start a new Slack task with `+codex`. See the [Calvin README](../../README.md#running-it-for-a-team) for model routing details.

### Verify Slack delivery

Retrieve the public address and check the gateway. The response lists `opencomputer` under `hosts`. It reports `"mode":"setup"` on a fresh install and switches to `"mode":"slack"` when the Slack app credentials are configured.

```bash
gateway_origin=$(orble port opencomputer | awk '$1 == 3170 { print $3 }')
curl -fsS "$gateway_origin/healthz"
```

Confirm the setup page marks the Slack app as installed, then send Computer a direct message from the Slack account you supplied to the installer. Ask it to write and run a shell script that prints the current UTC time. The thread should show the task and its output.

If Slack shows `401 OAuth access token is invalid` after a runner starts, check that the Claude setup token was copied in full and save it again. Start a new Slack thread to verify the new credential. Use these commands to check the container and host logs.

```bash
orble ssh opencomputer 'podman --root /.oldroot/mnt/opencomputer-gateway/storage logs --tail 50 opencomputer-gateway'
orble ssh opencomputer 'sudo opencomputer-box exec journalctl -u slack-presence-host -n 50 --no-pager'
```

### How the box runs OpenComputer

Orble boots with tini. The launcher starts the systemd environment that OpenComputer uses to manage runner units and resource limits, and mounts ext4 storage at `/data` for session images and workspaces. It gives the runner user access to the TUN device for rootless Podman and blocks the Computer from reaching Orble's box-scoped Self API. Podman binds the gateway to loopback for the shared port and to the private link for the Computer's outbound WebSocket.

## Optional Cloudflare gateway

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
SP_GATEWAY_URL=wss://<gateway-worker-host>/v1/computer/host?organizationId=<encoded-organization-id>
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

The Computer should appear online in OpenComputer. A Slack event in the Worker does not call the Orble shared port. Enable **Keep awake** if you want the Computer to process queued work immediately, or use `orble resume opencomputer` when a sleeping box should reconnect. If a cold boot leaves systemd stopped, rerun the launcher command from **Prepare a box and a release**.
