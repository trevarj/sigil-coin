# SigilCoin deployment

This tooling runs the public testnet on a Docker Compose host or as a
foreground stack in the workspace. It also contains a guarded mainnet path,
but mainnet genesis remains non-final and mainnet is not approved for use. The
tooling does not publish DNS, configure firewalls, issue TLS certificates,
commit, push, or deploy unless an operator runs it.

> **Public exposure warning:** `P2P_BIND=0.0.0.0` with
> `TESTNET_EXPOSURE_ACK=public-testnet-approved` intentionally exposes an
> unauthenticated P2P service to the Internet. Review provider and host
> firewalls, resource limits, log rotation, monitoring, backups, and incident
> shutdown before selecting it.

## Public testnet reset boundary

The configured public testnet starts from a new genesis:

- marker `SigilCoin public testnet reset - 2026-09-02`,
- timestamp `1788307200` (`2026-09-02T00:00:00Z`),
- display id
  `15447f3226699f537969cbea4b493bbbe25a4d856832bf28bce3e7df579e6ddc`.

This is not an activation on the previous chain. Old public-testnet databases,
history, and backups of that state are incompatible; old-chain balances do not
carry over. The `d3 7a 91 c5` magic is intentionally unchanged, so a successful
frame handshake does not prove that a peer has the reset genesis.

