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
running 2 flake checks...
all checks passed!
```

The count is what is LEFT TO BUILD, not how many checks exist. There are
exactly two: `sigilcoin-runs`, which builds both binaries and runs
`sigilcoin version`, and `module-eval`, which evaluates a host, asserts the
units it generates, and fails if a `sigilcoin-listen-proxy` unit ever comes
back. A run whose dependencies are already built legitimately prints
`running 0 flake checks`.
Zero means "nothing left to do", not "nothing was verified" — but it also
proves nothing, so when you want the checks to actually execute, force them:

```sh
nix build --rebuild --no-link \
  .#checks.x86_64-linux.module-eval .#checks.x86_64-linux.sigilcoin-runs
```

```
checking outputs of '/nix/store/…-sigilcoin-module-eval.drv'...
checking outputs of '/nix/store/…-sigilcoin-runs.drv'...
```

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

The explorer's public name is `explorer.sigilcoin.lol`. Put a TLS reverse
proxy in front of it on that name; nothing here terminates TLS, and the
explorer keeps binding `127.0.0.1:8080` so the proxy is the only way in. Do
not give it a public bind address.

### Ports and firewall

| Port | Chain | Who needs it open |
| --- | --- | --- |
| 19444/tcp | `sigilcoin-main` | Everyone. `openFirewall = true` opens it. Bound by `sigilcoin listen` itself. |
| 19445/tcp | `sigilcoin-regtest` | Local only. Never expose it. |
| 8080/tcp | explorer | Localhost only; reverse-proxy it, do not open the port. |

Mainnet magic is `8f d1 c0 a5`, regtest is `a5 c0 d1 8f`, and the user agent
is `/sigilcoin-node:0.1.0/`.

### Where state lives

`/var/lib/sigilcoin`, mode 0750, owned `sigilcoin:sigilcoin`:

| Path | What it is |
| --- | --- |
| `sigilcoin-main.sqlite` | Headers, blocks, UTXOs, mempool, peer table, mode 0644 |
| `wallet/` | Key directory, mode 0700 |
| `wallet/wallet.key` | 32-byte secret, hex, mode 0600 |

The key is in its own 0700 subdirectory, not loose in the data directory, and
that separation is load-bearing. The CLI locks the directory that holds the
key down to 0700 before it creates the file; when the key lived in the data
directory, the first `sigilcoin address` took the data directory from 0750 to
0700 and destroyed the group-execute bit the explorer needs to traverse into
it. Measured against the two builds:

```
old binary, after `sigilcoin address`:   drwx------ /tmp/sgl-before
                                         -rw-r--r-- /tmp/sgl-before/sigilcoin-main.sqlite
                                         -rw------- /tmp/sgl-before/wallet.key
this build, after `sigilcoin address`:   drwxr-x--- /tmp/sgl-after
                                         -rw-r--r-- /tmp/sgl-after/sigilcoin-main.sqlite
                                         drwx------ /tmp/sgl-after/wallet
                                         -rw------- /tmp/sgl-after/wallet/wallet.key
```

The explorer's PRIMARY group is `sigilcoin`, so it can traverse the directory
and read the database, and it cannot reach the key: the group has no bits at
all on `wallet/`, and the key inside is 0600 owned by the node user. Its unit
also carries `ReadOnlyPaths=/var/lib/sigilcoin`, so read-only is enforced by
the kernel rather than by a flag the explorer promises to honour.

A key written by an older build at `<dataDir>/wallet.key` is MOVED into
`wallet/` the first time any key-using command runs, and the move is printed:
`wallet: moved …/wallet.key to …/wallet/wallet.key`. If a key exists at BOTH
paths the CLI refuses rather than guessing which one holds the coins; keep
the right one, move the other somewhere safe, and remove it from the data
directory.

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
systemctl status sigilcoin-listen sigilcoin-sync
sudo -u sigilcoin sigilcoin status --chain sigilcoin-main --data-dir /var/lib/sigilcoin
```

`sigilcoin-listen` must be `active (running)`. It binds port 19444 itself;
there is no socket unit and no proxy in front of it.

A node that has done nothing but open its database reports genesis, which is
verified output from a fresh mainnet data directory:

```
chain: sigilcoin-main
best-height: 0
best-hash: a4db344771ff4af14b854e9cf0ed348c7199268d1f82f2c2782380f425dca5fb
best-work: 16837369189484508192
best-header-time: 1785542400
headers: 1
blocks: 0
validated-blocks: 0
best-block-height: 0
best-block-hash: a4db344771ff4af14b854e9cf0ed348c7199268d1f82f2c2782380f425dca5fb
mempool: 0
peers: 0
peer-successes: 0
peer-failures: 0
pending-blocks: 0
sync-stage: idle
sync-last-error:
tip-solution-bytes: 44
next-height: 1
next-reward: 1.00000000 SGL
issued-supply: 0.00000000 SGL
max-supply: 143029.99991970 SGL
```

`best-hash` is the internal byte order. The display id humans quote is that
string reversed: `fba5dc25f4802378c2f2821f8d2699718c34edf09c4e854bf14aff714734dba4`.
Both are current coherent placeholders, derived from genesis quote
`Sigil - Practical Symbolic Power`; mainnet timestamp remains non-final until
launch day. See `../LAUNCH.md`.

Creating the node's own address writes the wallet key:

```sh
sudo -u sigilcoin sigilcoin address --chain sigilcoin-main --data-dir /var/lib/sigilcoin
```

Verbatim from this build on a mainnet data directory at `/tmp/sgl-after`,
which is a 0750 directory standing in for `/var/lib/sigilcoin`:

