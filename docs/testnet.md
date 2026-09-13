# Public testnet operator runbook

This runbook covers the replacement `sigilcoin-testnet` network from height 0.
The stable seed endpoint is `seed.testnet.sigilcoin.lol:19446`; community nodes
may join and leave. Start a new 48-hour observation gate only after the
replacement genesis and fresh state are verified.

The earlier gate beginning `2026-09-06T05:30:15Z` belonged to the retired
nonce-PoW testnet and is superseded, not evidence for this replacement. The
launched mainnet was also retired before height 1 because its compute burn
contradicted the project's intent; its historical identity remains in
[LAUNCH.md](../LAUNCH.md).

Testnet coins are worthless. Never use a production key, address, seed phrase,
wallet backup, or unrevealed production material on testnet. Do not promote
this chain, its state, or its keys to mainnet, and do not push a mainnet launch
because a testnet gate passed.

## Replacement testnet parameters

- Chain: `sigilcoin-testnet`, selected with `--testnet`.
- DNS seed and P2P endpoint: `seed.testnet.sigilcoin.lol:19446`.
- Address HRP: `tsgl`, producing `tsgl1...` addresses.
- Genesis marker, timestamp, and display/internal hashes: use the reviewed
  replacement all-network output from `deploy/genesis-constants.sgl` for this
  build. Do not use the retired public-testnet identity.
- Transport magic: `SGT3` (final byte `0x33`); mainnet uses `SGM3` and regtest
  `SGR3`. This isolates older score-ranked peers without changing proof-of-golf
  genesis hashes, genesis timestamps, or block wire bytes. Existing proof-of-golf
  H0 state may be reused; retired nonce-PoW state may not.
- Timestamp: exactly `parent.time + configured testnet spacing`, with zero
  future drift. Testnet retains its configured shorter slots; mainnet uses
  exactly 86,400 seconds. `puzzle` and `status` report `next-slot-time` as a UTC
  epoch timestamp.
- Producer validity: the unchanged puzzle VM must accept the program and
  `L <= par`. The generated at-par witness is a valid fallback.
- Savings: `min(8, max(0, par - L))`; non-genesis block score is `1 + savings`,
  in `1..9`. Genesis score is 0. Scores display competition quality, not fork
  weight, and currently do not alter subsidy.
- Fork choice: only a strictly taller valid branch wins. Equal height retains
  the durable active incumbent across restart; score, hash, and arrival metadata
  do not break ties.
