# SigilCoin operations runbook

This runbook covers the replacement proof-of-golf seed and explorer on NixOS.
For Docker, the public testnet relay, and the supervised scheduled producer,
use [deployment.md](../docs/deployment.md). These are operator procedures, not
a claim that this replacement deployment has already passed live validation.

The launched nonce-PoW mainnet was retired before height 1 because its compute
burn contradicted the project's intent. Its launch identity and evidence remain
historical and superseded in [LAUNCH.md](../LAUNCH.md). Replacement networks
start at height 0 with fresh genesis identities and fresh state. Never open a
retired database with the replacement binary or count the old launch as
approval for this one.

## Consensus an operator needs to know

- The puzzle VM and producer validity `L <= par` remain. The generated at-par
  witness is a valid fallback, not an invitation to search for a header hash.
- `savings = min(8, max(0, par - L))`; a non-genesis block scores `1 + savings`,
  from 1 to 9. Genesis contributes 0. Only strictly greater cumulative score
  replaces the durable active incumbent. Equality has no global hash tie-break.
- Every header time is exactly `parent.time + network spacing` and must not be
  in the validating node's future. Mainnet spacing is exactly 86,400 seconds;
  regtest retains its configured shorter slots. `next-slot-time` is a UTC epoch
  timestamp, not a suggestion to change the clock.
- Headers remain 80 bytes. Nonce is 0, `bits` is fixed at the network's pow-limit
  compatibility value, and there is no hash target check or hash-difficulty
  retarget. Non-genesis coinbase lock-time is 0, graffiti is empty, and
  sequence/version are canonical.
- Build the complete candidate once per attempt. Puzzle-complexity retargeting,
  co-op commitments, strict under-personalized-par shares, ordinary
  transactions, and payouts remain.

This is a hobby chain, not settlement-grade security. Cheap historical
re-optimization permits deep rewrites, parent-template manipulation remains
possible, and equal-score local forks can persist. Neither daily slots nor a
confirmation count makes an old payment final.

## What is in deploy/

| File | Purpose |
| --- | --- |
| `flake.nix` | Packages, the NixOS module, and deployment checks |
| `package.nix` | Sigil toolchain and `sigilcoin` / `sigilcoin-explorer` derivations |
| `module.nix` | `services.sigilcoin` and `services.sigilcoin-explorer` |
| `genesis-constants.sgl` | Generates the reviewed replacement genesis constants |
| `RUNBOOK.md` | This file |

## Wiring it into a host

Keep `sigil`, `sigil-bitcoin`, and `sigil-coin` as sibling checkouts. The flake
uses revision-pinned local inputs; the local and Docker helpers override them
from the detected sibling layout. Use the reviewed sibling revisions together:
consensus, cumulative-score persistence, and durable parent validation cross
the package boundary. Do not substitute an old dependency pin because it
compiles. A local-only revision is not a reproducible public release until its
source and dependency revisions are published.

Add the deployment flake as a host input; `?dir=deploy` is required:

```nix
inputs.sigil.url = "path:/workspace/sigil";
inputs.sigil.flake = false;
inputs.sigil-bitcoin.url = "path:/workspace/sigil-bitcoin";
inputs.sigil-bitcoin.flake = false;
inputs.sigilcoin.url = "git+file:///workspace/sigil-coin?dir=deploy";
inputs.sigilcoin.inputs.sigil.follows = "sigil";
inputs.sigilcoin.inputs.sigil-bitcoin.follows = "sigil-bitcoin";
```

Build on the build host using the reviewed inputs:

```sh
cd /path/to/workspace/sigil-coin/deploy
nix build .#sigilcoin --print-build-logs \
  --override-input sigil ../../sigil \
  --override-input sigil-bitcoin ../../sigil-bitcoin
timeout 5 ./result/bin/sigilcoin version
timeout 5 ./result/bin/sigilcoin-explorer --version
```

