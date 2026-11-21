# OpenComputer on Orble

An Orble box can host one organization's OpenComputer runtime. The Computer connects to a gateway over an outbound WebSocket and runs each session in its own rootless Podman container. Use an existing OpenComputer gateway or run the standalone Slack gateway on the same box.

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

An `SP_PEOPLE` entry maps a Slack user ID to a Computer account. Set the value on a single line in `gateway.env`:

```dotenv
SP_PEOPLE='[{"slackUserId":"<slack-user-id>","dir":"operator","gitName":"Operator","gitEmail":"operator@example.com"}]'
```

### Install the Slack app

1. Open `https://<orble-shared-port>/setup?token=<SETUP_TOKEN>` in a private browser tab. Use the HTTPS address from step 1 and keep the setup URL private.
2. On the [Slack app settings page](https://api.slack.com/apps), expand **Your App Configuration Tokens** and generate a token for the workspace that will use OpenComputer. Copy the refresh token, which starts with `xoxe-1-`, into the gateway's setup page and select **Create the Slack app**.
3. Select **Point the app at this origin** to register the Slack events, interactivity, and OAuth callback URLs. The gateway can reuse the refresh token from the previous step.
4. Follow **Install the app into the workspace**. Verify the workspace shown in Slack before selecting **Allow**. Return to the setup page and check that the Slack app is marked **installed** and shows the expected workspace ID.

### Configure a model

For Claude Code, run `claude setup-token` on your workstation and open the authorization page in the browser profile signed in to the intended Claude account. Enter the one-time code in the CLI, then paste the full setup token into **Claude credential** on the gateway. A terminal may display the token on multiple lines. Copy it as a single continuous value. The setup page also accepts an Anthropic API key.

To enable Codex, set `OPENAI_API_KEY` in the gateway's root-only `gateway.env`, restart `opencomputer-gateway.service`, and start a new Slack task with `+codex`. Follow-up replies use the model selected for that session. See the [Calvin README](../../README.md#running-it-for-a-team) for model routing details.

### Verify Slack delivery

Check `https://<orble-shared-port>/healthz` for `"mode":"slack"` and the expected host ID in `hosts`. Then send Computer a direct message from an account listed in `SP_PEOPLE`. For example, ask it to write and run a shell script that prints the current UTC time. The thread should show the completed task and its output.

If Slack shows `401 OAuth access token is invalid` after a runner starts, check that the Claude setup token was copied in full and save it again. Start a new Slack thread to verify the new credential. For connection problems, check the gateway and host journals inside the Computer:

```bash
ssh <box-host> 'sudo opencomputer-box exec journalctl -u opencomputer-gateway -u slack-presence-host -n 50 --no-pager'
```
