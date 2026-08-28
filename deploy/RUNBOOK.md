# SigilCoin operations runbook

Covers the seed node and the explorer on NixOS. Every command here was run
against the `sigilcoin 0.1.0` binaries this flake builds, except the few
marked UNVERIFIED. Anything that can block a terminal is shown wrapped in
`timeout`; run it that way.

The systemd units themselves were generated and inspected, not started: this
sandbox has no root, so `systemctl` behaviour is argued from the unit files
and from systemd's documented `PrivateUsers` mapping rather than from a live
boot. Treat the first `nixos-rebuild switch` as the moment they are proven.

Contents: [what is here](#what-is-in-deploy) ·
[wire it up](#wiring-it-into-a-host) · [first bring-up](#first-time-bring-up) ·
[health](#is-the-node-healthy) · [peers](#adding-peers) ·
[backup](#backup-and-restore) · [upgrade](#upgrading) ·
[stalls and reorgs](#when-the-chain-stalls) · [known rough edges](#known-rough-edges)

## What is in deploy/

| File | Purpose |
| --- | --- |
| `flake.nix` | Packages, the NixOS module, and a `nix flake check` that builds the binaries and the systemd units |
| `package.nix` | Derivations: the Sigil toolchain and the `sigilcoin` / `sigilcoin-explorer` binaries |
| `module.nix` | `services.sigilcoin` and `services.sigilcoin-explorer` |
| `genesis-constants.sgl` | Prints the genesis constants for a quote and timestamp |
| `RUNBOOK.md` | This file |

The launch checklist is `../LAUNCH.md`.

## Wiring it into a host

Nothing outside `deploy/` was changed, and the workspace flake at
`/home/trev/Workspace/sigil/flake.nix` is untouched. The operator has to do
two things.

**1. Add the flake as an input** to the host configuration. The `?dir=deploy`
is not optional: `flake.nix` lives in `deploy/` but its source is the
sigil-coin repository above it, which it reads through
`self.sourceInfo.outPath`. Rooting the flake at `deploy/` instead throws an
error that says so rather than building the wrong thing.

```nix
inputs.sigilcoin.url = "git+file:///home/trev/Workspace/sigil/sigil-coin?dir=deploy";
# or, once the repo is published:
#   inputs.sigilcoin.url = "github:trevarj/sigil-coin?dir=deploy";
```

The two sibling checkouts are flake inputs pinned by revision
(`git+file:///…/sigil` and `git+file:///…/sigil-bitcoin`), as are the
fourteen `from-git` Sigil libraries the two dependency graphs need. That is
what lets the build sandbox stay offline, and it is why there is no
`depsHash` to fill in any more. Bump a sibling with `--override-input` or
`nix flake update`; see the comment block at the top of `flake.nix`.

There is no separate explorer package: `sigil-coin-explorer` declares
`bundle-name: "sigilcoin-explorer"` and bundles out of the same `sigil build`
as the CLI, so one derivation ships `bin/sigilcoin` and
`bin/sigilcoin-explorer`.

The build is real, not evaluated. Verified here:

```sh
cd /home/trev/Workspace/sigil/sigil-coin/deploy
nix build .#sigilcoin --print-build-logs
```

```
sigilcoin> buildPhase completed in 6 minutes 17 seconds
sigilcoin> Running phase: installCheckPhase
```

```sh
readlink -f result   # => /nix/store/r20gic6jsq8dz9ayc22xn2svxim87aka-sigilcoin-0.1.0
ls result/bin        # => sigilcoin  sigilcoin-explorer
./result/bin/sigilcoin version
```

```
sigilcoin 0.1.0
```

and `nix flake check`, run from inside `deploy/`:

```
running 6 flake checks...
all checks passed!
```

The count is what is left to build, not a fixed number: six on a cold store
(this flake's `sigilcoin-runs`, which builds both binaries and runs
`sigilcoin version`, plus `module-eval`, plus the four systemd unit files the
module generates), two on a warm one. What matters is that it is not zero —
`running 0 flake checks` means nothing was checked.

`deploy/` and `LAUNCH.md` must be at least `git add`ed for any of this to
work; Nix refuses to read a file the git tree does not track, and reports
`Path 'deploy/flake.nix' … is not tracked by Git`.

**2. Import the module and set options:**

```nix
{
  imports = [ inputs.sigilcoin.nixosModules.default ];
  nixpkgs.overlays = [ inputs.sigilcoin.overlays.default ];

  services.sigilcoin = {
    enable = true;
    chain = "sigilcoin-main";
    listen.bind = "0.0.0.0";        # the CLI default is 127.0.0.1: serves nobody
    openFirewall = true;            # opens 19444/tcp
    peers = [ "seed2.example.org:19444" ];
  };

  services.sigilcoin-explorer.enable = true;   # binds 127.0.0.1:8080
}
```

Put a TLS reverse proxy in front of the explorer. Nothing here terminates TLS.

### Ports and firewall

| Port | Chain | Who needs it open |
| --- | --- | --- |
| 19444/tcp | `sigilcoin-main` | Everyone. `openFirewall = true` opens it. Held by `sigilcoin-listen-proxy.socket`, not by the node process. |
| 19544/tcp | `sigilcoin-main` | Loopback only. `listen.internalPort`, where `sigilcoin listen` actually binds. Never open it. |
| 19445/tcp | `sigilcoin-regtest` | Local only. Never expose it. |
| 8080/tcp | explorer | Localhost only; reverse-proxy it, do not open the port. |

Mainnet magic is `8f d1 c0 a5`, regtest is `a5 c0 d1 8f`, and the user agent
is `/sigilcoin-node:0.1.0/`.

### Where state lives

`/var/lib/sigilcoin`, mode 0750, owned `sigilcoin:sigilcoin`:

| Path | What it is |
| --- | --- |
| `sigilcoin-main.sqlite` | Headers, blocks, UTXOs, mempool, peer table |
| `wallet.key` | 32-byte secret, hex, mode 0600 |

The explorer's PRIMARY group is `sigilcoin`, so it can read the directory and
the database and cannot read `wallet.key` (0600, owned by the node user). Its
unit also carries `ReadOnlyPaths=/var/lib/sigilcoin`, so read-only is
enforced by the kernel rather than by a flag the explorer promises to honour.

Primary group rather than supplementary is load-bearing. Every unit here runs
with `PrivateUsers=true`, and in that user namespace only the unit's own UID
and GID are mapped: a supplementary GID arrives as `65534(nogroup)` and
`/proc/self/setgroups` reads `deny`, so it cannot be recovered. An explorer
configured with `extraGroups = [ "sigilcoin" ]` fails closed and cannot open
the database at all. If you change the explorer's `Group`, check that it can
still read `<dataDir>` before deciding the explorer is broken.

> **wallet.key is the coins.** Lose it and every coin paid to that address is
> gone: there is no seed phrase, no recovery, no second copy anywhere. Never
> commit it, never paste it into a terminal you are sharing, never put it in
> a bug report, and never let it into the Nix store, which is world-readable.

## First-time bring-up

```sh
sudo nixos-rebuild switch --flake /path/to/host-config
systemctl status sigilcoin-listen-proxy.socket sigilcoin-listen sigilcoin-sync
sudo -u sigilcoin sigilcoin status --chain sigilcoin-main --data-dir /var/lib/sigilcoin
```

`sigilcoin-listen-proxy.socket` must be `active (listening)`. It is the unit
that owns port 19444; the node process itself binds only loopback.

A node that has done nothing but open its database reports genesis, which is
verified output from a fresh mainnet data directory:

```
chain: sigilcoin-main
best-height: 0
best-hash: 4dc1914abc4af386d05906338d7823fffdef2f469f0aad0ff6fbd635528b19ff
best-work: 53872
best-header-time: 1785542400
headers: 1
blocks: 0
validated-blocks: 0
best-block-height: 0
best-block-hash: 4dc1914abc4af386d05906338d7823fffdef2f469f0aad0ff6fbd635528b19ff
mempool: 0
peers: 0
peer-successes: 0
peer-failures: 0
pending-blocks: 0
sync-stage: idle
sync-last-error:
tip-solution-bytes: 49
next-height: 1
next-reward: 1.00000000 SGL
issued-supply: 0.00000000 SGL
max-supply: 143029.99991970 SGL
```

`best-hash` is the internal byte order. The display id humans quote is that
string reversed: `ff198b5235d6fbf60fad0a9f462feffdff23788d330659d086f34abc4a91c14d`.
Both are placeholders until the launch-day quote is chosen; see `../LAUNCH.md`.

Creating the node's own address writes `wallet.key`:

```sh
sudo -u sigilcoin sigilcoin address --chain sigilcoin-main --data-dir /var/lib/sigilcoin
```

```
address: sgl1qt7d93uz6att7y2934szv6gdu98e76nwrrn95a6
chain: sigilcoin-regtest
key-file: /tmp/sgl-verify/wallet.key
```

(that sample is from a regtest run; the mainnet form is the same shape, `sgl1…`)

Back the key up before the node earns anything. See
[Backup and restore](#backup-and-restore).

## Is the node healthy?

```sh
sudo -u sigilcoin sigilcoin status --chain sigilcoin-main --data-dir /var/lib/sigilcoin
journalctl -u sigilcoin-sync -u sigilcoin-listen -u sigilcoin-listen-proxy -n 50
```

**Read deltas, not absolutes.** `sync-stage` and `sync-last-error` are sticky:
they record the LAST outcome, not the current one, and a single unreachable
peer in the table is enough to leave `sync-stage: failed` and a populated
`sync-last-error` on a node that is otherwise perfectly healthy. "Watch for
`sync-last-error` to be empty" is not a criterion anyone can meet. Take two
`status` readings at least ten minutes apart and compare them.

| Signal | Healthy | Unhealthy |
| --- | --- | --- |
| `peer-successes` | strictly larger in the second reading | flat across two readings while `peer-failures` grows — the node is reaching nobody |
| `peer-failures` | may grow; growth alone means nothing | growing while `peer-successes` is flat |
| `sync-last-error` | any value, as long as `peer-successes` moved after it | unchanged for hours AND `peer-successes` flat; then the text names the cause |
| `validated-blocks` | rising about once a day; identical to the second node at the same height | flat for more than ~2 days, or DIFFERENT from another node at the same height (that is a consensus split, not an ops problem) |
| `best-height` vs `best-block-height` | within a few blocks | headers far ahead of validated bodies: block download or validation is behind |
| `pending-blocks` | 0, or briefly non-zero | persistently non-zero means validation is stuck |
| `peers` | at least 1 | 0 means nothing was ever configured |
| `issued-supply` | rises, never exceeds `max-supply` | anything above 143029.99991970 SGL is a consensus bug |

Verified contrast, both from this build. A sync that reached its peer:

```
peers: 1
peer-successes: 1
peer-failures: 0
sync-stage: idle
sync-last-error:
```

and a sync against a peer that is not there:

```
peers: 1
peer-successes: 0
peer-failures: 1
sync-stage: failed
sync-last-error: connect failed: peers: could not connect to 127.0.0.1 (p2p-socket-connect-timeout: connection refused).
```

The difference that matters is `peer-successes`, not the presence of an error
string.

**Journal lines that look like faults and are not.** The listener reports how
each inbound connection ended, and the normal end of a Bitcoin-style
conversation is the peer hanging up:

```
peer-served: 4 answered=1 ended=p2p-read-envelope: unexpected end of stream
```

Measured 6/6 on ordinary connects, hangups and garbage writes. Treat these as
traffic, not errors. `p2p-read-envelope: payload too large` on the same line
is a malformed peer being rejected — also normal, and also not a fault of the
seed.

`tip-solution-bytes` is the winning program length at the tip, and
`next-reward` is what the next block pays. Neither is a health signal; they
are the game.

**Is the seed actually reachable?** The only real answer comes from off-host:

```sh
nc -vz seed.<yourdomain> 19444
```

On the host itself, `systemctl is-active sigilcoin-listen-proxy.socket`
answers whether the kernel is holding the port. That socket stays active
across every restart of the node process, which is the point of it.

## Adding peers

Declaratively, in the host config (re-asserted on every start, idempotent):

```nix
services.sigilcoin.peers = [ "seed2.example.org:19444" "203.0.113.10:19444" ];
```

By hand, verified against the running binary:

```sh
sudo -u sigilcoin sigilcoin peers add 203.0.113.10:19444 \
  --chain sigilcoin-main --data-dir /var/lib/sigilcoin
```

```
203.0.113.10:19444 source=manual score=0 failures=0 last-result= last-error=
```

`peers list`, `peers remove HOST:PORT` and `peers test HOST:PORT` take the
same shape. `peers test` dials the peer and reports the result on the same
line. Adding a peer twice is a no-op, verified. An empty table prints:

```
no peers configured; add one with `sigilcoin peers add HOST:PORT`
```

IPv6 needs brackets: `[2001:db8::1]:19444`.

## Backup and restore

Two files matter, and they matter for different reasons. The database is
replaceable by re-syncing from the network. `wallet.key` is not replaceable
by anything.

### Backup

```sh
sudo systemctl stop sigilcoin-sync sigilcoin-listen
sudo install -d -m 0700 /var/backups/sigilcoin
sudo cp -a /var/lib/sigilcoin/sigilcoin-main.sqlite /var/backups/sigilcoin/
sudo cp -a /var/lib/sigilcoin/wallet.key /var/backups/sigilcoin/
sudo systemctl start sigilcoin-sync sigilcoin-listen
```

Stopping first is not optional for a plain `cp`: the database is not in WAL
mode and a copy taken mid-write can be torn. For an online copy use
`sqlite3 <db> ".backup <dest>"` instead (UNVERIFIED here; `sqlite3` is not
installed by this module).

Store the wallet backup encrypted and offline. It is 65 bytes of hex; a
printed copy in a safe is a legitimate answer for a chain that mints one
block a day.

### Restore

```sh
sudo systemctl stop sigilcoin-sync sigilcoin-listen
sudo install -o sigilcoin -g sigilcoin -m 0600 \
  /var/backups/sigilcoin/wallet.key /var/lib/sigilcoin/wallet.key
sudo install -o sigilcoin -g sigilcoin -m 0644 \
  /var/backups/sigilcoin/sigilcoin-main.sqlite /var/lib/sigilcoin/
sudo systemctl start sigilcoin-sync sigilcoin-listen
sudo -u sigilcoin sigilcoin balance --chain sigilcoin-main --data-dir /var/lib/sigilcoin
```

`balance` prints the address, `outputs`, `balance`, `spendable` and
`immature`. Coinbase outputs are immature for 100 blocks, which on a
one-block-a-day chain is about 100 days: a freshly restored node that mined
recently will show its reward under `immature`, not `spendable`. That is
correct, not a restore failure.

Losing only the database: delete it and let the node re-sync from peers. The
wallet key is independent of it, and the balance reappears once the chain is
back.

## Upgrading

```sh
# 1. Build and check first, on the build host
cd /path/to/sigil-coin/deploy && nix flake check
nix build /path/to/sigil-coin?dir=deploy#sigilcoin

# 2. Confirm the binary is the version you expect
./result/bin/sigilcoin version     # => sigilcoin 0.1.0

# 3. Roll it out
sudo nixos-rebuild switch --flake /path/to/host-config

# 4. Confirm the chain survived the restart
sudo -u sigilcoin sigilcoin status --chain sigilcoin-main --data-dir /var/lib/sigilcoin
```

`nixos-rebuild switch` restarts both units. Rollback is `nixos-rebuild
switch --rollback`; the data directory is untouched by either direction.

**Before upgrading, check what changed.** The puzzle language, the puzzle
generator, emission, the solution rules and fork choice are consensus. A
release that changes any of them is a hard fork, not an upgrade: every node
must run it, and a node left behind will diverge silently rather than error.
`sigilcoin status` does not report a consensus version, so this check is
manual — read the release notes, and if the puzzle generator's version number
moved, treat it as a fork.

## When the chain stalls

Expected cadence is one block per day. The enforced rule is not the cadence
but the floor: 72000 seconds (20 hours) minimum between blocks on mainnet,
with a 7200-second future-drift allowance. Twenty-six hours without a block
is unremarkable. Three days is not.

Work through it in this order:

1. **Is anyone mining?** Nothing forces a block to exist. On a chain this
   small, "stalled" usually means the humans stopped playing, and no
   operational action fixes that.
2. **Are peers reachable?**
   `sigilcoin peers test HOST:PORT --chain sigilcoin-main --data-dir /var/lib/sigilcoin`,
   then check `peer-failures` in `status`.
3. **Is the node refusing blocks?** Read `sync-last-error`. A rule refusal
   names the rule. A transport failure looks like this, verified:
   `sync-last-error: connect failed: peers: could not connect to 127.0.0.1 (p2p-socket-connect-timeout: connection refused).`
4. **Are bodies arriving but not validating?** `best-height` climbing while
   `validated-blocks` is flat and `pending-blocks` is non-zero. Raise
   `services.sigilcoin.sync.validationBlocks`, or check whether the unit is
   hitting `CPUQuota`: `systemctl show sigilcoin-sync -p CPUUsageNSec`.
   Hostile-but-legal solutions are bounded, not cheap.
5. **Nothing else worked.** Stop the units, move the database aside (keep it,
   do not delete it — it is the evidence), restart, and let the node re-sync
   from genesis. The wallet key is not involved.

### Reorgs

A reorg here is routine, not an incident. Fork choice is: greater height
wins; at equal height the shorter winning program wins; at equal height and
equal length the lower block hash wins. Because the optimal program for a
puzzle is often unique, ties are the normal case rather than the rare one,
and the tie-break is decided by a hash a miner can grind with up to 400 bytes
of graffiti. Expect the tip to change hands.

What that means operationally:

- A `best-block-hash` that changes at the same height is a reorg. The node
  rolls back UTXOs and restores the affected mempool entries by itself.
- **A mined block is not money until it is 100 blocks deep**, which is the
  coinbase maturity and roughly 100 days. Treat a fresh reward as
  provisional; `balance` already does, under `immature`.
- A reorg deeper than a few blocks, or one that repeats at the same height,
  is worth reporting in `#systemcrafters` with the two competing block ids
  and the output of `sigilcoin status` from both sides.
- No action is required from the operator. There is no `invalidateblock`.

## Known rough edges

Verified behaviour of `sigilcoin 0.1.0` that the module works around. Read
this before deciding something is broken.

**`sigilcoin listen` must be run with `--max-connections 0`, and the kernel
holds the port either way.** Measured against the binary this flake builds,
on loopback:

| Invocation | Result |
| --- | --- |
| `--max-connections 1`, one connect | exits 0 after serving it (`connections-served: 1`) |
| `--max-connections 0`, idle, `--accept-timeout 3000` | still running at 20 s; killed by `timeout`, not by itself |
| `--max-connections 0`, 3 garbage writes then 3 bare hangups | alive after all six; each logged and the loop continued |

So `--max-connections 0` — what the module sets, and not the CLI's default of
1 — gives a process that behaves like a daemon in every case tried here. The
accept timeout did not end it: `socket-ready?` blocked rather than returning
false.

That is measured behaviour, not a guarantee, and it disagrees with an earlier
report of `--max-connections 0` exiting after 3.079 s. Do not build the
deployment on either reading. The module is arranged so neither matters:

- `sigilcoin-listen-proxy.socket` binds `0.0.0.0:19444` with `Accept=no` and
  holds it for the lifetime of the host. The accept backlog therefore
  survives every restart of everything behind it, and a peer that dials
  during one waits in the backlog instead of being refused.
- `systemd-socket-proxyd` forwards to `127.0.0.1:19544`, where
  `sigilcoin listen` binds.
- `sigilcoin-listen` itself is `Restart=always`, `RestartSec=100ms`,
  `StartLimitIntervalSec=0`. Startup-to-bind is ~0.08 s, so a restart leaves
  the loopback listener missing for roughly 0.18 s, during which the proxy
  drops the connections it cannot forward. The public port never closes.

Real socket activation — handing `sigilcoin listen` the listening fd itself
and deleting the proxy — is not possible today: nothing in the Sigil runtime
or in sigil-bitcoin reads `$LISTEN_FDS`, and `run-listen` unconditionally
calls `tcp-listen` to make its own socket. When the CLI learns to adopt an
inherited fd, point `sigilcoin-listen.socket` straight at it and drop
`sigilcoin-listen-proxy` entirely.

The proxy costs nothing in fidelity: the node never recorded inbound peer
addresses in the first place. `node-serve-inbound-socket` takes the address
as a display label and the CLI passes the literal string `"inbound"`.

So: `systemctl status sigilcoin-listen` showing a recent start time is fine,
and `systemctl is-active sigilcoin-listen-proxy.socket` is the thing that
must always say `active`.

**Two processes share one SQLite file.** `sigilcoin-listen` and
`sigilcoin-sync` both open `<data-dir>/<chain>.sqlite`. The Sigil SQLite
driver forces `busy_timeout=0` and retries a contended step rather than
blocking, and the database is not in WAL mode. Concurrent reads while the
other unit is running were verified to work. Under sustained write contention
they have not been. If `sync-last-error` starts reporting busy or locked
database errors, run the two units on a schedule that does not overlap rather
than adding a third writer.

**The explorer's flags, confirmed by running it.** `sigilcoin-explorer`
builds and runs out of the same derivation as the node. Two differences from
the node CLI matter and the module handles both: chain selection is the bare
`--regtest` flag, not `--chain NAME`, and the bind address flag is `--host`,
not `--bind`. There is no read-only flag; read-only is enforced by the unit's
`ReadOnlyPaths`.

```sh
timeout 5 sigilcoin-explorer --help
```

```
sigilcoin-explorer — read-only web explorer for SigilCoin

usage:
  sigilcoin-explorer [--regtest] [--data-dir DIR] [--host HOST] [--port N]

options:
  --regtest         serve sigilcoin-regtest instead of sigilcoin-main
  --data-dir DIR    node data directory to read (default: .)
  --host HOST       address to bind (default: 127.0.0.1)
  --port N          port to bind (default: 8080)
  -h, --help        print this and exit
  --version         print the package version and exit
```

MINIMUM VERSION: `--help`, `-h` and `--version` answer and exit before
anything binds a port. An explorer built before that landed has no `--help`
handling at all and falls through to serving, so the command blocks the
terminal instead of printing. If `sigilcoin-explorer --version` does not
print `sigilcoin-explorer 0.1.0` and return, you are on an older build: read
`explorer-main` in
`packages/sigil-coin-explorer/src/sigil/coin/explorer/server.sgl` instead of
running it. Every explorer command in this runbook is wrapped in `timeout`
for that reason.

Serving was verified the same way — bounded, because the server itself does
not exit:

```sh
timeout 5 sigilcoin-explorer --regtest --data-dir /tmp/n --host 127.0.0.1 --port 18099 &
sleep 2 && curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18099/
```

```
200
explorer: sigilcoin-regtest at /tmp/n/sigilcoin-regtest.sqlite
explorer: http://127.0.0.1:18099/
```

**A read-only SQLite reader still needs the database to be clean.** If the
node crashes mid-write and leaves a hot journal, recovery requires a write,
which the explorer cannot perform. Symptom: the explorer fails to start until
one of the node units has opened the database once. Starting
`sigilcoin-explorer` after `sigilcoin-sync`, which the unit ordering already
does, is the mitigation.