One derivation ships both binaries. A version string alone does not prove
genesis or consensus compatibility. Record the exact source and image/store
identity alongside the reviewed all-network genesis output; do not compare a
new build to a pasted historical store hash.

Import the module and explicitly select the new state directory:

```nix
{
  imports = [ inputs.sigilcoin.nixosModules.default ];
  nixpkgs.overlays = [ inputs.sigilcoin.overlays.default ];

  services.sigilcoin = {
    enable = true;
    chain = "sigilcoin-main";
    dataDir = "/var/lib/sigilcoin-proof-of-golf";
    listen.bind = "0.0.0.0";
    openFirewall = true;
    peers = [ "seed2.example.org:19444" ];
  };

  services.sigilcoin-explorer.enable = true;
}
```

Replace the example peer with an approved reachable replacement-network peer.
This mainnet configuration is not launch approval. The module supports mainnet
and regtest; use the Docker/local workflow for public testnet. Keep regtest
loopback-only. Put a TLS reverse proxy in front of the explorer at
`explorer.sigilcoin.lol`; the explorer itself stays on `127.0.0.1:8080`.

| Port | Use |
| --- | --- |
| 19444/tcp | Mainnet P2P; opened by `openFirewall = true` |
| 19445/tcp | Regtest P2P; local only, never expose it |
| 8080/tcp | Explorer loopback origin; do not expose it directly |

Restrict SSH independently to operator sources or a VPN. A public P2P bind
does not authorize public administration or direct explorer access.

## Retired-state cutover

On a host that ran the retired network, stop every database user, including any
external producer, contributor, observer, or one-shot CLI, before switching
software. Archive the old chain and wallet state offline with its old genesis
and source revision. It is historical evidence, not a backup to restore into
the replacement network.

For the retired NixOS default `/var/lib/sigilcoin`, preserve it and require an
unused replacement path:

```sh
(
set -euo pipefail
sudo systemctl stop sigilcoin-explorer sigilcoin-sync sigilcoin-listen
sudo test ! -e /var/lib/sigilcoin-proof-of-golf
stamp=$(date -u +%Y%m%dT%H%M%SZ)
sudo mv /var/lib/sigilcoin "/var/lib/sigilcoin.retired-nonce-pow-$stamp"
sudo install -d -o sigilcoin -g sigilcoin -m 0750 \
  /var/lib/sigilcoin-proof-of-golf
)
```

Substitute the actual old `dataDir` if it differed. Do not run this archive
step on a new host with no retired state. The subshell never restarts services;
on a failure leave the host stopped and preserve what exists. Keep a verified
encrypted offline copy of the retired directory. Do not copy its database,
wallet, balances, or commitment receipts into the new directory.

The NixOS default is `/var/lib/sigilcoin-proof-of-golf`. Docker defaults are
`state/mainnet-proof-of-golf`, `state/testnet-proof-of-golf`, and
`state/testnet-pool-proof-of-golf`; the local helpers use
`deploy/state/local-mainnet-proof-of-golf` or
`deploy/state/local-testnet-proof-of-golf`. Renaming an old database directory
to one of these names does not make it compatible.

## First-time bring-up

After the archive boundary and explicit launch approval:

```sh
sudo nixos-rebuild switch --flake /path/to/host-config
systemctl status sigilcoin-listen sigilcoin-sync
sudo -u sigilcoin sigilcoin status --chain sigilcoin-main \
  --data-dir /var/lib/sigilcoin-proof-of-golf
```

The listener must be active and own port 19444 directly; there is no socket
proxy. A fresh database reports the replacement genesis at height 0, cumulative
score 0, and no issued supply. Compare the internal and display-order genesis
ids with the reviewed all-network output from `deploy/genesis-constants.sgl`.
A matching chain name or wire handshake is insufficient. Stop for any retired
genesis or unexpected history before connecting more peers.

Create a wallet only if this node actually needs one:

```sh
sudo -u sigilcoin sigilcoin address --chain sigilcoin-main \
  --data-dir /var/lib/sigilcoin-proof-of-golf
```

The node's fresh key determines its address; do not copy an example address's
key or use a testnet wallet. The data directory is mode `0750`, owned
`sigilcoin:sigilcoin`. The private key lives at `wallet/wallet.key`, mode `0600`,
inside `wallet/`, mode `0700`. Back it up before receiving funds; there is no
seed phrase or remote recovery.

The explorer's primary group is the node's group so it can traverse the data
directory but not `wallet/`. With `PrivateUsers=true`, substituting a
supplementary group can fail closed. Its unit uses
`ReadOnlyPaths=/var/lib/sigilcoin-proof-of-golf`; do not grant it key access or
write access to repair an unrelated failure.

## Scheduled production

The NixOS listener and sync units do not produce blocks. A manual producer first
synchronizes, then asks for the current puzzle and scheduled time:

```sh
sudo -u sigilcoin sigilcoin puzzle --chain sigilcoin-main \
  --data-dir /var/lib/sigilcoin-proof-of-golf
```

At or after the reported `next-slot-time`, submit one complete at-par candidate:

```sh
sudo -u sigilcoin sigilcoin mine --chain sigilcoin-main \
  --data-dir /var/lib/sigilcoin-proof-of-golf
```

The CLI name remains `mine`, but it does not search. With no `--solution`, it
uses the generated valid at-par witness for score 1. Supply `--solution` only
for a valid current-context program you have actually shortened. Omitting
`--address` uses or creates the node's wallet; a seed using an external payout
address should pass its reviewed `--address` instead and need not hold a key.
An early-slot refusal means wait, not change a timestamp or retry in a tight
loop. A tip change requires a new parent-specific puzzle and candidate.

