# SigilCoin launch checklist

Do these in order. Steps 1 through 4 are irreversible once step 5 puts a
public node up: after that, changing any of them splits the network or
invalidates the chain. Operational detail lives in
[`deploy/RUNBOOK.md`](deploy/RUNBOOK.md).

Current state: **nothing here has ever run on a public network.** The genesis
quote, the derived genesis constants, the seed hostname, the repository URL
and the explorer hostname are all decided and in the tree. See
[Decisions still owed](#decisions-still-owed-by-the-operator) for what is
left.

---

## 1. Freeze the puzzle language and the generator

`packages/sigil-coin-puzzle` is consensus. The interpreter decides whether a
block's program solves its puzzle, and the generator decides what the puzzle
is. A node that disagrees with its peers about either one is on a different
chain, silently — there is no version negotiation on the wire that would
surface it.

- [ ] No open work on `src/sigil/coin/puzzle.sgl` or
      `src/sigil/coin/puzzle/generator.sgl`. Merge or abandon it now.
- [ ] `puzzle-generator-version` is `1` and stays `1` through launch.
- [ ] Full suite green:
      `nix develop /home/trev/Workspace/sigil -c sigil test --redirects ./dev-redirects.sgl --no-color`
- [ ] Tag the freeze so the launch commit is nameable, and say in the tag
      message that the puzzle layer is frozen.

After this point a change to either file is a hard fork requiring every node
to upgrade in lockstep. Treat "we should add one more builtin" as a
post-launch v2 discussion, not a launch blocker.

The same freeze applies to `sigil-coin-consensus`: emission, the solution
rules, the coinbase codec and fork choice.

## 2. Choose the genesis quote and regenerate the constants

Genesis carries a quote from `#systemcrafters` in its coinbase. The quote IS
the genesis hash: change one byte and every constant below changes.

- [ ] Pick the quote. Ask the person quoted first — it is going in an
      immutable coinbase forever.
- [ ] Pick the genesis timestamp, UTC, in the recent past. It must be far
      enough back that genesis, and a first block 20 hours later, both clear
      the 7200-second future-drift rule on any node with a sane clock.
- [x] Edit `QUOTE` and `TIME` in `deploy/genesis-constants.sgl` and run it
      from the repository root:

      nix develop /home/trev/Workspace/sigil -c \
        sigil deploy/genesis-constants.sgl --redirects ./dev-redirects.sgl

      Verified output for the launch quote:

      quote: Sigil - Practical Symbolic Power
      quote-bytes: 32
      time: 1785542400
      header-hex: 04000000000000000000000000000000000000000000000000000000000000000000000099a5066258b8dc1726a6d0dcb92472129769a290b29421f39c823e692b5e7a6b00376d6affff7f2031000000
      hash: 210ca3a6564da8187b4f935daad4e1ed809ef6db7faef3ed4e46ae78007dee9d
      id: 9dee7d0078ae464eedf3ae7fdbf69e80ede1d4aa5d934f7b18a84d56a6a30c21

- [x] Check `quote-bytes` against the 400-byte graffiti cap. 32 bytes used,
      368 to spare. It is a BYTE
      count of the UTF-8 the coinbase actually carries, not a character
      count, so a quote with any non-ASCII in it costs more than it looks.

- [x] Paste all four into
      `packages/sigil-coin-node/src/sigil/coin/node/chain.sgl`:
      `coin-genesis-quote`, `coin-genesis-time`,
      `coin-genesis-header-constant` (the `header-hex` line) and
      `coin-genesis-id-constant` (the `id` line).
- [ ] Re-run the suite. `test-node.sgl` rebuilds genesis from the quote and
      asserts the constants, so a mismatch fails there rather than shipping.
- [ ] Leave the regtest constants alone. A distinct regtest genesis is what
      stops a local block being mistaken for a real one.

## 3. Stand the seed host's DNS up

`sigilcoin-main-chain` ships `seed.sigilcoin.lol:19444`. The earlier
`.invalid` placeholder never resolved, by design — a node with no configured
peer found nothing and said so, rather than silently reaching a stranger's
host. It is gone.

- [ ] Point `seed.sigilcoin.lol` at the seed host's A/AAAA records.
- [x] `seed-peers` in `chain.sgl` is `(("seed.sigilcoin.lol" . 19444))`.
- [ ] Re-run the suite, rebuild, and confirm a fresh data directory finds the
      seed with no `--peer` flag and no manual `peers add`.

DNS must resolve before step 5. Otherwise every new node needs a hand-typed
peer, and the first thing anyone would ask in the channel is what to type.

## 4. Publish the parameters

Publish before the announcement, so the first person who reads it can verify
rather than trust. A file in the repository is enough; a gist is not — it
should be in the same place the code is.

- [ ] Genesis display id and internal hash.
- [ ] Genesis header hex and the quote it encodes.
- [ ] Network magic `8f d1 c0 a5`, default port 19444, protocol version
      70015, user agent `/sigilcoin-node:0.1.0/`.
- [ ] Address format: bech32, HRP `sgl`, so addresses read `sgl1…`.
- [ ] Emission, exactly: 1 SGL per block for the first 30 blocks, then 100
      SGL halving every 730 blocks, total supply 143029.99991970 SGL
      (14302999991970 daviwils; 1 SGL = 100000000 daviwils). Zero premine.
      The genesis coinbase is unspendable.
- [ ] Rules a miner hits: solutions at most 512 bytes, graffiti at most 400
      bytes, blocks at most 16384 bytes, at most 8 example pairs per puzzle,
      block spacing floor 72000 seconds, future drift allowance 7200 seconds,
      coinbase maturity 100 blocks.
- [ ] Fork choice, stated plainly: greater height wins; at equal height the
      better score wins, where score is the shorter program, then the one
      that allocated less, then the one that ran in fewer steps, then the one
      carrying more co-op shares. There is no block-hash tie-break: two blocks
      that score identically are incomparable and the one seen first is kept,
      which is what stops a copied solution from being ground into a win.

Anyone can check the first two against their own build with
`sigilcoin status`, which prints `best-hash` on a fresh data directory.

## 5. Stand up the seed node and the explorer

Follow [`deploy/RUNBOOK.md`](deploy/RUNBOOK.md); the checklist here is only
the launch-day gate.

- [ ] `cd …/sigil-coin/deploy && nix flake check` passes on the build host.
      The number it prints is what was left to build (two checks exist;
      zero once cached), so do not read it as a pass count.
      Force the two real checks to execute:
      `nix build --rebuild --no-link .#checks.x86_64-linux.module-eval .#checks.x86_64-linux.sigilcoin-runs`.
      One builds both binaries and runs `sigilcoin version`; `module-eval`
      asserts that no `sigilcoin-listen-proxy` unit exists and that the
      listen unit binds the public port itself.
- [ ] `nix build …/sigil-coin?dir=deploy#sigilcoin` produces
      `result/bin/sigilcoin` and `result/bin/sigilcoin-explorer`, and
      `./result/bin/sigilcoin version` prints `sigilcoin 0.1.0`.
      The `?dir=deploy` is required; see `deploy/flake.nix`.
- [ ] Host deployed with `services.sigilcoin.enable = true`,
      `chain = "sigilcoin-main"`, `listen.bind = "0.0.0.0"`,
      `openFirewall = true`.
- [ ] 19444/tcp reachable from off-host. Check from somewhere else, not from
      the seed: `nc -vz seed.sigilcoin.lol 19444`.
- [ ] `systemctl is-active sigilcoin-listen` says `active`. The node process
      itself holds 19444; there is no socket unit and no proxy.
- [ ] `sigilcoin status` on the seed reports the published genesis hash.
- [ ] Wallet key backed up, encrypted, offline, before the seed can earn
      anything. It is `/var/lib/sigilcoin/wallet/wallet.key`, inside a 0700
      directory the explorer cannot enter; `stat -c '%A' /var/lib/sigilcoin`
      must still read `drwxr-x---` after the key exists, because that is
      what the explorer traverses.
- [ ] `timeout 5 sigilcoin-explorer --version` prints
      `sigilcoin-explorer 0.1.0` and returns. If it blocks instead, the
      build predates `--help`/`--version` handling and every explorer
      command has to be run under `timeout`.
- [ ] Explorer up at `explorer.sigilcoin.lol` behind a TLS reverse proxy, and
      it renders genesis. The explorer itself stays bound to `127.0.0.1:8080`;
      the proxy is the only public path to it. If the explorer is not
      ready, launch without it and say so in the announcement rather than
      delaying — a chain with no explorer is fine; a chain with no seed is
      not.
- [ ] A second node, on different hardware and a different network, syncs
      from the seed and reaches the same tip. One node is not a network.

## 6. The announcement

`#systemcrafters` on Libera tolerates roughly one message a day. This is
that message. Post it once, do not follow up with a thread, and answer only
direct questions.

Draft, to send as-is:

> SigilCoin is up: a blockchain where mining is program synthesis instead of
> hash grinding. Each block publishes a handful of input/output pairs and a
> rule for the day, and you win by writing the smallest function that
> reproduces every pair. Mining it with a model or a search script is the
> intended way to play, not a loophole. It's written in Sigil, it's worth
> nothing and is never intended to be worth anything, and there's no premine.
> Blocks are one a day. Graffiti in the coinbase is by convention a quote
> from here. Code, genesis hash and network parameters:
> https://github.com/trevarj/sigil-coin. To play: build the `sigilcoin`
> binary, run
> `sigilcoin sync`, then `sigilcoin puzzle` to see today's pairs and
> `sigilcoin mine --solution '<your program>'` when you have something that
> beats the baseline it prints.

Before sending:

- [x] Repository URL is `https://github.com/trevarj/sigil-coin`.
- [ ] The claims match what shipped: worth nothing, no premine, one block a
      day, smallest function reproducing every pair wins.
- [ ] The three commands were run against the real mainnet build, in that
      order, on a machine that is not the seed.
- [x] The quote in genesis needs no third-party credit:
      `Sigil - Practical Symbolic Power` is the operator's own line.
- [ ] Nobody is asked to install anything unsigned from a stranger.

Do not post it as a coin launch, do not mention value, price, exchanges or
scarcity, and do not repeat it in other channels. The chain is a toy for one
community; the announcement should read like a toy.

## 7. Post-launch checks

**First hour:** seed reachable from off-host (`nc -vz`, run from elsewhere);
`sigilcoin-listen` active; two `sigilcoin status` readings ten minutes apart
show `peer-successes` strictly larger in the second; explorer serving.

Do NOT use "`peer-failures` not climbing" or "`sync-last-error` empty" as
criteria. Both fields are sticky records of the last outcome, and one
unreachable peer in the table leaves `sync-stage: failed` on a healthy node
forever. Movement in `peer-successes` is the signal; see the runbook's health
section for the measured healthy/unhealthy pair.

**First 48 hours:** at least one block mined by someone who is not the
operator — this is the real signal that the announcement worked and the
instructions were followed; `validated-blocks` matching between the seed and
the second node at the same height; `peer-successes` still rising on both.

**First two weeks:** cadence roughly one block a day; reorgs happening and
resolving without intervention (expected: equal-scoring blocks are
incomparable and settle on first-seen, so a fork should resolve the moment a
child arrives, not linger); `issued-supply` matching the published emission
schedule at the current height; disk growth measured and extrapolated — 16384
bytes per block is about 6 MB a year, so this should be a non-issue, and if it
is not, something is wrong.

**Ongoing:** back up `wallet/wallet.key` and the database on a schedule; watch for
anyone reporting a solution their node accepts and the seed rejects, which
is the consensus-divergence signal and the one thing worth waking up for.

---

## Pre-launch soak

**This has never run on a public network.** Two nodes on one machine, over
loopback, is the extent of what has been exercised. Soak before step 5, not
after.

Run mainnet rules — `--chain sigilcoin-main`, not regtest, so the real 20
hour spacing floor and the real genesis are in play — on two machines, on
different networks, for **at least 14 days**. Fourteen because it is the
shortest window that contains a plausible number of blocks on a chain that
mints one a day, and because the emission warmup is 30 blocks: a shorter soak
never leaves the 1 SGL warmup band and never exercises the first halving
boundary at all.

What to run:

- Seed host with the real module, real ports, real firewall. Not a laptop.
- Second node on unrelated hardware and a different network, syncing from the
  seed by DNS name, never by IP.
- Mine deliberately awkward blocks: a solution at exactly 512 bytes, graffiti
  at exactly 400 bytes, a block filled to the 16384-byte cap, a block at the
  earliest legal timestamp, and a competing block at the same height to force
  a tie-break.
- Restart both hosts at least once. Kill the seed with `SIGKILL` mid-write at
  least once, and confirm both node units come back. The explorer will NOT
  recover on its own: a hard kill can leave a SQLite hot journal, rolling it
  back is a write, and the explorer's unit is `ReadOnlyPaths`. Let
  `sigilcoin-sync` open the database first (that performs the rollback),
  check the `-journal` file is gone, then restart the explorer. Do not delete
  the journal by hand. See the runbook's last rough edge.
- Restore from backup onto a third, empty machine and confirm the address and
  balance match.

What to watch daily, all as changes between two readings rather than as
absolute values:

- `validated-blocks` identical on both nodes at the same height. Not
  "rising" — identical. A difference here is the consensus signal.
- `peer-successes` larger than yesterday's reading on both nodes. This
  replaces "`sync-last-error` empty", which no healthy node can satisfy: a
  peer hanging up is the normal end of a conversation and leaves an error
  string behind.
- `issued-supply` matching the published schedule exactly.
- `systemctl show sigilcoin-listen -p NRestarts` — record it daily. The
  listener is persistent and absorbs peer faults itself, so this should stay
  at whatever the last `nixos-rebuild` left it. Any growth is a real crash,
  and five restarts inside a minute put the unit in `failed` on purpose.
- RSS against the unit's 1G `MemoryMax`; validation CPU against `CPUQuota`.

**Abort the launch if any of these happen:**

- The two nodes disagree about the tip at the same height for any reason
  other than a reorg that resolves within one block. That is a consensus
  split, and it is fatal.
- A block one node accepts, the other rejects.
- `issued-supply` diverges from the published schedule by one daviwil.
- The database is corrupt after a hard kill, or a restore does not reproduce
  the balance.
- A single block takes more than a few seconds to validate. Solution
  verification is bounded but not cheap, and a chain where a hostile block is
  a denial of service is not ready to be public.
- Port 19444 is ever observed refusing a connection from off-host while
  `sigilcoin-listen` is active. The node holds the port for as long as it
  runs, so a refusal while it is up means the accept loop is wedged. (A
  refusal during the few seconds of a deliberate restart is expected.)
- `peer-successes` is flat for a full day on either node while blocks are
  being mined.
- Memory or CPU climbs steadily over the soak rather than flattening.

Anything else — an explorer bug, an ugly log line, a missing convenience
flag — is a post-launch fix, not an abort.

---

## Decisions still owed by the operator

What is left is DNS, a certificate, and one go/no-go call. Nothing in this
table can be deferred past step 5.

| # | Decision | Where it lives now |
| --- | --- | --- |
| 1 | ~~The genesis quote~~ — RESOLVED: `Sigil - Practical Symbolic Power`, the operator's own words, so no third-party permission is needed. 32 UTF-8 bytes, 368 under the 400-byte graffiti cap. | `coin-genesis-quote` in `packages/sigil-coin-node/src/sigil/coin/node/chain.sgl` |
| 2 | The genesis timestamp | `coin-genesis-time`, currently `1785542400` (2026-08-01T00:00:00Z). Still the value the constants below were derived from; changing it means regenerating them. |
| 3 | ~~The two derived genesis constants~~ — RESOLVED. Regenerated from the launch quote with `deploy/genesis-constants.sgl`: header `04…2b5e7a6b00376d6affff7f2031000000`, id `9dee7d0078ae464eedf3ae7fdbf69e80ede1d4aa5d934f7b18a84d56a6a30c21`. `test-node.sgl` rebuilds genesis from the quote and asserts both. | `coin-genesis-header-constant` and `coin-genesis-id-constant` in `chain.sgl` |
| 4 | ~~The real seed DNS name~~ — RESOLVED: `seed.sigilcoin.lol:19444`, on the operator's own domain. The A/AAAA records still have to exist before step 5. | `sigilcoin-main-chain` seed peers in `chain.sgl` |
| 5 | ~~Where the repository is published~~ — RESOLVED and confirmed: `https://github.com/trevarj/sigil-coin`, the operator's account. Every `package.sgl` and the announcement now say so. | `package.sgl` files, the step 6 announcement |
| 6 | ~~`depsHash`~~ — RESOLVED. There is no vendoring derivation and no hash to fill in: every `from-git` dependency is a pinned flake input, so Nix fetches it and the sandbox stays offline. Bumping one is `nix flake update <input>` in `deploy/`. | — |
| 7 | ~~Confirm the explorer's flags~~ — RESOLVED. `--regtest`, `--data-dir`, `--host`, `--port` confirmed against `explorer-main` and against `sigilcoin-explorer --help` run from the built binary. | `services.sigilcoin-explorer.command` in `deploy/module.nix` |
| 8 | The TLS certificate for `explorer.sigilcoin.lol` | Still owed. The domain is `sigilcoin.lol` and the explorer's public name is `explorer.sigilcoin.lol` (`deploy/RUNBOOK.md`), but nothing in the tree issues or terminates a certificate: that is the reverse proxy's job on the host. |
| 9 | Whether to launch without an explorer if it is not ready | Recommendation: yes |
| 11 | Whether to run the 14-day pre-launch soak, or launch without it | Still owed. See [Pre-launch soak](#pre-launch-soak); nothing has ever run outside loopback. |
| 10 | ~~Whether `sigilcoin listen` gets a persistent accept loop before launch~~ — RESOLVED IN THE CLI, not worked around. `run-listen` now loops indefinitely under `--max-connections 0` (`operate.sgl`: `((= max-connections 0) (loop last))`) and serves each connection inside its own guard, so a hangup, garbage bytes or a silent drop kill that connection only. Re-measured against this build: idle at `--accept-timeout 2000` it was alive at 30 s and 55 s and ended only by an external `timeout`; six hostile connections were absorbed and a seventh still accepted. The seed therefore binds 19444 itself. | `packages/sigil-coin-cli/src/sigil/coin/cli/operate.sgl`, `deploy/module.nix` |
| 10b | ~~Whether to delete the socket proxy once the CLI can adopt an inherited fd~~ — DELETED NOW, and no fd adoption was needed. The proxy existed only because the old listener died on an accept timeout and on hostile input; with that fixed it was pure cost: an extra unit pair and hop, no inbound peer address ever reaching the node (which forecloses abuse-banning), and a `Restart=always` without `StartLimitIntervalSec=0` that could park `systemd-socket-proxyd` in `failed` and take port 19444 out of service — the outage it was supposed to prevent. `nix flake check`'s `module-eval` now fails if any `sigilcoin-listen-proxy` unit comes back. | `deploy/module.nix`, `deploy/flake.nix` |
