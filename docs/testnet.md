# Public testnet operator runbook

This runbook covers the 30-day public `sigilcoin-testnet` exercise. The stable
seed is a RackNerd host at `seed.testnet.sigilcoin.lol:19446`. Community nodes
may join and leave without permission.

Testnet coins are worthless. Never use a production key, address, seed phrase,
wallet backup, or unrevealed production material on testnet. Do not promote
this chain, its state, or its keys to mainnet, and do not push a mainnet launch
because a testnet gate passed.

## Frozen testnet parameters

- Chain: `sigilcoin-testnet`, selected with `--testnet`.
- DNS seed and P2P endpoint: `seed.testnet.sigilcoin.lol:19446`.
- P2P transport: TCP port `19446`, network magic `d3 7a 91 c5`.
- Address HRP: `tsgl`, producing `tsgl1...` addresses.
- Genesis marker: `SigilCoin public testnet reset - 2026-09-02`.
- Genesis timestamp: `1788307200` (`2026-09-02T00:00:00Z`).
- Genesis display id:
  `15447f3226699f537969cbea4b493bbbe25a4d856832bf28bce3e7df579e6ddc`.
- Genesis internal hash reported by node status:
  `dc6d9e57dfe7e3bc28bf3268854d5ae2bb3b494beacb6979539f6926327f4415`.
- Minimum spacing: one hour.
- Maximum future drift: five minutes.
- Explorer: `https://explorer.testnet.sigilcoin.lol` through Caddy to the
  container's loopback-only `127.0.0.1:8080` mapping.
- Co-op relay: `https://pool.testnet.sigilcoin.lol` through Caddy to the
  container's loopback-only `127.0.0.1:8082` mapping. This is a non-custodial
  public-testnet convenience service, not a consensus service or a mainnet pool.
- Exercise duration: 30 consecutive days, with day-7 and day-30 gates.

One hour is the network's target operating cadence and enforced minimum block
spacing. A header may lead a validating clock by at most five minutes, so that
allowance cannot make an immediate successor legal; the CLI waits until the
one-hour floor is within the drift window. This is not a participation schedule.
Community miners are not assigned slots, are not required to remain online, and
must not mine catch-up bursts.

## Reset cutover

This public testnet is a genesis reset, not a height activation. It starts at
height 0 from the marker and timestamp above. Heights from the previous public
testnet are not canonical on the reset chain. Old chain and relay databases,
histories, and backups of that state are incompatible. An archived wallet key
may still be a valid key format, but no old-chain balance, history, or relay
receipt carries over; keep both old state directories out of reset operation.

The network magic remains `d3 7a 91 c5`; magic alone therefore does not
distinguish an old node from the reset. Genesis validation is the boundary.
Upgrade every participant before reconnecting.

Before starting reset software on a host that ran the old testnet:

1. Stop listener, sync, explorer, pool, miners, contributors, and every CLI
   process that can open either database.
2. If the history is worth retaining, take verified offline chain and pool
   archives and label them with the old genesis and source revision.
3. Move both old state directories aside. Do not open them with the reset
   binary.
4. Create distinct empty chain and pool directories with restrictive
   permissions.
5. Start the reset stack and verify the display genesis id and relay context
   before adding peers, contributors, or miners.

For the Docker default, an operator may perform the non-destructive directory
cutover explicitly:

```sh
(
set -euo pipefail
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml stop
state_dir=${SIGIL_TESTNET_STATE_DIR:-"$PWD/state/testnet"}
pool_state_dir=${SIGIL_TESTNET_POOL_STATE_DIR:-"$PWD/state/testnet-pool"}
[[ $state_dir == /* ]] || state_dir=$PWD/${state_dir#./}
[[ $pool_state_dir == /* ]] || pool_state_dir=$PWD/${pool_state_dir#./}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
mv -- "$state_dir" "${state_dir}.pre-reset-$stamp"
if [[ -d $pool_state_dir ]]; then
  mv -- "$pool_state_dir" "${pool_state_dir}.pre-reset-$stamp"
fi
install -d -m 0750 "$state_dir"
install -d -m 0770 -g "$(id -g)" "$pool_state_dir"
docker compose --env-file .env -f compose.testnet.yml up -d
)
```

The fail-fast subshell never reaches restart after a failed stop, move, or
directory creation. Leave the stack down, preserve what exists, and investigate
before retrying.