For supervised production, use the Docker procedure in
[deployment.md](../docs/deployment.md#scheduled-mainnet-production).
`start-mainnet-miner.sh`, the `mainnet-miner` profile, and the `miner` service
retain their operator-facing names, but run `producer-loop`. It waits for
`next-slot-time`, checks the validated tip, and submits once; `MINE_INTERVAL=60`
is the idle polling/retry delay, not the 86,400-second consensus spacing.
Sleeping and low CPU are normal. Do not point two differently managed stacks
at one live state directory.

## Is the node healthy?

```sh
sudo -u sigilcoin sigilcoin status --chain sigilcoin-main \
  --data-dir /var/lib/sigilcoin-proof-of-golf
journalctl -u sigilcoin-sync -u sigilcoin-listen -n 50
```

Read deltas, not just the last error. `sync-stage` and `sync-last-error` describe
the last outcome; an unreachable peer can leave a sticky error after another
peer succeeds. Compare two status readings and a separate node.

| Signal | Interpretation |
| --- | --- |
| Peer successes/failures | Successes should advance; growing failures with no new success means connectivity needs attention. |
| Validated tip and score | Compare branch identity and cumulative score, not height alone. An equal-score local incumbent may legitimately differ. |
| `next-slot-time` | No new mainnet block is admissible before its exact daily slot; a due slot may remain empty without a producer. |
| `best-height` vs `best-block-height` | Headers persistently ahead of validated bodies indicate download or validation lag. |
| `pending-blocks` | Persistently nonzero indicates unresolved body validation/download work. |
| Supply | Require `issued-supply <= scheduled-supply-cap <= max-supply` and agreement on the same active branch. |

Check P2P reachability from outside the host:

```sh
nc -vz seed.sigilcoin.lol 19444
```

Review CPU, memory, disk, file descriptors, restart counts, and malformed public
input. Low-CPU production does not make every hostile-but-valid puzzle evaluation
cheap. Ordinary peer hangups are not by themselves a seed failure.

`next-reward` is scheduled subsidy, not an exact payout. For subsidy `S` and
fees `F`, a solo block mints `floor(4*S/5)+F`; a cooperative block mints `S+F`,
targets 10% for contribution-weighted shares and 5% for the parent carrier, and
gives fees and integer residuals to the producer. The unused solo reserve is
unminted, so issued supply can trail the scheduled cap.

## Adding peers

Configure peers declaratively:

```nix
services.sigilcoin.peers = [ "seed2.example.org:19444" ];
```

Or add an approved reachable peer by hand:

```sh
sudo -u sigilcoin sigilcoin peers add seed2.example.org:19444 \
  --chain sigilcoin-main --data-dir /var/lib/sigilcoin-proof-of-golf
```

`peers list`, `peers remove HOST:PORT`, and `peers test HOST:PORT` use the same
chain/data flags. Peer registration is idempotent. IPv6 endpoints need brackets,
for example `[2001:db8::1]:19444`. DNS is bootstrap, not a consensus authority;
every peer must validate the replacement genesis.

## Backup and restore

Stop all writers and readers before a plain filesystem archive. Stop any
producer or contributor outside these units as well. Back up the complete
current state, including its wallet and local commitment records:

```sh
(
set -euo pipefail
sudo systemctl stop sigilcoin-explorer sigilcoin-sync sigilcoin-listen
backup_dir=/var/backups/sigilcoin-proof-of-golf
sudo install -d -m 0700 "$backup_dir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
sudo tar -C /var/lib/sigilcoin-proof-of-golf \
  -czf "$backup_dir/$stamp-chain.tgz" .
sudo chmod 0600 "$backup_dir/$stamp-chain.tgz"
sudo sha256sum "$backup_dir/$stamp-chain.tgz"
sudo systemctl start sigilcoin-sync sigilcoin-listen
sudo systemctl start sigilcoin-explorer
)
```

Record the checksum and replacement genesis/source identity with the archive.
Encrypt it and keep it offline; it contains secrets and must not enter source,
logs, chat, or the world-readable Nix store. A live copy can contain torn SQLite
state. The fail-fast subshell leaves services stopped if archiving fails.

Restore only a verified backup from this replacement genesis. Set `BACKUP` to
that archive's absolute path, stop all other database users, and preserve the
current directory rather than overwriting it:

```sh
(
set -euo pipefail
: "${BACKUP:?Set BACKUP to a verified replacement-genesis archive}"
sudo systemctl stop sigilcoin-explorer sigilcoin-sync sigilcoin-listen
stamp=$(date -u +%Y%m%dT%H%M%SZ)
sudo mv /var/lib/sigilcoin-proof-of-golf \
  "/var/lib/sigilcoin-proof-of-golf.before-restore-$stamp"
sudo install -d -o sigilcoin -g sigilcoin -m 0750 \
  /var/lib/sigilcoin-proof-of-golf
sudo tar -C /var/lib/sigilcoin-proof-of-golf -xzf "$BACKUP"
sudo -u sigilcoin sigilcoin status --chain sigilcoin-main \
  --data-dir /var/lib/sigilcoin-proof-of-golf
sudo systemctl start sigilcoin-sync sigilcoin-listen
sudo systemctl start sigilcoin-explorer
)
```

Compare restored genesis, tip, cumulative score, wallet permissions, and balance
with the archived evidence and a replacement-network peer. Never restore a
retired nonce-PoW archive into this directory. A fresh re-sync can replace lost
chain data, but it cannot recover a lost wallet key.

Coinbase maturity remains one block: an output created at H may be spent in
H+1. `balance` considers the candidate after the current tip. The bundled
mainnet wallet separately waits six confirmations before selecting coinbase
inputs; test networks select at one. Those wallet delays are policy, not
settlement guarantees against a later higher-score rewrite.

## Upgrading

Record the reviewed source/dependency revisions, build identity, and genesis.
Stop all database users and take an offline replacement-network backup before
switching the host configuration. Afterward compare status, scores, peers,
explorer routes, and balances on the same active branch.

`nixos-rebuild switch --rollback` rolls back software, not state. Only use a
generation compatible with the current replacement genesis, schema, and
consensus. The retired nonce-PoW generation is not a rollback target. Never try
different binaries against an uncertain database; preserve it and recover to
an explicitly compatible empty location.

Puzzle language/generation, emission, solution validity, scheduling, and fork
choice are consensus. Compare changes with [consensus.md](../docs/consensus.md);
a version string and a successful `status` command cannot establish
compatibility.

## When the chain stalls

Mainnet has exact daily header slots, not a probabilistic cadence. Publication
can be late when nobody is producing; a late block still uses its scheduled
time. Work through:

1. Check `next-slot-time` and the host's UTC clock. A future slot means wait;
   zero future drift makes clock correctness important.
2. Check that a producer is running or deliberately submit one due at-par
   candidate. No target, nonce, or coinbase search is required.
3. Check peers and `sync-last-error`; distinguish transport failures from
   explicit validation refusals.
4. If headers arrive but bodies remain pending, inspect validation limits and
   resource pressure. The module exposes `services.sigilcoin.sync.validationBlocks`
   and `services.sigilcoin.cpuQuota`; these bound processing, not fork weight.
5. If corruption is suspected, stop every database user, preserve the complete
   state and logs, and recover from a matching backup or a fresh replacement
   re-sync. Never delete the evidence or reuse retired state.

### Reorgs

Strictly greater cumulative validated score wins, even at a lower height.
Equal-score branches retain the durable active incumbent across restart, so two
nodes can disagree locally without either violating consensus. There is no
global height/hash tie-break and no special finality once a child appears.

A reorg rolls back orphaned UTXOs and reconnects the winning branch, with
affected mempool transactions revalidated. A spend whose orphaned funding
output no longer exists cannot remain spendable. Co-op receipts follow exact
active-branch commitment/reveal membership and can move backward or become
stale/missed; ordinary payouts remain vulnerable to later rewrites.

Record the competing ids, cumulative scores, and status from both sides.
Investigate unexplained divergence or repeated deep rewrites without claiming
they are computationally expensive. There is no `invalidateblock` operator
escape hatch and no confirmation count that makes this settlement-grade.

## Known rough edges

- `sigilcoin listen --max-connections 0` is the daemon mode used by the module.
  A positive connection budget is bounded operation, not a seed service. The
  accept timeout is a poll interval in daemon mode; ordinary disconnects should
  not terminate the listener.
- Listener and sync share one SQLite database. The driver retries contended
  steps, but sustained write contention still needs investigation. Do not add
  more writers to cure busy/locked errors.
- The explorer uses `--host`, not the node CLI's `--bind`; it selects test
  chains with `--regtest` or `--testnet`, not `--chain NAME`. Its unit enforces
  read-only access rather than relying on a read-only command-line flag.
- Explorer routes remain `/`, `/blocks`, `/difficulty`, `/block/<height|id>`,
  and `/address/<address>`, with JSON under `/api/summary`, `/api/blocks`,
  `/api/difficulty`, `/api/block/<height|id>`, and `/api/address/<address>`.
  `/api/difficulty` describes puzzle complexity, not a hash search target.
  Block JSON has `golf` fields `claimed_length`, `par`, `savings`,
  `block_score`, and `chain_score`; summary exposes `next_slot` and
  `chain_score`. Compare data on the same active branch.
- A read-only explorer cannot recover a hot SQLite journal after a killed
  writer. Do not delete the journal or make the explorer writable. Let a node
  open the database normally, then restart the explorer:

  ```sh
  sudo -u sigilcoin sigilcoin status --chain sigilcoin-main \
    --data-dir /var/lib/sigilcoin-proof-of-golf
  sudo systemctl restart sigilcoin-explorer
  ```

  Preserve state and investigate if recovery fails. Unit ordering after sync
  helps on normal startup, but an independently restarted explorer may still
  need the writable recovery step.