Deployment scripts never delete operator data. Before deploying the reset to a
host that ran the old chain, stop every database user, take an offline archive
if desired, move the old `SIGIL_TESTNET_STATE_DIR` aside, and create a fresh
empty directory. Never open the old directory with the reset binary or restore
an old-chain backup into reset state. The exact non-destructive Docker cutover
is in [testnet.md](testnet.md#reset-cutover).

## Workspace and tools

Keep the three checkouts as siblings:

```text
workspace/
├── sigil/
├── sigil-bitcoin/
└── sigil-coin/
```

Docker builds require BuildKit and Docker Compose v2.17 or newer because the
build uses named `additional_contexts`. Local and remote helpers require Bash;
remote deployment also requires `ssh` and `rsync`. Use the workspace's pinned
Nix environment rather than installing tools globally.

The Compose project runs from `sigil-coin/deploy/docker`. Its main context is
`../..`; named contexts are `../../../sigil` and `../../../sigil-bitcoin`. The
image builds `deploy#sigilcoin`, exports its Nix closure, and contains
`sigilcoin`, `sigilcoin-explorer`, and the generated static site.

## Public testnet DNS and firewall

Create operator-owned DNS records with TTL 300 during initial rollout:

| Name | Type | Value |
| --- | --- | --- |
| `seed.testnet.sigilcoin.lol` | A | seed host public IPv4 address |
| `explorer.testnet.sigilcoin.lol` | A | seed host public IPv4 address (host reverse proxy) |

Both records resolve to the RackNerd seed host. The seed record must be DNS-only: do
not place a web CDN or HTTP proxy in front of P2P. No SRV record is needed,
because the node's canonical seed includes TCP port `19446`.

Add corresponding AAAA records only after validating the IPv6 node listener,
reverse proxy, provider firewall, host firewall, routing, and off-host probes.
Do not publish an AAAA record that reaches only HTTPS but not P2P, or vice
versa.

Apply separate provider and host firewall policy:

- public TCP/19446 to the testnet seed;
- public TCP/443 to the explorer's host reverse proxy;
- public TCP/80 only when the operator intentionally enables an HTTPS redirect
  or an ACME HTTP challenge;
- no public TCP/8080; Docker binds it to `127.0.0.1` only;
- SSH on its chosen port restricted independently to approved operator sources
  or a VPN.

Verify from outside the host network:

```sh
dig +short A seed.testnet.sigilcoin.lol
dig +short A explorer.testnet.sigilcoin.lol
nc -vz seed.testnet.sigilcoin.lol 19446
curl -fsS https://explorer.testnet.sigilcoin.lol/api/summary \
  | jq -e '.chain == "sigilcoin-testnet"'
```

When AAAA exists, repeat with IPv6 forced. Confirm an off-host connection to
TCP/8080 fails.

## Remote Docker host

Use a generic SSH hostname and a workspace owned by the login user:

```sh
ssh host.example 'sudo install -d -o "$USER" -g "$(id -gn)" -m 0750 /srv/sigilcoin'
cd /path/to/workspace/sigil-coin
cp deploy/docker/.env.example deploy/docker/.env
$EDITOR deploy/docker/.env
```

Set container identities from the host. The explorer UID must differ from the
node UID while sharing its GID:

```sh
export SIGIL_UID=$(ssh host.example id -u)
export SIGIL_GID=$(ssh host.example id -g)
export EXPLORER_UID=1001 # choose a numeric UID different from SIGIL_UID
export REMOTE_HOST=host.example
export REMOTE_DIR=/srv/sigilcoin
export MODE=testnet
export ENV_FILE=$PWD/deploy/docker/.env
bash deploy/scripts/deploy-remote.sh
```

The script validates configuration, rsyncs all three sibling working trees,
uploads the selected environment file separately with restrictive mode, then
builds and starts `compose.testnet.yml`. It excludes Git metadata, builds,
Sigil caches and state, deployment state/logs, and `.env`. It never commits or
pushes. A dirty working tree is intentionally deployable, so review `git status`
in all three checkouts first.

### Testnet exposure modes

The listener defaults to fail-closed loopback:

```sh
P2P_BIND=127.0.0.1
TESTNET_EXPOSURE_ACK=
REMOTE_PEER_IP=
```

Two and only two acknowledgements permit a non-loopback testnet bind.

Private one-peer allowlist mode:

```sh
P2P_BIND=0.0.0.0
TESTNET_EXPOSURE_ACK=peer-ip-allowlisted
REMOTE_PEER_IP=198.51.100.10
PEER=198.51.100.10:19446
```

Both provider and host firewalls must allow TCP/19446 only from that exact
peer address. If `PEER` is set, its host must equal `REMOTE_PEER_IP`.

Intentional public mode:

```sh
P2P_BIND=0.0.0.0
TESTNET_EXPOSURE_ACK=public-testnet-approved
REMOTE_PEER_IP=
PEER=seed.testnet.sigilcoin.lol:19446
```

Public mode does not require `REMOTE_PEER_IP`; the exact acknowledgement exists
to prove that the operator deliberately selected Internet exposure. Missing,
misspelled, or alternate acknowledgement values are rejected. The remote
preflight, local helper, and container entrypoint enforce the same modes.

The canonical node config already contains
`seed.testnet.sigilcoin.lol:19446`, so `PEER` is optional. Setting it makes the
outbound bootstrap target explicit.

### Status and logs

```sh
ssh host.example
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml ps
docker compose --env-file .env -f compose.testnet.yml logs -f --tail=100 listener sync explorer
docker compose --env-file .env -f compose.testnet.yml exec sync \
  /usr/local/bin/sigilcoin-entrypoint cli status
```

The sync service runs one bounded pass at a time and retries after
`SYNC_INTERVAL`. Container logs do not intentionally print wallet keys or the
environment. Operators must still review log retention, filesystem use,
restart counts, and public connection pressure.

Status reports branch-aware `issued-supply` from active UTXOs and the separate
height-only `scheduled-supply-cap`. Issued supply may trail that cap because a
solo block mints only `floor(4*S/5)` of scheduled subsidy; cooperative blocks
mint full scheduled subsidy and route fees and integer residuals to the
producer.

## Explorer reverse proxy and TLS

`compose.testnet.yml` hardcodes the host mapping to
`127.0.0.1:${EXPLORER_PORT:-8080}:8080`; there is no public bind override. Only
an operator-managed host reverse proxy should serve
`explorer.testnet.sigilcoin.lol` over TLS.

A Caddy site using certificate files already provisioned by the operator:

```caddyfile
explorer.testnet.sigilcoin.lol {
    tls /path/to/operator-managed/fullchain.pem /path/to/operator-managed/privkey.pem
    reverse_proxy 127.0.0.1:8080
}
```

A generic nginx site after the operator provisions certificate files:

```nginx
server {
    listen 443 ssl;
    server_name explorer.testnet.sigilcoin.lol;

    ssl_certificate     /path/to/operator-managed/fullchain.pem;
    ssl_certificate_key /path/to/operator-managed/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

These examples do not install, issue, or renew certificates. TLS policy and
proxy lifecycle remain operator-owned. Smoke-test `/`, `/blocks`,
`/difficulty`, `/api/summary`, `/api/blocks`, and `/api/difficulty` over HTTPS,
and verify direct off-host TCP/8080 remains closed.

## Local Nix loopback stack

From the `sigil-coin` checkout, join the public seed outbound while keeping
both local services on loopback:

```sh
nix develop .. -c env \
  MODE=testnet \
  BIN_DIR="$PWD/build/dev/bin" \
  PEER=seed.testnet.sigilcoin.lol:19446 \
  P2P_BIND=127.0.0.1 \
  P2P_PORT=19446 \
  EXPLORER_PORT=8080 \
  bash deploy/scripts/run-local.sh
```

The listener is reachable only at `127.0.0.1:19446`; the explorer is reachable
only at `http://127.0.0.1:8080/`. Omit `BIN_DIR` to let the helper build through
`deploy#sigilcoin` with the detected local sibling inputs. Ctrl-C terminates
the listener, explorer, and active sync/sleep child while preserving state.

The foreground helper runs all processes as the invoking user and cannot
provide Docker's node/explorer UID separation. Use it only on a trusted
single-user development host. To stop after a disconnected terminal:

```sh
MODE=testnet bash deploy/scripts/stop-local.sh
```

Default paths are under `deploy/state/local-testnet`,
`deploy/logs/local-testnet`, and `deploy/run/local-testnet`; they are ignored by
Git.

## State and permissions

Compose mounts testnet state from `SIGIL_TESTNET_STATE_DIR` (default
`./state/testnet`) and mainnet from separate `SIGIL_MAINNET_STATE_DIR`. The
deploy script creates the selected directory mode `0750`. Listener and sync run
as `SIGIL_UID:SIGIL_GID` with umask `0027`; explorer runs as a distinct
`EXPLORER_UID` with the shared GID and receives a read-only state mount.

SQLite database, WAL, SHM, and journal files are normalized to `0640` so the
explorer can read them. Keep `wallet/` at `0700` and `wallet/wallet.key` at
`0600`, owned by `SIGIL_UID`; the explorer UID must not read them. Wallet keys,
backups, and unrevealed commitments remain secrets even though test coins are
worthless. Never use production keys on testnet.

## Backups

Stop all database users before a filesystem backup:

```sh
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml stop
install -d -m 0700 "$HOME/sigilcoin-testnet-backups"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
state_dir=${SIGIL_TESTNET_STATE_DIR:-"$PWD/state/testnet"}
[[ $state_dir == /* ]] || state_dir=$PWD/${state_dir#./}
tar -C "$state_dir" -czf "$HOME/sigilcoin-testnet-backups/$stamp.tgz" .
chmod 0600 "$HOME/sigilcoin-testnet-backups/$stamp.tgz"
sha256sum "$HOME/sigilcoin-testnet-backups/$stamp.tgz" \
  >"$HOME/sigilcoin-testnet-backups/$stamp.tgz.sha256"
docker compose --env-file .env -f compose.testnet.yml up -d
```

A live `cp` or `tar` may capture torn SQLite state. Store backups encrypted and
offline; never commit them or rsync them into source. Restore only a backup
whose recorded genesis matches the current chain, into an empty location.
Start sync before explorer so SQLite can recover normally, then compare reset
genesis, status, issued supply, and balance with an independent node.

## Upgrade and rollback

Before an upgrade, stop database users, take a verified backup, and preserve
the current image under a rollback tag:

```sh
cd /srv/sigilcoin/sigil-coin/deploy/docker
current_image=$(docker compose --env-file .env -f compose.testnet.yml config --images | sort -u)
[[ -n $current_image && $current_image != *$'\n'* ]] || { echo 'expected one image' >&2; exit 1; }
rollback_image=${SIGIL_ROLLBACK_IMAGE:-sigilcoin-local:testnet-rollback}
docker image tag "$current_image" "$rollback_image"
```

After deploying the reviewed source, compare node status, resource use, public
P2P, and explorer summary with the baseline. To recreate from a schema-compatible
rollback image without rebuilding:

```sh
SIGIL_IMAGE="$rollback_image" docker compose --env-file .env \
  -f compose.testnet.yml up -d --no-build --force-recreate
```

An image rollback does not migrate or restore state. Both database schema and
genesis must be compatible. Never roll a reset node back onto previous-testnet
state; if compatibility is uncertain, preserve the current directory and
restore a matching reset-genesis backup into an empty location. An incident or
testnet success does not authorize a mainnet push or deployment.

## Mainnet placeholder

Mainnet uses port `19444`, separate state, and loopback explorer port `8081`.
Its current coherent placeholder genesis was regenerated with the tightened
witness source, but its launch timestamp and resulting final constants remain
non-final. Both helper scripts and every container refuse mainnet unless the
operator sets exactly `ALLOW_MAINNET=yes`.

```sh
ALLOW_MAINNET=yes MODE=mainnet bash deploy/scripts/run-local.sh
ALLOW_MAINNET=yes MODE=mainnet REMOTE_HOST=host.example \
  REMOTE_DIR=/srv/sigilcoin bash deploy/scripts/deploy-remote.sh
```

These commands document the future safety gate; they are not launch approval.
The public testnet must complete its day-30 gate before the separate mainnet
soak can begin. See [testnet.md](testnet.md) and [LAUNCH.md](../LAUNCH.md).