Nothing in the node or deployment automation deletes old operator data. If an
archive is not wanted, disposal remains a deliberate operator action outside
startup.

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
SIGIL_TESTNET_POOL_STATE_DIR=./state/testnet-pool
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
miners, node status must report internal genesis hash
`dc6d9e57dfe7e3bc28bf3268854d5ae2bb3b494beacb6979539f6926327f4415`,
while explorer/API display order is
`15447f3226699f537969cbea4b493bbbe25a4d856832bf28bce3e7df579e6ddc`.
Any previous-testnet tip is a failed cutover.

## Community bootstrap

A current node automatically reads the canonical DNS seed. An operator may
also make bootstrap explicit:

```sh
sigilcoin peers add seed.testnet.sigilcoin.lol:19446 --testnet \
  --data-dir "$DATA"
sigilcoin peers test seed.testnet.sigilcoin.lol:19446 --testnet \
  --data-dir "$DATA"
sigilcoin sync --peer seed.testnet.sigilcoin.lol:19446 --testnet \
  --data-dir "$DATA" --iterations 1 --max-steps 4096 --max-blocks 256
```

A community operator may manually configure any trusted reachable testnet peer.
DNS is bootstrap, not an authority over consensus. Every node independently
validates the reset genesis and rules. A previous-testnet history, an `sgl1...`
address, or any genesis mismatch is grounds to stop; reset-testnet addresses
must begin `tsgl1...`.

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

The watcher defaults to `.sigilcoin-testnet`. Back up that disposable wallet
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
canonical digest order; the grindable digest does not decide admission.

A producer opts in explicitly:

```sh
sigilcoin mine --relay https://pool.testnet.sigilcoin.lol \
  --solution '(lambda(x)...)' --testnet
```

The miner requires the relay context to match its own active chain, applies the
normal commitment checks, fully revalidates every reveal against its actual
producer solution, deduplicates pubkeys/solutions, ranks eligible reveals by
contribution descending and pubkey ascending, and includes at most eight. The
relay's first-16 admission therefore does not promise one of the
consensus R8 share positions. If an explicitly configured relay is unavailable,
stale, malformed, oversized, or contradictory, mining fails; an operator may
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

1. Capture node status: tip height/hash, validated bodies, next complexity,
   peer successes/failures, last sync outcome, `issued-supply`, and
   `scheduled-supply-cap`.
2. Compare the seed with at least one independently operated node at the same
   height.
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

The seed operator targets roughly one accepted block per hour without catch-up
mining. Community blocks may change the observed count, so do not treat a
volunteer's missed hour as an incident or impose a participation roster.

## Consensus and interoperability evidence

Complete these before day 7 and repeat representative cases before day 30:

- Retarget: capture H15, H16, and H17 puzzle complexity and historical queries;
  the first 16-block boundary must agree across nodes.
- Maturity: show the H1 coinbase cannot be spent in H1 and is selectable for
  H2, then send a small amount between disposable `tsgl1...` wallets.
- Co-op: use the node-free watcher to carry a commitment at H and its
  authorized reveal at H+1; require authenticated non-zero `Q`, contribution
  in `1..4`, canonical output order, a direct contributor output spendable in
  the following block, the 10% contribution-weighted share pool, 5% carrier
  target, and the producer's fee and integer residual. Exercise every watcher
  status and a reorg that moves a receipt backward or makes it stale/missed.
- Four-role smoke: producer A mines D's commitment in H100; light contributor D
  has no node database and the pre-H100 relay row contains no private key,
  blind, solution source, consensus share signature, or encoded share; H101
  includes D's reveal and A's signed A-to-B transaction; ordinary node B sends
  its exact signed B-to-C transaction over a normal P2P session, A records it
  from a peer before mining H102, C receives the expected output, and B pays the
  fee; after reopening H102, H103 proves durability and A/B/C plus explorer
  agree on transactions, balances, payouts, and the full cooperative subsidy
  (zero unminted reserve).
- Solo issuance: require `floor(4*S/5)+F` in the only coinbase output and show
  the unused scheduled reserve as unminted.
- Supply: compare branch-aware `issued-supply` from active UTXOs with the
  separately labeled `scheduled-supply-cap`; issued supply may be lower after
  solo blocks and must never exceed the cap.
- Reorg: create equal-height siblings in a controlled window, verify rank by
  `(L, MB, SB)` with `Q` report-only, extend the selected incumbent, and require
  all nodes and explorer canonical views to converge after the explicit child
  without database editing.
- Restart: cleanly restart each service and preserve tip, balance, peers,
  explorer state, and idempotent pool receipts.
- Hard kill: once while the listener is idle, kill only one node, recover via
  normal SQLite opening/sync, and verify no lost validated state.
- Restore: restore matching reset-genesis chain and pool offline backups into
  empty test locations and verify status, disposable address, balance, sync,
  pool health/context, and explorer routes.