```
address: sgl1q396xfcr5yjygshnnjxazyu5lhufgzy6r9hpptg
chain: sigilcoin-main
key-file: /tmp/sgl-after/wallet/wallet.key
```

The address is whatever that node's own fresh key derives; the seed's will
differ. What must not differ is the data directory's mode, which the explorer
depends on:

```sh
stat -c '%A %n' /var/lib/sigilcoin /var/lib/sigilcoin/wallet /var/lib/sigilcoin/wallet/wallet.key
```

```
drwxr-x--- /var/lib/sigilcoin
drwx------ /var/lib/sigilcoin/wallet
-rw------- /var/lib/sigilcoin/wallet/wallet.key
```

Back the key up before the node earns anything. See
[Backup and restore](#backup-and-restore).

## Is the node healthy?

```sh
sudo -u sigilcoin sigilcoin status --chain sigilcoin-main --data-dir /var/lib/sigilcoin
journalctl -u sigilcoin-sync -u sigilcoin-listen -n 50
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
nc -vz seed.sigilcoin.lol 19444
```

On the host itself, `systemctl is-active sigilcoin-listen` answers whether
the node is up, and `ss -ltnp | grep 19444` whether it is holding the port.
The port is closed for the few seconds of a restart, and only then.

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
sudo cp -a /var/lib/sigilcoin/wallet/wallet.key /var/backups/sigilcoin/
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
sudo install -d -o sigilcoin -g sigilcoin -m 0700 /var/lib/sigilcoin/wallet
sudo install -o sigilcoin -g sigilcoin -m 0600 \
  /var/backups/sigilcoin/wallet.key /var/lib/sigilcoin/wallet/wallet.key
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
`sigilcoin status` cannot prove consensus compatibility, so this check is
manual: compare consensus changes against `../docs/consensus.md`. Any change to
frozen puzzle or consensus rules is a fork.

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
wins; at equal height the lower composite score wins. Equal-height,
equal-score blocks are incomparable, so the incumbent remains the tip and
first-seen wins locally. There is no block-hash tie-break. Nodes can briefly
keep different siblings, then converge when a child gives one branch greater
height.

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

**`sigilcoin listen` must be run with `--max-connections 0`, which is what
makes it a daemon.** Measured against the binary this flake builds, on
loopback, with the results pasted from the runs:

| Invocation | Result |
| --- | --- |
| `--max-connections 0 --accept-timeout 2000`, idle | alive at 30 s and at 55 s; ended by an external `timeout 61` (exit 124), never by itself |
| `--max-connections 0`, 3 garbage writes then 3 bare hangups | all six absorbed, a 7th connect accepted afterwards, process still alive |
| `--max-connections 7`, the same six plus one | `connections-accepted: 7`, `connections-dropped: 7`, exit 0 only when its own budget was reached |
| `--max-connections 1`, one connect | `connections-accepted: 1`, exit 0 |

The accept timeout is a poll interval under `--max-connections 0`:
`operate.sgl`'s loop answers an idle poll with `((= max-connections 0) (loop
last))` instead of returning. A POSITIVE `--max-connections` is what makes
the command exit on an idle timeout, which is what a probe or a test wants
and what a seed must not have.

Each connection is served inside its own guard, so a hangup, garbage bytes or
a silent client drop end that connection and nothing else. That is why the
unit is an ordinary `Type=simple` service that binds `0.0.0.0:19444`
directly, with `Restart=always`, `RestartSec=5s` and systemd's start rate
limit left on (5 starts in 60 s). A restart now means a real fault, so a
crash loop should reach `failed` and be visible rather than spin forever.

An earlier revision of this module ran the node on loopback behind
`sigilcoin-listen-proxy.socket` and `systemd-socket-proxyd`, because the
listen command of the time exited on an accept timeout and died on a bare
connect-and-hangup. Both defects were fixed in the CLI, so the workaround is
gone: it added a hop, it hid the peer address from a node that will one day
want to ban one, and its own `Restart=always` without
`StartLimitIntervalSec=0` could leave the proxy `failed` with port 19444 out
of service. If you are looking at a host that still has those units, it is
running an old generation.

So: `systemctl is-active sigilcoin-listen` is the thing that must say
`active`, and a recent start time on it is worth a look rather than a shrug.

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

The explorer never writes: it opens the node's database read-only,
answers one request per connection, and closes.
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

**A read-only SQLite reader cannot recover a hot journal.** If the node is
killed mid-write — `SIGKILL`, a power cut, the soak plan's own hard-kill test
— SQLite leaves `sigilcoin-main.sqlite-journal` beside the database, and
rolling it back is a WRITE. The explorer's unit has
`ReadOnlyPaths=/var/lib/sigilcoin`, so it cannot perform that write and will
not serve; expect it to fail on start, or to error on every query, until
something writable has opened the database.

What the operator does about it:

1. Do not delete the journal. It is the uncommitted transaction, and removing
   it corrupts the database instead of repairing it.
2. Let a node unit open the database, which performs the rollback:
   `systemctl start sigilcoin-sync`, or
   `sudo -u sigilcoin sigilcoin status --chain sigilcoin-main --data-dir /var/lib/sigilcoin`.
3. Confirm the journal is gone: `ls /var/lib/sigilcoin` should show only the
   `.sqlite` file and `wallet/`.
4. Then `systemctl restart sigilcoin-explorer`.

The unit ordering (`After=sigilcoin-sync.service`) makes that sequence happen
by itself on a normal boot, so this is a manual step only when the explorer
is started while the node units are stopped.
