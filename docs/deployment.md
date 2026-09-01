# SigilCoin deployment

This tooling runs the current private 30-day testnet on a Docker Compose host
or as a foreground stack on a local NixOS machine. It also contains a guarded
mainnet path, but mainnet genesis is non-final and that path is not approved for
use. The tooling does not publish DNS, terminate TLS, commit, or push Git.

## Workspace and tool requirements

Keep the three checkouts as siblings:

```text
workspace/
├── sigil/
├── sigil-bitcoin/
└── sigil-coin/
```

Docker builds require BuildKit and Docker Compose v2.17 or newer because the
build uses named `additional_contexts`. Local and remote helper scripts require
Bash; remote deployment also requires `ssh` and `rsync`. The Compose project
is run from
`sigil-coin/deploy/docker`; its main context is `../..`, and its named contexts
are `../../../sigil` and `../../../sigil-bitcoin`. The image builds
`deploy#sigilcoin` with both local inputs overridden, exports the complete Nix
closure, and imports it into the runtime image. It contains `sigilcoin`,
`sigilcoin-explorer`, and the generated static site at
`/opt/sigilcoin/share/sigilcoin-site`. The static site is not exposed by this
private stack.

No apt, brew, global npm, or global pip install is part of either workflow.

Direct use of `deploy/flake.nix` assumes revision-pinned `sigil` and
`sigil-bitcoin` clones at `/workspace`. `run-local.sh` and the Docker build do
not depend on those defaults: they override both inputs from the detected
sibling layout shown above.

## Remote Docker host private testnet

The examples use the neutral SSH host or alias `your-remote-host`. On first
use, create a remote workspace owned by the login user:

```sh
ssh your-remote-host 'sudo install -d -o "$USER" -g "$(id -gn)" -m 0750 /srv/sigilcoin'
cd /path/to/workspace/sigil-coin
cp deploy/docker/.env.example deploy/docker/.env
$EDITOR deploy/docker/.env
```

Set `PEER` to the other approved machine's fixed `IP:19446`. Set the numeric
container identity from the remote host rather than assuming 1000:

```sh
export SIGIL_UID=$(ssh your-remote-host id -u)
export SIGIL_GID=$(ssh your-remote-host id -g)
export EXPLORER_UID=1001 # choose a numeric UID different from SIGIL_UID
export REMOTE_HOST=your-remote-host
export REMOTE_DIR=/srv/sigilcoin
export MODE=testnet
export ENV_FILE=$PWD/deploy/docker/.env
bash deploy/scripts/deploy-remote.sh
```

The script rsyncs all three sibling working trees, excluding `.git`, `build`,
`.sigil`, `.sigilcoin`, `.sigilcoin-testnet`, `result*`, deployment state,
logs, and `.env`; uploads the selected
environment file separately; then runs:

```sh
docker compose --env-file .env -f compose.testnet.yml build
docker compose --env-file .env -f compose.testnet.yml up -d --remove-orphans
```

It never commits or pushes Git. A dirty local working tree is intentionally
deployed, so review `git status` in all three
checkouts before running it.

### Network boundary

The testnet listener defaults to host bind `127.0.0.1:19446`. To accept the
other approved node, set all three values below; deployment and the container
fail closed if any acknowledgement is absent or malformed:

```sh
P2P_BIND=0.0.0.0
TESTNET_EXPOSURE_ACK=peer-ip-allowlisted
REMOTE_PEER_IP=OTHER_NODE_FIXED_IPV4
```

At both the provider firewall and host firewall, allow TCP/19446 **only from
that exact IPv4 address**. Never allow `0.0.0.0/0`. If `PEER` is set while the
listener is exposed, its host must equal `REMOTE_PEER_IP`. There are no seed
peers.

The testnet Compose mapping hardcodes the explorer host bind to
`127.0.0.1:8080`; there is no public bind override. Do not create public DNS or
add TLS during the private test. Reach it through SSH:

```sh
ssh -N -L 18080:127.0.0.1:8080 your-remote-host
# Open http://127.0.0.1:18080/ locally.
```

### Status and logs

```sh
ssh your-remote-host
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml ps
docker compose --env-file .env -f compose.testnet.yml logs -f --tail=100 listener sync explorer
docker compose --env-file .env -f compose.testnet.yml exec sync \
  /usr/local/bin/sigilcoin-entrypoint cli status
```

The sync service runs one bounded pass at a time and retries after
`SYNC_INTERVAL`; a failed peer attempt does not expose secrets. Container logs
never intentionally print wallet keys or environment contents.

## Local NixOS foreground stack

From `sigil-coin`, build through the deployment flake and keep the stack in the
current terminal:

```sh
cd /path/to/workspace/sigil-coin
MODE=testnet \
PEER=REMOTE_FIXED_IPV4:19446 \
P2P_BIND=LOCAL_PRIVATE_IPV4 \
REMOTE_PEER_IP=REMOTE_FIXED_IPV4 \
TESTNET_EXPOSURE_ACK=peer-ip-allowlisted \
bash deploy/scripts/run-local.sh
```

Omit `PEER` until the remote listener is ready. For loopback-only use, omit
both `PEER` and `P2P_BIND`; the listener then defaults to `127.0.0.1:19446`.
The explorer always binds `127.0.0.1:8080`. Ctrl-C terminates listener,
explorer, and the active sync or sleep child promptly while preserving state.
The foreground helper runs all three processes as the invoking user, so it
cannot provide Docker's node/explorer UID separation. Use it only on a trusted
single-user development host; the wallet's 0700/0600 modes do not isolate the
explorer process when both have the same UID.