- Explorer and pool: check canonical block/PBE/score/Q/co-op and address
  HTML/JSON, issued-supply and scheduled-maximum labels, read-only behavior,
  relay status against exact block membership, and escaping of harmless
  hostile-looking graffiti such as `<b>test</b>`.

Never coordinate a fault drill that takes every reachable bootstrap node down
at once. Announce a bounded drill window, but do not assign mining obligations
to community members.

## Backups and restore

A plain filesystem archive is consistent only while listener, sync, explorer,
pool, and every command that can write either database are stopped. Keep chain
and pool state in distinct archives:

```sh
(
set -euo pipefail
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml stop
backup_dir=$HOME/sigilcoin-testnet-backups
install -d -m 0700 "$backup_dir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
state_dir=${SIGIL_TESTNET_STATE_DIR:-"$PWD/state/testnet"}
pool_state_dir=${SIGIL_TESTNET_POOL_STATE_DIR:-"$PWD/state/testnet-pool"}
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
4. Build and start the reviewed image without changing genesis or rules.
5. Compare status, resource use, public P2P, explorer routes, pool
   health/context, and active receipt projections with the pre-upgrade baseline
   and an independent node.

Rollback only to a reviewed image compatible with the chain database, pool
schema, and reset genesis. Never restore a previous-testnet database or backup
into either current state directory. If compatibility is uncertain, stop and
preserve both directories rather than trying binaries against them. Never make
an unreviewed source or mainnet push to repair public testnet.

## Incident shutdown

Shut down the affected public service immediately for suspected consensus
divergence, either database's corruption, any private-key or premature
contributor-secret disclosure, uncontrolled resource exhaustion, or an abuse
event that cannot be safely bounded:

1. For a pool incident, disable the public Caddy pool route and stop the pool
   container. For a chain incident, block new public TCP/19446 at provider and
   host firewalls. Keep restricted admin access available.
2. Stop mining and sync, then stop listener, pool, and explorer cleanly when
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

## Day-7 gate

Continue only when all of these are evidenced:

1. Seed and an independent node agree on canonical tip and validated bodies.
2. DNS bootstrap, public TCP/19446, HTTPS explorer, and HTTPS pool health/context
   work off-host while direct TCP/8080 and TCP/8082 remain unreachable.
3. H16 retarget, H1-to-H2 maturity/transfer, solo under-minting,
   issued-versus-scheduled supply labels, and one node-free contribution-weighted
   commit/reveal payout cycle pass where their heights have been reached. The
   four-role smoke must show the co-op reveal alongside an ordinary signed
   transaction and a later B-to-C transaction crossing P2P before inclusion.
   If cadence has not reached a boundary, extend the gate rather than waive it.
4. Relay admission proves first-16 acceptance, seventeenth rejection, one slot
   per pubkey/context, and miner-owned contribution-first R8 selection without
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

## Day-30 gate

The public testnet exercise completes only when:

- it operated for 30 consecutive days with the one-hour cadence used as a
  network target, not an enforced community participation schedule;
- seed and independent nodes finish on the same reset-genesis canonical tip,
  validated body count, next complexity, branch-aware issued supply, and
  UTXO-derived balances;
- every observed retarget and the one-block maturity boundary are correct;
- at least two node-free commit/reveal/co-op cycles from distinct periods
  produce valid authenticated `Q`, direct contributor outputs spendable in the
  following block, and contribution-weighted 10%/5% payouts without custody or
  inclusion promise;
- repeated chain/status reorg, restart, hard-kill, matching reset-genesis
  chain/pool backup, restore, upgrade, and rollback exercises recover without
  manual database editing or wallet loss;
- explorer HTML/JSON remains correct, read-only, TLS-only publicly, and
  XSS-safe, with issued-supply and scheduled-maximum labels and port 8080
  loopback-only;
- pool health/context and receipt status remain branch-coherent and TLS-only
  publicly, port 8082 stays loopback-only, first-16/R8 policy behaves as
  documented, and logs/backups disclose no phase-one contributor secret;
- censorship, authenticated Sybil slot filling, malformed/rate-limited traffic,
  uptime, resources, and both databases' growth have a reviewed 30-day record
  with no unresolved trend or incident;
- bootstrap from `seed.testnet.sigilcoin.lol:19446` works for a fresh community
  node without a hand-entered IP;
- no production key or mainnet state entered the exercise.

Archive only sanitized evidence. Passing day 30 is a prerequisite for the
separate mainnet soak, not approval to launch, push, deploy mainnet, or reuse
any testnet key or database.
