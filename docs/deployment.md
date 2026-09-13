# SigilCoin deployment

This tooling runs replacement proof-of-golf networks from height 0 on a Docker
Compose host or as a foreground stack in the workspace. Mainnet activation
requires explicit exposure acknowledgements and an operator-controlled Caddy
cutover. The tooling does not publish DNS, configure firewalls, issue TLS
certificates, commit, or push.

> **Public exposure warning:** `P2P_BIND=0.0.0.0` with
> `TESTNET_EXPOSURE_ACK=public-testnet-approved` exposes unauthenticated P2P,
> while Caddy exposes the bounded co-op relay. Review provider and host
> firewalls, resource limits, rate pressure, log rotation, monitoring, backups,
> and incident shutdown before selecting them. The relay's authentication and
> limits do not prevent Sybil slot filling or guarantee inclusion.

## Replacement-network boundary

The launched nonce-PoW mainnet was retired before height 1 because its compute
burn contradicted the project's intent. Its launch identity and evidence remain
historical and superseded in [LAUNCH.md](../LAUNCH.md); they are not the identity
of this replacement. Mainnet, public testnet, and regtest began again at height
0 with the proof-of-golf genesis constants from `deploy/genesis-constants.sgl`.
Compare the reviewed output for the exact build before connecting peers; a
matching chain name, port, address prefix, or wire magic is not enough.

Every valid producer program still satisfies `L <= par` in the puzzle VM.
Its displayed score is `1 + min(8, max(0, par - L))`, from 1 at par to 9;
genesis contributes 0. Score measures competition quality, not fork choice,
and currently does not alter subsidy. Only a strictly taller valid branch
replaces the active chain. Equal height retains the durable active incumbent
across restart; score, hash, and arrival metadata do not break ties.

Chain configs hardcode `(height . internal-hash)` checkpoints. Incompatible
branches cannot cross a checkpoint. Checkpoints advance only in reviewed
software releases, not automatically or through signed broadcasts; operators
must upgrade nodes to share a newer checkpoint. Mainnet now pins H0 and the
live H1 block; public testnet and regtest still pin H0 only, protecting genesis
but no later history. Mainnet rejects reorgs below H1; reorgs above H1 remain
possible.

Mainnet H1 internal hash:
`24f2cbbf4a5dbbce67abbcc047e300cda17c600e7ab3565846d27a0eb6b041d2`.
Its reversed display ID is
`d241b0b60e7ad2465856b37a0e607ca1cd00e347c0bcab67cebb5d4abfcbf224`.

This cutover preserves proof-of-golf block bytes, genesis hashes, and genesis
timestamps. Transport magic changes to `SGM3` / `SGT3` / `SGR3` on mainnet /
testnet / regtest to isolate older score-ranked nodes. Existing proof-of-golf
H0 state may be reused; retired nonce-PoW state must stay archived. A node
refuses to open active history that conflicts with an installed checkpoint
rather than silently rewriting it. Preserve the database and compare the
reviewed release's checkpoints when diagnosing such a refusal.

Each header timestamp must equal `parent.time + network spacing` and must not
be in the validating node's future. Mainnet spacing is exactly 86,400 seconds;
test networks retain their configured shorter slots. The 80-byte header stays,
but nonce is zero and `bits` is fixed at the network's pow-limit compatibility
value, not a hash target. Non-genesis coinbase lock-time is zero, graffiti is
empty, and coinbase sequence/version are canonical. Producers build one complete
candidate per attempt, without grinding. The generated at-par witness is a
valid fallback, not merely eligibility for another search. Puzzle-complexity
retargeting and strict `L < personalized_par` co-op shares remain.

This is a hobby chain, not settlement-grade security. Public witnesses make
equal-height alternatives cheap to construct, but extra golf score cannot make
them win. Missed slots offer a chance for a replacement to become strictly
taller; partitions can preserve different local incumbents. Parent-template
manipulation and reorgs above the latest checkpoint remain possible. A daily
slot or a string of confirmations does not eliminate those limits.