The script builds `path:$PWD?dir=deploy#sigilcoin` with overrides to
`../sigil` and `../sigil-bitcoin`. To use an already built source tree:

```sh
BIN_DIR=$PWD/build/dev/bin MODE=testnet bash deploy/scripts/run-local.sh
```

State, logs, and PID files default to:

```text
deploy/state/local-testnet/
deploy/logs/local-testnet/
deploy/run/local-testnet/
```

They are gitignored. In another terminal, inspect status and logs with:

```sh
out=$(nix --extra-experimental-features 'nix-command flakes' build \
  "path:$PWD?dir=deploy#sigilcoin" \
  --override-input sigil "path:$(dirname "$PWD")/sigil" \
  --override-input sigil-bitcoin "path:$(dirname "$PWD")/sigil-bitcoin" \
  --no-link --print-out-paths)
"$out/bin/sigilcoin" status --testnet --data-dir "$PWD/deploy/state/local-testnet"
tail -F deploy/logs/local-testnet/{listener,sync,explorer}.log
```

If the foreground terminal was disconnected instead of receiving Ctrl-C:

```sh
MODE=testnet bash deploy/scripts/stop-local.sh
```

## State, permissions, and backups

Compose bind mounts testnet state from `SIGIL_TESTNET_STATE_DIR` (default
`deploy/docker/state/testnet`) and mainnet from a separate
`SIGIL_MAINNET_STATE_DIR` (default `deploy/docker/state/mainnet`). The deploy
script creates the selected directory mode 0750. Listener and sync run as
`SIGIL_UID:SIGIL_GID` with umask 0027; explorer runs as the distinct
`EXPLORER_UID` with the shared `SIGIL_GID`, and its state bind mount is
read-only. Deployment safely normalizes existing SQLite DB, WAL, SHM, and
journal files to 0640 so explorer can read them. For a custom path, create it on
the remote host before deployment and make it owned by
`SIGIL_UID:SIGIL_GID`. Keep `wallet/` mode 0700 and `wallet/wallet.key` mode
0600 and owned by `SIGIL_UID`; explorer's distinct UID must never be able to
read them. The wallet key and unrevealed commitment material are secrets even
on disposable testnet.

Take a plain filesystem backup only with all database users stopped:

```sh
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml stop
install -d -m 0700 "$HOME/sigilcoin-backups"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
# Set this to SIGIL_TESTNET_STATE_DIR from .env; the default is shown.
state_dir=${SIGIL_TESTNET_STATE_DIR:-"$PWD/state/testnet"}
[[ $state_dir == /* ]] || state_dir=$PWD/${state_dir#./}
tar -C "$state_dir" -czf "$HOME/sigilcoin-backups/testnet-$stamp.tgz" .
chmod 0600 "$HOME/sigilcoin-backups/testnet-$stamp.tgz"
docker compose --env-file .env -f compose.testnet.yml up -d
```

A live `cp` or `tar` can capture a torn SQLite database. Store backups encrypted
and offline; never commit or rsync them back into a source checkout.

## Upgrade and rollback

Before an upgrade, stop database users and take a backup as above. Confirm the
older binary is schema-compatible with the current database; an image rollback
does not migrate or restore state. Then preserve the currently selected image
on the remote Docker host:

```sh
ssh your-remote-host
cd /srv/sigilcoin/sigil-coin/deploy/docker
# `config --images` resolves SIGIL_IMAGE from the shell or .env.
current_image=$(docker compose --env-file .env -f compose.testnet.yml config --images | sort -u)
[[ -n $current_image && $current_image != *$'\n'* ]] || { echo 'expected one SigilCoin image' >&2; exit 1; }
rollback_image=${SIGIL_ROLLBACK_IMAGE:-sigilcoin-local:testnet-rollback}
docker image tag "$current_image" "$rollback_image"
```

Review all three working trees, rerun `deploy-remote.sh`, then compare node
status and explorer summary. State is not deleted by rsync or Compose.

To roll back the image without rebuilding or changing state:

```sh
ssh your-remote-host
cd /srv/sigilcoin/sigil-coin/deploy/docker
rollback_image=${SIGIL_ROLLBACK_IMAGE:-sigilcoin-local:testnet-rollback}
SIGIL_IMAGE="$rollback_image" docker compose --env-file .env \
  -f compose.testnet.yml up -d --no-build --force-recreate
```

For a source rollback, restore a reviewed local snapshot of all three sibling
checkouts and rerun the deployment script. Do not use this workflow as a reason
to push unpublished code.

## Mainnet placeholder

Mainnet files exist for future operations, use port 19444, use separate state,
and default the explorer host port to loopback `8081`. **The final mainnet
genesis is non-final. Do not run them now.** Both scripts and every container
refuse mainnet unless the operator explicitly sets the exact value:

```sh
ALLOW_MAINNET=yes MODE=mainnet bash deploy/scripts/run-local.sh
ALLOW_MAINNET=yes MODE=mainnet REMOTE_HOST=your-remote-host \
  REMOTE_DIR=/srv/sigilcoin bash deploy/scripts/deploy-remote.sh
```

Those commands document the future safety gate; they are not launch approval.
The present scope remains the disposable private testnet for 30 days, with only
the two approved peer IPs and no public explorer, DNS, TLS, seed discovery, or
automated Git push.