- Checkpoints: chain configs hardcode `(height . internal-hash)` pairs.
  Incompatible branches cannot cross them. Only reviewed software releases
  advance checkpoints; nodes must upgrade to share a newer one. Public testnet
  and regtest still pin H0 only, protecting genesis but no later history.
  Mainnet now pins H0 and the live H1 block listed in
  [the consensus specification](consensus.md#58-hardcoded-release-checkpoints):
  reorgs below H1 are rejected, while reorgs above H1 remain possible.
  There is no automatic or signed-checkpoint finality service.
- Headers remain 80 bytes, with canonical packed length/complexity in
  `version`, nonce 0, and fixed network pow-limit `bits` as a compatibility
  field. There is no hash target validation or hash-difficulty retarget.
- Non-genesis coinbase: lock-time 0, empty graffiti, canonical sequence/version.
- Production: build a complete candidate once after its slot is due; no
  grinding. Puzzle-complexity retargeting remains.
- Shares: unchanged strict `L < personalized_par`, commitments, delayed
  reveals, contribution checks, and direct signed payouts.
- Explorer: `https://explorer.testnet.sigilcoin.lol` through Caddy to
  loopback-only `127.0.0.1:8080`.
- Co-op relay: `https://pool.testnet.sigilcoin.lol` through Caddy to
  loopback-only `127.0.0.1:8082`. It is a non-custodial public-testnet
  convenience service, not a consensus service or a mainnet pool.
- Exercise duration: at least 48 consecutive hours on the replacement network;
  extend it until every required boundary has been exercised.

The schedule fixes admissible header timestamps, not volunteer availability.
A late block keeps its scheduled time; never substitute the current wall clock
or a future timestamp. A due at-par candidate needs no further search.
Community producers are not assigned slots or required to remain online.

This is a hobby chain, not settlement-grade security. Equal-height alternatives
are cheap to build, but better golf score cannot make them win. Missed slots
offer a takeover opportunity if a replacement becomes strictly taller, and
partitions can preserve different local incumbents. Parent-template manipulation
and reorgs above the latest checkpoint remain possible. Clock spacing and
additional confirmations do not remove these limitations.

## Reset cutover

Moving from retired nonce-PoW is a replacement network, not a height activation
or a database upgrade. Every participant must use the proof-of-golf genesis,
longest-height rules, and released checkpoints from height 0. A chain name,
address prefix, port, or successful wire handshake
does not prove that a peer has that identity. Old chain and relay databases,
histories, and backups stay archived; no old balance or receipt carries over.
Never open retired state with the replacement binary.
The later longest-height/checkpoint cutover changes transport magic, not
proof-of-golf genesis; existing proof-of-golf H0 state may be reused. When
upgrading for a later checkpoint, preserve state before restarting. The node
refuses to open active history that conflicts with the installed checkpoint
rather than silently rewriting it; compare the reviewed release's checkpoint
list when diagnosing that refusal.

Before starting on a host that ran the retired testnet:

1. Stop listener, sync, explorer, pool, producers, contributors, observers, and
   every CLI process that can open either database, including out-of-Compose
   jobs.
2. Archive the retired state offline and label it with the old genesis and
   source revision. Move both old chain and pool directories out of active use.
3. Create distinct empty `state/testnet-proof-of-golf` and
   `state/testnet-pool-proof-of-golf` directories with restrictive permissions.
   Do not copy any retired SQLite file, receipt, or wallet into them.
4. Set the new paths in `.env`, then start the replacement stack.
5. Compare the display genesis id and relay context with the reviewed
   replacement constants before adding peers, contributors, or producers.

For a host using the retired Docker defaults, the non-destructive archive and
directory creation are:

```sh
(
set -euo pipefail
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml stop
old_state_dir=$PWD/state/testnet
old_pool_state_dir=$PWD/state/testnet-pool
new_state_dir=$PWD/state/testnet-proof-of-golf
new_pool_state_dir=$PWD/state/testnet-pool-proof-of-golf
[[ ! -e $new_state_dir && ! -e $new_pool_state_dir ]]
stamp=$(date -u +%Y%m%dT%H%M%SZ)
mv -- "$old_state_dir" "${old_state_dir}.retired-nonce-pow-$stamp"
if [[ -d $old_pool_state_dir ]]; then
  mv -- "$old_pool_state_dir" "${old_pool_state_dir}.retired-nonce-pow-$stamp"
fi
install -d -m 0750 "$new_state_dir"
install -d -m 0770 -g "$(id -g)" "$new_pool_state_dir"
)
```

If the old `.env` used non-default paths, substitute those actual retired paths
before running this block. The example assumes the remote login user's UID/GID
match `SIGIL_UID`/`SIGIL_GID`; retain the configured ownership otherwise.
The fail-fast subshell never restarts services. A failed stop, move, or
directory creation leaves the stack down; preserve what exists and investigate.
Keep the retired directories as offline archives, with a verified encrypted
copy outside the host.

Only after that succeeds, edit `.env` to select:

```sh
SIGIL_TESTNET_STATE_DIR=./state/testnet-proof-of-golf
SIGIL_TESTNET_POOL_STATE_DIR=./state/testnet-pool-proof-of-golf
```

Then start from those fresh paths:

```sh
cd /srv/sigilcoin/sigil-coin/deploy/docker
$EDITOR .env
docker compose --env-file .env -f compose.testnet.yml up -d
```

Apply the same archive/fresh-directory boundary to any observer, contributor,
or local node state. Deployment automation never deletes or migrates old
operator data. A newly named directory containing an old database is not fresh
state.

## Safety boundary

Public mode exposes an unauthenticated P2P service and a bounded co-op relay to
the Internet. Before opening either, confirm resource limits, rotating logs,
provider and host firewall rules, monitoring, backups, and an incident shutdown
path. The explorer and pool containers must never bind a public host interface.
Only Caddy may expose their loopback ports.

Keep SSH administration separate from public services: restrict TCP/22 (or the
chosen admin port) to operator source addresses or a VPN. Do not infer that an
open P2P firewall rule authorizes public SSH.

All testnet wallets are disposable secrets. Keep `wallet/` mode `0700`,
`wallet/wallet.key` mode `0600`, backups encrypted and offline, and unrevealed
commitment blinds private. Never paste keys or backups into logs, chat, tickets,
or source.

## DNS and network readiness

Create these operator-owned DNS records with TTL 300 initially:

| Name | Record | Value |
| --- | --- | --- |
| `seed.testnet.sigilcoin.lol` | A | seed host public IPv4 |
| `explorer.testnet.sigilcoin.lol` | A | seed host public IPv4 (Caddy) |
| `pool.testnet.sigilcoin.lol` | A | seed host public IPv4 (Caddy) |

All three A records point to the RackNerd seed host. Keep the seed record
DNS-only, with no HTTP CDN or proxy in front of P2P. No SRV record is needed;
port `19446` is part of the chain configuration. Add AAAA records only after
the node listener, both Caddy origins, provider firewall, host firewall, and
off-host probes have all been validated over IPv6.

Firewall policy:

- allow public TCP/19446 to the seed node;
- allow public TCP/443 to Caddy;
- allow TCP/80 only if the operator intentionally uses HTTP-to-HTTPS redirect
  or an ACME HTTP challenge;
- never allow public TCP/8080 or TCP/8082; both stay on `127.0.0.1`;
- restrict admin SSH separately to approved operator sources.

Validate from a machine outside the host network:

```sh
dig +short A seed.testnet.sigilcoin.lol
dig +short A explorer.testnet.sigilcoin.lol
dig +short A pool.testnet.sigilcoin.lol
nc -vz seed.testnet.sigilcoin.lol 19446
curl -fsS https://explorer.testnet.sigilcoin.lol/api/summary \
  | jq -e '.chain == "sigilcoin-testnet"'
curl -fsS https://pool.testnet.sigilcoin.lol/healthz
curl -fsS https://pool.testnet.sigilcoin.lol/v1/context \
  | jq -e '.version == 1 and .chain == "sigilcoin-testnet"'
```

If AAAA is published, repeat DNS, `nc`, and `curl` with IPv6 forced. A broken
AAAA record is an outage for clients that prefer IPv6.

## Start the stable seed

Use the Docker deployment workflow in [deployment.md](deployment.md). The seed
host's environment must explicitly select public mode:

```sh
P2P_BIND=0.0.0.0
P2P_PORT=19446
TESTNET_EXPOSURE_ACK=public-testnet-approved
REMOTE_PEER_IP=
EXPLORER_PORT=8080
POOL_PORT=8082
POOL_UID=1002
SIGIL_TESTNET_STATE_DIR=./state/testnet-proof-of-golf
SIGIL_TESTNET_POOL_STATE_DIR=./state/testnet-pool-proof-of-golf
```

The exact acknowledgement is intentional approval of Internet-facing P2P. A
missing, misspelled, or alternate value must fail before startup. Do not expose
the seed until both provider and host firewall policies are ready.

After startup:

```sh
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml ps
docker compose --env-file .env -f compose.testnet.yml logs --tail=100 listener sync explorer pool
docker compose --env-file .env -f compose.testnet.yml exec sync \
  /usr/local/bin/sigilcoin-entrypoint cli status
docker compose --env-file .env -f compose.testnet.yml exec pool \
  /usr/local/bin/sigilcoin-entrypoint health-relay
ss -ltn
```

Require P2P on the intended public interface, explorer only at
`127.0.0.1:8080`, pool only at `127.0.0.1:8082`, all four containers healthy,
and no unexpected listener. The pool must have a distinct UID, a read-only
chain-state mount, and a separate writable state directory. Before connecting
producers, compare node status and explorer/API display order with the reviewed
replacement all-network genesis output produced by this build. Any mismatch or
retired-testnet tip is a failed cutover.

## Community bootstrap

A current node automatically reads the canonical DNS seed. For a new community
node, select an unused state path; never use a retired database. An operator may
make bootstrap explicit:

```sh
DATA="$PWD/state/testnet-proof-of-golf"
install -d -m 0750 "$DATA"
sigilcoin peers add seed.testnet.sigilcoin.lol:19446 --testnet \
  --data-dir "$DATA"
sigilcoin peers test seed.testnet.sigilcoin.lol:19446 --testnet \
  --data-dir "$DATA"
sigilcoin sync --peer seed.testnet.sigilcoin.lol:19446 --testnet \
  --data-dir "$DATA" --iterations 1 --max-steps 4096 --max-blocks 256
```

A community operator may manually configure any trusted reachable testnet peer.
DNS is bootstrap, not an authority over consensus. Every node independently
validates the replacement genesis and rules. A retired-testnet history, an
`sgl1...` address, or any genesis mismatch is grounds to stop; replacement-testnet
addresses must begin `tsgl1...`.

## Contribute without a node

The public testnet watcher needs a local wallet directory but no node database.
It derives the pubkey-personalized puzzle and par locally from the relay's
public chain context; a share must be strictly shorter than that par. With no
solution argument it prints the puzzle and prompts once:

```sh
sigilcoin contribute --relay https://pool.testnet.sigilcoin.lol --testnet
```

Supply a solution non-interactively, or resume the same private receipt after
an interruption:

```sh
sigilcoin contribute --relay https://pool.testnet.sigilcoin.lol \
  --solution '(lambda(x)...)' --testnet
sigilcoin contribute --relay https://pool.testnet.sigilcoin.lol \
  --commitment COMMITMENT --testnet
```

`--solution` and `--commitment` are mutually exclusive. An empty response or
EOF at the interactive prompt creates no receipt. Add `--data-dir DIR` to keep
the disposable wallet and private commitment records somewhere other than the
default.

Public contribution and producer URLs must use HTTPS. The CLI invokes
CA-verified, bounded curl without redirects or curlrc processing; if curl is
unavailable it fails before creating a wallet or commitment. Plain HTTP is
accepted only for a literal loopback regtest relay.

The watcher defaults to `.sigilcoin-testnet-proof-of-golf`; do not reuse or copy
the retired `.sigilcoin-testnet` directory. Back up the new disposable wallet
key and keep the command running through the following block, or resume it with
the printed commitment. Before block `H`, it sends only public context, pubkey,
commitment, and a context-bound relay authorization. The private key, blind,
solution source, consensus share signature, and encoded share stay local. Only
after the exact commitment appears in canonical block `H` does the watcher sign
and submit the reveal containing the blind and source. The private key never
leaves the wallet. Interrupting the watcher leaves its private record usable;
successful inclusion removes only that record.

Watcher status is projected from exact membership in active validated block
bodies and may move backward or forward after a reorg:

| Status | Meaning |
| --- | --- |
| `waiting` | The active validated tip is below `H-1`; keep watching. |
| `stale` | The canonical `H-1` parent or contribution context changed. Stop and solve the new context. |
| `queued` | Block `H` does not exist yet and the relay holds the commitment. |
| `commit-missed` | Canonical block `H` exists but omitted the commitment. This receipt is finished. |
| `revealable` | Canonical `H` is the active validated tip, contains the exact commitment, and `H+1` is absent; the watcher may now sign. |
| `reveal-queued` | The relay accepted and revalidated the reveal while `H+1` is absent. |
| `included` | Canonical `H+1` contains the exact share and its contributor output. |
| `reveal-missed` | Canonical `H+1` exists without that exact share and output. This receipt is finished. |

An `included` reward is a direct coinbase output to the contributor's signed
wallet key and becomes spendable in the block after the reveal block. SigilCoin
uses one-block coinbase maturity; Bitcoin's default remains 100 blocks. It is
not a relay balance, and inclusion is not guaranteed.

## Pool admission and producer use

For each exact `(height, parent, complexity)` context, the first 16
authenticated distinct pubkeys receive durable relay commitment slots; one
pubkey may occupy only one slot. The seventeenth receives `pool-full`. New
accepted PUTs return 201 and exact stored replays return 200, so retry the same
saved receipt rather than generating a new blind. Relay authorization controls
admission only: an attacker with many keys can still fill all 16 slots, and the
per-address limit of eight new mutations per 60 seconds is not Sybil resistance.
Every accepted current-context commitment is offered to the producer in
canonical digest order; the digest does not decide admission.

Relay participation does not change solution validity: the producer's global
solution must satisfy `L <= par`, while every personalized share supplied by
the relay must satisfy `L < personalized_par`. The generated at-par witness
is a valid score-1 fallback. Each byte saved adds one point, capped at eight
savings and score 9. After the complete body and merkle root are final, `mine`
submits that candidate once with the canonical nonce, coinbase, fixed `bits`,
and scheduled timestamp. It does not search for a header hash.

After synchronizing, inspect the current puzzle and `next-slot-time`:

```sh
sigilcoin puzzle --testnet --data-dir "$DATA"
```

At or after that UTC epoch time, opt into the relay with a complete at-par
candidate:

```sh
sigilcoin mine --relay https://pool.testnet.sigilcoin.lol \
  --testnet --data-dir "$DATA"
```

With no `--solution`, `mine` uses the valid generated at-par fallback without a
prompt. To improve displayed competition quality, pass `--solution` with your
valid shortened program for the current parent; this does not improve fork
position or the current subsidy. Wait after an early-slot refusal; do not retry
in a tight loop or alter the timestamp. A changed tip requires a fresh
parent-specific puzzle and candidate.
The result's `validation` and `active-chain` fields are distinct: a valid
side-branch block need not become active. Record its `savings`, `block-score`,
and `chain-score` as quality metrics; an accepted block is not a settlement guarantee.

The producer requires the relay context to match its own active chain, applies the
normal commitment checks, fully revalidates every reveal against its actual
producer solution, deduplicates pubkeys/solutions, ranks eligible reveals by
contribution descending and pubkey ascending, and includes at most eight. The
relay's first-16 admission therefore does not promise one of the
consensus R8 share positions. If an explicitly configured relay is unavailable,
stale, malformed, oversized, or contradictory, production fails; an operator may
deliberately rerun without `--relay` to construct a solo block.

The relay can delay or omit work, and either the relay or a producer can censor
a commitment or reveal. A producer also sees the source after the commitment
block and can omit it from the reveal block. None of these availability risks
lets either party redirect a valid signed payout: the pubkey is signed and the
contributor output is checked by consensus. This service is public-testnet-only
operational coordination, not custody, proof of inclusion, or a consensus rule.

## Local Nix loopback workflow

From the `sigil-coin` checkout inside the workspace, use the workspace's pinned
Nix environment. This joins the public seed outbound while keeping local P2P
and explorer ports loopback-only:

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

The explorer is available only at `http://127.0.0.1:8080/`. No exposure
acknowledgement is needed for this fail-closed loopback mode. Ctrl-C stops the
foreground stack and preserves state. This workflow is for a trusted local
host, not the public RackNerd seed.
The helper defaults to `deploy/state/local-testnet-proof-of-golf`; archive the
retired local state and never override `DATA_DIR` to point back at it.

## Explorer and pool TLS reverse proxy

Compose fixes the explorer mapping at `127.0.0.1:8080` and the pool mapping at
`127.0.0.1:8082`; neither has a public-bind override. Caddy is the only public
TLS and HTTP-framing boundary. Do not place Docker on ports 80 or 443, expose
either loopback port, add CORS, or proxy the pool through a service that does
not preserve these request limits.

The repository Caddyfile applies the shared security headers and logging. Its
pool boundary is equivalent to:

```caddyfile
explorer.testnet.sigilcoin.lol {
    reverse_proxy 127.0.0.1:8080
}

pool.testnet.sigilcoin.lol {
    request_body {
        max_size 2KB
    }
    reverse_proxy 127.0.0.1:8082 {
        header_up X-Sigilcoin-Client-IP {remote_host}
    }
}
```

Caddy's `header_up` assignment must overwrite any untrusted client-supplied
`X-Sigilcoin-Client-IP` with the connection's `{remote_host}`. Do not combine
it with a deletion directive: Caddy orders header deletions after assignments.
Validate the explorer's `/`, `/blocks`, `/difficulty`, `/api/summary`, `/api/blocks`, and
`/api/difficulty`, plus the pool's `/healthz` and `/v1/context`, over HTTPS.
Confirm direct off-host access to both TCP/8080 and TCP/8082 fails.

## Daily operations

Record evidence in UTC. Do not record environment dumps, wallet material,
contributor request bodies, encoded reveals, or unsanitized relay details. At
least daily:

1. Capture node status: tip height/hash, validated bodies, `next-slot-time`,
   next puzzle complexity, `best-chain-score`, peer successes/failures, last
   sync outcome, `issued-supply`, and `scheduled-supply-cap`. Record producer
   `mine` results separately for `savings`, `block-score`, `chain-score`,
   `validation`, and `active-chain`. The producer should sleep between due
   slots, not consume CPU searching.
2. Compare the seed with the separate observer process and database at the same
   height. The compressed gate does not claim host-level independence.
3. Probe DNS, public P2P, HTTPS explorer, pool `/healthz` and `/v1/context`, and
   confirm TCP/8080 and TCP/8082 remain private.
4. Review listener, sync, pool, reverse-proxy, firewall, and kernel logs for
   malformed traffic, repeated connection pressure, 409/429/500 spikes,
   crashes, and restarts without logging request bodies.
5. Record all four containers' restart counts, RSS, CPU, disk use, inode use,
   chain/pool database growth, network traffic, and file-descriptor/PID pressure
   against limits.
6. Confirm log rotation retains useful incident evidence without filling disk.
   Never enable request-body or environment logging, and do not publish private
   keys, source addresses, or unsanitized relay details.
7. Check freshness of both chain and pool backups without printing or opening
   wallet or contribution material.

Any retained observer must also start from fresh
`state/testnet-observer-proof-of-golf` state with the replacement genesis.
Archive the retired observer database and old evidence separately. Update any
external evidence collector to record the replacement golf fields before
reenabling its cron job; old network snapshots do not count toward this gate.

Use `next-slot-time` rather than a wall-clock mining roster. A due slot can stay
empty when nobody produces; a late block still has the exact scheduled header
time. Inspect synchronization, clocks, and producer availability when it is
late. Never change `bits`, search nonces, or future-date a block to catch up.

## Consensus and interoperability evidence

Complete these before the 48-hour gate closes:

- Puzzle retarget: capture H15, H16, and H17 complexity and historical queries.
  The 16-block puzzle-complexity boundary must agree across nodes. Require
  fixed network `bits`, exact slot timestamps with no future drift, and
  cumulative golf scores; there is no second hash-target retarget.
- Maturity: show the H1 coinbase cannot be spent in H1 and is selectable for
  H2, then send a small amount between disposable `tsgl1...` wallets.
- Co-op: use the node-free watcher to carry a commitment at H and its
  authorized reveal at H+1; require contribution in `1..4`, canonical output
  order, a direct contributor output spendable in the following block, the 10%
  contribution-weighted share pool, 5% carrier target, and the producer's fee
  and integer residual. Exercise every watcher status and a reorg that moves a
  receipt backward or makes it stale/missed.
- Four-role local regtest smoke: use [local-testnet.md](local-testnet.md) with
  fresh regtest state. Producer A includes D's commitment in H100; light
  contributor D has no node database and the pre-H100 relay row contains no private key,
  blind, solution source, consensus share signature, or encoded share; H101
  includes D's reveal and A's signed A-to-B transaction; ordinary node B sends
  its exact signed B-to-C transaction over a normal P2P session, A records it
  from a peer before producing H102, C receives the expected output, and B pays the
  fee; after reopening H102, H103 proves durability and A/B/C plus explorer
  agree on transactions, balances, payouts, and the full cooperative subsidy
  (zero unminted reserve).
- Solo issuance: require `floor(4*S/5)+F` in the only coinbase output and show
  the unused scheduled reserve as unminted.
- Supply: compare branch-aware `issued-supply` from active UTXOs with the
  separately labeled `scheduled-supply-cap`; issued supply may be lower after
  solo blocks and must never exceed the cap.
- Reorg: create valid equal-height branches with different golf scores and
  require each node to retain its durable active incumbent across restart,
  irrespective of score, hash, or arrival metadata. Local equal-height
  disagreement is allowed. A shorter higher-score branch must not displace it;
  propagate a strictly taller checkpoint-compatible branch, even with lower
  golf score, and require nodes and explorer to switch without database editing.
  Children and confirmation counts do not finalize history above the latest
  checkpoint.
- Checkpoints: record the installed release's `(height . internal-hash)` list
  on each node and require agreement with every reached checkpoint. Public
  testnet's H0-only checkpoint protects genesis, not post-genesis history; this
  gate cannot demonstrate later finality until a reviewed release pins a later
  public-testnet block. Mainnet's H1 checkpoint does not apply to testnet.
- Restart: cleanly restart each service and preserve tip, balance, peers,
  explorer state, and idempotent pool receipts.
- Hard kill: once while the listener is idle, kill only one node, recover via
  normal SQLite opening/sync, and verify no lost validated state.
- Restore: restore matching replacement-genesis chain and pool offline backups
  into empty test locations and verify status, disposable address, balance,
  sync, pool health/context, and explorer routes. Never restore retired state.
- Explorer and pool: check canonical block/PBE, golf, co-op and address
  HTML/JSON; the golf object contains `claimed_length`, `par`, `savings`,
  `block_score`, and `chain_score`. Require issued-supply and
  scheduled-maximum labels, read-only behavior, relay status against exact
  block membership, and rejection of nonempty non-genesis graffiti.

Never coordinate a fault drill that takes every reachable bootstrap node down
at once. Announce a bounded drill window, but do not assign production obligations
to community members.

## Backups and restore

A plain filesystem archive is consistent only while listener, sync, explorer,
pool, producers, and every command that can write either database are stopped.
Keep chain and pool state in distinct archives. If `.env` overrides either
state path, export the same values in this shell before using these commands:

```sh
(
set -euo pipefail
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml stop
backup_dir=$HOME/sigilcoin-testnet-backups
install -d -m 0700 "$backup_dir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
state_dir=${SIGIL_TESTNET_STATE_DIR:-"$PWD/state/testnet-proof-of-golf"}
pool_state_dir=${SIGIL_TESTNET_POOL_STATE_DIR:-"$PWD/state/testnet-pool-proof-of-golf"}
[[ $state_dir == /* ]] || state_dir=$PWD/${state_dir#./}
[[ $pool_state_dir == /* ]] || pool_state_dir=$PWD/${pool_state_dir#./}
tar -C "$state_dir" -czf "$backup_dir/$stamp-chain.tgz" .
tar -C "$pool_state_dir" -czf "$backup_dir/$stamp-pool.tgz" .
chmod 0600 "$backup_dir/$stamp-chain.tgz" "$backup_dir/$stamp-pool.tgz"
sha256sum "$backup_dir/$stamp-chain.tgz" "$backup_dir/$stamp-pool.tgz" \
  >"$backup_dir/$stamp.sha256"
docker compose --env-file .env -f compose.testnet.yml up -d
)
```

The fail-fast subshell restarts services only after both archives, permissions,
and the checksum file succeed. On any failure, leave them stopped and preserve
the partial evidence for diagnosis.

Encrypt backups at rest and copy them to an operator-controlled offline
location. The chain backup contains the disposable node key and may contain
local unrevealed commitment records. The pool backup contains source addresses
and revealed records, but a phase-one row must never contain a contributor
private key, blind, solution source, consensus share signature, or encoded
share. Never commit either archive or rsync it into a source tree. For a restore
drill, verify checksums, preserve
failed state, extract the matching pair into distinct empty directories with
restrictive modes, start sync before pool/explorer, and compare the restored
node and relay context to an independent peer.

## Upgrade and rollback

Before every upgrade:

1. Review and record exact source revisions and image identity.
2. Stop database users and take a verified offline backup.
3. Preserve the current image under an immutable rollback tag.
4. Build and start the reviewed image only when its consensus rules and genesis
   match fresh or explicitly compatible chain state.
5. Compare status, resource use, public P2P, explorer routes, pool
   health/context, and active receipt projections with the pre-upgrade baseline
   and an independent node.

Rollback only to a reviewed image compatible with the chain database, pool
schema, and replacement genesis. The retired nonce-PoW image is not a rollback
target. Never restore a retired-testnet database or backup into either current
state directory. If compatibility is uncertain, stop and preserve both
directories rather than trying binaries against them. Never make an unreviewed
source or mainnet push to repair public testnet.

## Incident shutdown

Shut down the affected public service immediately for suspected consensus
divergence, either database's corruption, any private-key or premature
contributor-secret disclosure, uncontrolled resource exhaustion, or an abuse
event that cannot be safely bounded:

1. For a pool incident, disable the public Caddy pool route and stop the pool
   container. For a chain incident, block new public TCP/19446 at provider and
   host firewalls. Keep restricted admin access available.
2. Stop production and sync, then stop listener, pool, and explorer cleanly when
   their state may be involved.
3. Do not expose port 8080 or 8082 as a workaround. Keep the unaffected public
   route only when its read-only dependency and evidence are trustworthy.
4. Preserve rotating logs, status output, pool health/context, process/resource
   metrics, image identity, and separate read-only copies of chain and pool
   state. Do not publish source addresses or contribution bodies.
5. Notify participants through the established testnet channel with symptoms,
   the last trusted tip, and whether watchers should stop or retain their saved
   commitments; do not promise inclusion on recovery.
6. Reproduce and review the cause offline. Resume only with documented recovery,
   independent-node agreement, and a coherent chain/pool snapshot.

A testnet outage is preferable to silently serving a divergent chain. Incident
recovery does not authorize mainnet, deployment automation, a source push, or
DNS changes.

## 48-hour gate

Continue only when all of these are evidenced:

1. Seed and an independent node validate the same proof-of-golf genesis and
   released checkpoints, and agree on bodies/quality scores for the same branch.
   Both adopt an available strictly taller valid checkpoint-compatible branch;
   durable equal-height local choices are recorded.
2. DNS bootstrap, public TCP/19446, HTTPS explorer, and HTTPS pool health/context
   work off-host while direct TCP/8080 and TCP/8082 remain unreachable.
3. H16 puzzle-complexity retarget, fixed `bits`, exact slots, capped additive
   scores, H1-to-H2 maturity/transfer, solo under-minting,
   issued-versus-scheduled supply labels, and one node-free
   contribution-weighted commit/reveal payout cycle pass where their heights
   have been reached. The four-role smoke must show the co-op reveal alongside
   an ordinary signed transaction and a later B-to-C transaction crossing P2P
   before inclusion. If cadence has not reached a boundary, extend the gate
   rather than waive it.
4. Relay admission proves first-16 acceptance, seventeenth rejection, one slot
   per pubkey/context, and producer-owned contribution-first R8 selection without
   claiming Sybil resistance or guaranteed inclusion.
5. A chain/status reorg, exact receipt replay after restart, clean restart,
   hard-kill recovery, matching offline backups, and restore pass.
6. Explorer canonical/read-only/XSS checks and pool body/header/loopback
   boundaries pass.
7. Logs and metrics show bounded CPU, memory, disk, PIDs, file descriptors,
   traffic, database growth, and restart behavior for all four containers under
   public input.
8. Phase-one requests and pool rows contain no private key, blind, solution
   source, consensus share signature, or encoded share; no production key,
   backup, or mainnet state was used or disclosed.

Stop and preserve evidence for any unexplained tip disagreement, validation
mismatch, database error, sustained resource growth, or loss of network
control.

## Completion gate

The compressed public testnet exercise completes only when:

- it operated for 48 consecutive hours using the configured shorter testnet
  slots, with exact parent-plus-spacing timestamps and no future drift;
- seed and an independent node agree on a strictly taller valid
  checkpoint-compatible canonical branch when one is available; equal-height
  local incumbents and their durable behavior are recorded without score, hash,
  or arrival-metadata tie-breaks;
- nodes agree on replacement genesis, validated bodies on the same branch,
  next complexity and slot, capped additive scores, branch-aware issued supply,
  and UTXO-derived balances;
- H15, H16, and H17 prove puzzle-complexity retargeting, fixed network `bits`,
  cumulative score, and historical queries;
- one node-free commit/reveal/co-op cycle produces a valid contribution, direct
  contributor output, and contribution-weighted payout without custody;
- restart, hard-kill, matching chain/pool backup, and restore exercises recover
  without manual database editing or wallet loss;
- explorer and pool remain correct, TLS-only publicly, loopback-only internally,
  branch-coherent, and free of phase-one contributor secrets;
- bootstrap works from `seed.testnet.sigilcoin.lol:19446` without a hand-entered
  IP, and no production key or mainnet state entered the exercise.

Archive only sanitized evidence. This compressed gate does not establish
long-duration stability or settlement-grade security. Mainnet remains an
experimental hobby chain with cheap equal-height alternatives, missed-slot
takeover opportunities, partitions, parent-template manipulation, and reorgs
above the latest release checkpoint. H0 alone protects no post-genesis history.