When replacing retired nonce-PoW state on an existing host, stop every chain
and pool database user and archive that retired chain and receipt state with
its genesis and source revision. Move it out of all active paths, then select
fresh distinct `state/*-proof-of-golf` directories. Never open a retired database with
the replacement binary, restore its receipts, or carry its balances forward.
Deployment scripts do not delete or migrate old operator data. The explicit
non-destructive Docker cutover is in [testnet.md](testnet.md#reset-cutover).

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
image builds `deploy#sigilcoin`, exports its Nix closure, and contains the
wrapped `sigilcoin` with pinned curl/CA data, `sigilcoin-explorer`, and the
generated static site.

## Public testnet DNS and firewall

Create operator-owned DNS records with TTL 300 during initial rollout:

| Name | Type | Value |
| --- | --- | --- |
| `sigilcoin.lol` | A | seed host public IPv4 address (host static site) |
| `seed.testnet.sigilcoin.lol` | A | seed host public IPv4 address |
| `explorer.testnet.sigilcoin.lol` | A | seed host public IPv4 address (Caddy) |
| `pool.testnet.sigilcoin.lol` | A | seed host public IPv4 address (Caddy) |

All four A records resolve to the RackNerd seed host. The seed record must be
DNS-only: do not place a web CDN or HTTP proxy in front of P2P. No SRV record
is needed, because the node's canonical seed includes TCP port `19446`.

Add corresponding AAAA records only after validating the IPv6 node listener,
both reverse-proxy origins, provider firewall, host firewall, routing, and
off-host probes. Do not publish an AAAA record that reaches only some of the
advertised services.

Apply separate provider and host firewall policy:

- public TCP/19446 to the testnet seed;
- public TCP/443 to the static site, explorer, and pool through Caddy;
- public TCP/80 for Caddy's HTTPS redirect and ACME HTTP challenge;
- no public TCP/8080 or TCP/8082; Docker binds both to `127.0.0.1`;
- SSH on its chosen port restricted independently to approved operator sources
  or a VPN.

Verify from outside the host network:

```sh
getent ahostsv4 sigilcoin.lol
dig +short A seed.testnet.sigilcoin.lol
dig +short A explorer.testnet.sigilcoin.lol
dig +short A pool.testnet.sigilcoin.lol
nc -vz seed.testnet.sigilcoin.lol 19446
curl -fsS https://explorer.testnet.sigilcoin.lol/api/summary \
  | jq -e '.chain == "sigilcoin-testnet"'
curl -fsS https://pool.testnet.sigilcoin.lol/healthz
curl -fsS https://pool.testnet.sigilcoin.lol/v1/context \
  | jq -e '.version == 1 and .chain == "sigilcoin-testnet"'
curl -fsS https://sigilcoin.lol/ >/dev/null
```

When AAAA exists, repeat with IPv6 forced. Confirm off-host connections to
TCP/8080 and TCP/8082 fail.

## Remote Docker host

Prepare the operator-owned remote workspace and the required local environment
file:

```sh
ssh host.example 'sudo install -d -o "$USER" -g "$(id -gn)" -m 0750 /srv/sigilcoin'
cd /path/to/workspace/sigil-coin
cp deploy/docker/.env.example deploy/docker/.env
$EDITOR deploy/docker/.env
```

Set `SIGIL_UID` and `SIGIL_GID` to the remote login user's numeric IDs. Choose
`EXPLORER_UID` and `POOL_UID` values that differ from the node and each other;
the defaults are 1001 and 1002. Keep
`SIGIL_TESTNET_STATE_DIR=./state/testnet-proof-of-golf`,
`SIGIL_TESTNET_POOL_STATE_DIR=./state/testnet-pool-proof-of-golf`,
`EXPLORER_PORT=8080`, and `POOL_PORT=8082` distinct.

The reviewed RackNerd handoff deploys the four-service testnet stack and then
the site/Caddy configuration:

```sh
./deploy/scripts/deploy-testnet-remote.sh racknerd-chi
```

The wrapper requires `deploy/docker/.env`, fixes the remote directory at
`/srv/sigilcoin`, and sets `SSH_IDENTITIES_ONLY=no` for the existing alias. The
equivalent lower-level stack invocation is:

```sh
SSH_IDENTITIES_ONLY=no ./deploy/scripts/deploy-remote.sh \
  --host racknerd-chi \
  --remote-dir /srv/sigilcoin \
  --mode testnet \
  --env-file deploy/docker/.env
```

`SSH_IDENTITIES_ONLY` accepts only `yes` or `no` and applies to every SSH call
and rsync's SSH transport; when unset, direct `deploy-remote.sh` calls retain
SSH-config behavior. The deploy script validates UIDs and non-symlink,
non-nested, distinct chain/pool paths, rsyncs all three sibling working trees,
uploads the environment file with restrictive mode, and starts
`compose.testnet.yml`. It excludes Git metadata, builds, caches, state,
deployment logs, and `.env`; it never commits or pushes. Review all three
working trees before intentionally running it.

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
docker compose --env-file .env -f compose.testnet.yml logs -f --tail=100 listener sync explorer pool
docker compose --env-file .env -f compose.testnet.yml exec sync \
  /usr/local/bin/sigilcoin-entrypoint cli status
docker compose --env-file .env -f compose.testnet.yml exec pool \
  /usr/local/bin/sigilcoin-entrypoint health-relay
```

The sync service runs one bounded pass at a time and retries after
`SYNC_INTERVAL`. The pool reads chain state through a query-only, read-only
mount and writes only its separate receipt store. Container logs do not
intentionally print wallet keys, the environment, request bodies, encoded
shares, or unsanitized relay details. Operators must still review log
retention, filesystem use, restart counts, public connection/rate pressure,
and both databases' growth.

Status reports branch-aware `issued-supply` from active UTXOs and the separate
height-only `scheduled-supply-cap`. Issued supply may trail that cap because a
solo block mints only `floor(4*S/5)` of scheduled subsidy; cooperative blocks
mint full scheduled subsidy and route fees and integer residuals to the
producer.

`puzzle` and `status` expose `next-slot-time` as a UTC epoch timestamp.
`puzzle` reports `savings` and `block-score` for its at-par witness; `status`
reports the active `best-chain-score`. `mine` reports the submitted block's
`savings`, `block-score`, `chain-score`, `validation`, and `active-chain`.
These score fields report quality on the named branch, not its selection
weight or subsidy. Use height, active-chain membership, and the installed
release's checkpoints when investigating a branch change.
A validated side-branch block need not be active or keep its payout after a
reorg. A slot is the earliest admissible wall-clock time, not a promise that
somebody will produce a block. Investigate clocks, producer availability, and
peer synchronization when a due slot remains unfilled; do not tune a hash target
or run a search worker.

## Static site, explorer, pool, and TLS

`compose.testnet.yml` hardcodes the explorer host mapping to
`127.0.0.1:${EXPLORER_PORT:-8080}:8080` and the pool mapping to
`127.0.0.1:${POOL_PORT:-8082}:8082`; neither has a public-bind override. Caddy
serves the generated site itself and remains the only public HTTP/TLS service.
The image installs that site at `/opt/sigilcoin/share/sigilcoin-site`.

After deploying an image, run the site helper with the SSH hostname or alias:

```sh
bash deploy/scripts/deploy-site-remote.sh racknerd-chi
```

The helper requires the explorer and pool containers, copies the immutable
generated site tree, stages the repository Caddyfile and a rollback copy,
validates the configuration, prompts for remote `sudo`, reloads Caddy, and
checks the public site, explorer, pool `/healthz`, and pool `/v1/context`.
`SSH_IDENTITIES_ONLY` accepts only `yes` or `no`; this helper and the RackNerd
one-host wrapper use `no` so the existing SSH alias can offer agent identities.

`deploy/Caddyfile` serves the apex from that tree. On the explorer origin it
serves only the three exact shared branding paths
`/assets/sigilcoin-symbol.png`, `/assets/plus-jakarta.woff2`, and
`/assets/jetbrains-mono.woff2`; every other request stays on the loopback
explorer proxy. The pool origin proxies unchanged paths to loopback port 8082,
caps request bodies at 2 KB and overwrites any incoming
`X-Sigilcoin-Client-IP` with Caddy's `{remote_host}`. It
enables no CORS.

Rollback uses the preserved pre-change config:

```sh
sudo sh -c 'caddy validate --config /srv/sigilcoin/Caddyfile.rollback && install -o root -g root -m 0644 /srv/sigilcoin/Caddyfile.rollback /etc/caddy/Caddyfile && systemctl reload caddy'
```

Smoke-test `/`, `/blocks`, `/difficulty`, `/api/summary`, `/api/blocks`, and
`/api/difficulty` on the explorer over HTTPS; test `/healthz` and `/v1/context`
on the pool; fetch the shared assets and `https://sigilcoin.lol/`; and verify
direct off-host TCP/8080 and TCP/8082 remain closed.

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

Default paths are under `deploy/state/local-testnet-proof-of-golf`,
`deploy/logs/local-testnet`, and `deploy/run/local-testnet`; they are ignored by
Git. Archive any retired local testnet state rather than pointing `DATA_DIR`
back at it.

## State and permissions

Compose mounts testnet chain state from `SIGIL_TESTNET_STATE_DIR` (default
`./state/testnet-proof-of-golf`), pool receipts from `SIGIL_TESTNET_POOL_STATE_DIR`
(default `./state/testnet-pool-proof-of-golf`), and mainnet from
`SIGIL_MAINNET_STATE_DIR` (default `./state/mainnet-proof-of-golf`).
Listener and sync run as `SIGIL_UID:SIGIL_GID` with
umask `0027`; explorer and pool use distinct `EXPLORER_UID` and `POOL_UID`
values, share only `SIGIL_GID`, and receive the chain mount read-only. Only the
pool receives its separate receipt directory read-write; the deploy script
creates it as the remote operator with group `SIGIL_GID` and mode `0770`.

The pool starts only after healthy sync and runs with a read-only root,
temporary writable files on tmpfs, all capabilities dropped,
`no-new-privileges`, `pids_limit: 64`, `mem_limit: 256m`, and `cpus: "0.5"`.

Its durable file is `sigilcoin-pool.sqlite` under the pool state directory; it
never writes the node database.

Public relay admission is bounded before SQLite persistence: one transaction
may serialize to at most 16384 bytes, and the whole mempool table is capped at
1024 rows while available bodies are capped at 1048576 serialized bytes.
Disconnected or stale request placeholders are removed, and only inventory in
the bounded requested prefix is persisted. A one-shot producer considers only
the first 128 block-sized candidates. Header sync caps the entire unsettled
header/body cache at 4096 rows; only accepted, previously unknown headers make
room by evicting oldest leaves, which peers may announce again later. Body
requests fill across attempt-count bands. These are node policy limits, not
consensus; they prevent public relay traffic from turning the scheduled
producer back into sustained CPU or disk load.

SQLite database, WAL, SHM, and journal files are normalized to `0640` so the
read-only services can traverse chain state. Keep `wallet/` at `0700` and
`wallet/wallet.key` at `0600`, owned by `SIGIL_UID`; neither explorer nor pool
may read it. Wallet keys, backups, and unrevealed commitments remain secrets
even though test coins are worthless. Never use production keys on testnet.

## Backups

Stop every chain and pool database user before a filesystem backup, and archive
the two state directories separately. If `.env` overrides either state path,
export the same values in this shell before using the following commands:

```sh
(
set -euo pipefail
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml stop
install -d -m 0700 "$HOME/sigilcoin-testnet-backups"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
state_dir=${SIGIL_TESTNET_STATE_DIR:-"$PWD/state/testnet-proof-of-golf"}
pool_state_dir=${SIGIL_TESTNET_POOL_STATE_DIR:-"$PWD/state/testnet-pool-proof-of-golf"}
[[ $state_dir == /* ]] || state_dir=$PWD/${state_dir#./}
[[ $pool_state_dir == /* ]] || pool_state_dir=$PWD/${pool_state_dir#./}
tar -C "$state_dir" -czf "$HOME/sigilcoin-testnet-backups/$stamp-chain.tgz" .
tar -C "$pool_state_dir" -czf "$HOME/sigilcoin-testnet-backups/$stamp-pool.tgz" .
chmod 0600 "$HOME/sigilcoin-testnet-backups/$stamp-chain.tgz" \
  "$HOME/sigilcoin-testnet-backups/$stamp-pool.tgz"
sha256sum "$HOME/sigilcoin-testnet-backups/$stamp-chain.tgz" \
  "$HOME/sigilcoin-testnet-backups/$stamp-pool.tgz" \
  >"$HOME/sigilcoin-testnet-backups/$stamp.sha256"
docker compose --env-file .env -f compose.testnet.yml up -d
)
```

The fail-fast subshell restarts services only after both archives, permissions,
and the checksum file succeed. On any failure, leave the stack stopped and
preserve the partial evidence for diagnosis.

A live `cp` or `tar` may capture torn SQLite state. Store backups encrypted and
offline; never commit or rsync them into source. Restore only a matching
replacement-genesis pair into distinct empty locations, never retired nonce-PoW
state. Start sync before pool and
explorer so chain SQLite can recover normally, then compare genesis, status,
relay context, issued supply, and balance with an independent node.

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
P2P, explorer summary, pool health/context, and active receipt projections with
the baseline. To recreate from a schema-compatible rollback image without
rebuilding:

```sh
SIGIL_IMAGE="$rollback_image" docker compose --env-file .env \
  -f compose.testnet.yml up -d --no-build --force-recreate
```

An image rollback does not migrate or restore either state directory. The
chain database, pool schema, consensus rules, and replacement genesis must all
be compatible. The retired nonce-PoW image and its archives are not rollback
targets for a proof-of-golf deployment; never open either generation's state
with the other binary.
If compatibility is uncertain, preserve both current directories and restore
a matching pair into empty locations. An incident or testnet success does not
authorize a mainnet push or deployment.

## Mainnet launch configuration

Mainnet Docker uses port `19444`, fresh `./state/mainnet-proof-of-golf` state, and
loopback explorer port `8081`. The co-op relay service and public pool hostname
are testnet-only; mainnet Compose has no pool. Compare the replacement genesis
with the reviewed all-network constants, not the superseded launch record.
Both helper scripts and every container refuse mainnet unless the operator sets
exactly `ALLOW_MAINNET=yes`.

The local helper defaults to `deploy/state/local-mainnet-proof-of-golf`.
The Docker replacement must set
`SIGIL_MAINNET_STATE_DIR=./state/mainnet-proof-of-golf` in `.env`; a changed
default does not override an old environment file. On a host that used the
retired default, first stop every external database user and archive the old
mainnet directory before changing its active state path:

```sh
(
set -euo pipefail
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose -p sigilcoin-mainnet --env-file .env --profile mainnet-miner \
  -f compose.mainnet.yml stop
[[ ! -e state/mainnet-proof-of-golf ]]
stamp=$(date -u +%Y%m%dT%H%M%SZ)
mv -- state/mainnet "state/mainnet.retired-nonce-pow-$stamp"
install -d -m 0750 state/mainnet-proof-of-golf
)
```

Substitute the actual retired path if `.env` used an override. Keep an encrypted
offline copy labeled with the retired genesis and revision. Only after this
archive step succeeds, save the new `.env` state path and run the reviewed
deployment. Do not restore the retired database, wallet, or receipts. Fresh
hosts skip the archive step but still select an unused replacement directory.

```sh
ALLOW_MAINNET=yes MODE=mainnet bash deploy/scripts/run-local.sh
ALLOW_MAINNET=yes MODE=mainnet REMOTE_HOST=host.example \
  REMOTE_DIR=/srv/sigilcoin bash deploy/scripts/deploy-remote.sh
```

These commands document the safety gate; they are not launch approval. Complete
the replacement public-testnet gate before a separate private mainnet rehearsal.
See [testnet.md](testnet.md) and [LAUNCH.md](../LAUNCH.md).

### Scheduled mainnet production

On the Docker host, `start-mainnet-miner.sh` starts the non-default
`mainnet-miner` profile and `miner` service. Those operator-facing names remain,
but the container runs `producer-loop`: it waits for `next-slot-time`, builds
and submits one complete candidate, then waits again. There is no nonce, hash,
or coinbase search. The generated at-par program is a valid score-1 fallback.
`MINE_INTERVAL=60` controls idle tip polling and retry delay, not consensus
spacing; mainnet header times are exactly one day apart. The supervisor checks
for a changed validated tip while waiting and cancels a stale in-flight child.
An early-slot refusal is retried after waiting, never worked around by altering
the timestamp.

Producer rewards go to
`sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud`; the seed stores no wallet key.
Review the configured `MINER_ADDRESS` before starting. Keep the producer
low-CPU: sleeping between slots is normal, and hash-rate tuning is irrelevant.

```sh
bash /srv/sigilcoin/sigil-coin/deploy/scripts/start-mainnet-miner.sh
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose -p sigilcoin-mainnet --env-file .env --profile mainnet-miner \
  -f compose.mainnet.yml logs -f miner
```

Normal mainnet deployment stops and removes an active producer before replacing
node binaries. Run the guarded launcher again after every deployment. To stop
only production:

```sh
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose -p sigilcoin-mainnet --env-file .env --profile mainnet-miner \
  -f compose.mainnet.yml stop miner
```
