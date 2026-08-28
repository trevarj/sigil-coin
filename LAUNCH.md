# SigilCoin launch checklist

Do these in order. Steps 1 through 4 are irreversible once step 5 puts a
public node up: after that, changing any of them splits the network or
invalidates the chain. Operational detail lives in
[`deploy/RUNBOOK.md`](deploy/RUNBOOK.md).

Current state: **nothing here has ever run on a public network.** The
genesis quote, the genesis timestamp and the seed hostname are all
placeholders. See [Decisions still owed](#decisions-still-owed-by-the-operator).

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
- [ ] Edit `QUOTE` and `TIME` in `deploy/genesis-constants.sgl` and run it
      from the repository root:

      nix develop /home/trev/Workspace/sigil -c \
        sigil deploy/genesis-constants.sgl --redirects ./dev-redirects.sgl

      Verified output for the current placeholder:

      quote: PLACEHOLDER: the launch-day #systemcrafters quote goes here
      quote-bytes: 59
      time: 1785542400
      header-hex: 0400000000000000000000000000000000000000000000000000000000000000000000007c95e9e1f3fed6ac0776e4fd69d20ba3f63364906a532befc67246ee58743ed800376d6affff7f2031000000
      hash: 4dc1914abc4af386d05906338d7823fffdef2f469f0aad0ff6fbd635528b19ff
      id: ff198b5235d6fbf60fad0a9f462feffdff23788d330659d086f34abc4a91c14d

- [ ] Check `quote-bytes` against the 400-byte graffiti cap. It is a BYTE
      count of the UTF-8 the coinbase actually carries, not a character
      count, so a quote with any non-ASCII in it costs more than it looks.

- [ ] Paste all four into
      `packages/sigil-coin-node/src/sigil/coin/node/chain.sgl`:
      `coin-genesis-quote`, `coin-genesis-time`,
      `coin-genesis-header-constant` (the `header-hex` line) and
      `coin-genesis-id-constant` (the `id` line).
- [ ] Re-run the suite. `test-node.sgl` rebuilds genesis from the quote and
      asserts the constants, so a mismatch fails there rather than shipping.
- [ ] Leave the regtest constants alone. A distinct regtest genesis is what
      stops a local block being mistaken for a real one.

## 3. Replace the placeholder seed host

`sigilcoin-main-chain` currently ships `seed.sigilcoin.invalid:19444`.
`.invalid` never resolves, by design — a node with no configured peer finds
nothing and says so, rather than silently reaching a stranger's host.

- [ ] Register the real DNS name and point it at the seed host's A/AAAA
      records.
- [ ] Replace the `seed-peers` entry in `chain.sgl` with
      `("seed.<yourdomain> . 19444)`.
- [ ] Re-run the suite, rebuild, and confirm a fresh data directory finds the
      seed with no `--peer` flag and no manual `peers add`.

Do not launch with the `.invalid` placeholder still in place. Every new node
would need a hand-typed peer, and the first thing anyone would ask in the
channel is what to type.

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
- [ ] Rules a miner hits: solutions at most 256 bytes, graffiti at most 400
      bytes, blocks at most 8192 bytes, block spacing floor 72000 seconds,
      future drift allowance 7200 seconds, coinbase maturity 100 blocks.
- [ ] Fork choice, stated plainly: greater height wins; at equal height the
      shorter program wins; at equal height and length the lower block hash
      wins.

Anyone can check the first two against their own build with
`sigilcoin status`, which prints `best-hash` on a fresh data directory.

## 5. Stand up the seed node and the explorer

Follow [`deploy/RUNBOOK.md`](deploy/RUNBOOK.md); the checklist here is only
the launch-day gate.

- [ ] `cd …/sigil-coin/deploy && nix flake check` passes on the build host.
      It must report a non-zero number of checks (six on a cold store, fewer
      when they are already built); one of them builds both binaries and runs
      `sigilcoin version`. `running 0 flake checks` means nothing ran.
- [ ] `nix build …/sigil-coin?dir=deploy#sigilcoin` produces
      `result/bin/sigilcoin` and `result/bin/sigilcoin-explorer`, and
      `./result/bin/sigilcoin version` prints `sigilcoin 0.1.0`.
      The `?dir=deploy` is required; see `deploy/flake.nix`.
- [ ] Host deployed with `services.sigilcoin.enable = true`,
      `chain = "sigilcoin-main"`, `listen.bind = "0.0.0.0"`,
      `openFirewall = true`.
- [ ] 19444/tcp reachable from off-host. Check from somewhere else, not from
      the seed: `nc -vz seed.<yourdomain> 19444`.
- [ ] `systemctl is-active sigilcoin-listen-proxy.socket` says `active`. That
      socket unit, not the node process, is what holds 19444.
- [ ] `sigilcoin status` on the seed reports the published genesis hash.
- [ ] Wallet key backed up, encrypted, offline, before the seed can earn
      anything.
- [ ] `timeout 5 sigilcoin-explorer --version` prints
      `sigilcoin-explorer 0.1.0` and returns. If it blocks instead, the
      build predates `--help`/`--version` handling and every explorer
      command has to be run under `timeout`.
- [ ] Explorer up behind TLS, and it renders genesis. If the explorer is not
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

> SigilCoin is up: a blockchain where mining is program golf instead of hash
> grinding. Each block publishes a generated puzzle and the shortest program
> that solves it wins the block. It's written in Sigil, it's worth nothing
> and is never intended to be worth anything, and there's no premine.
> Blocks are one a day. Graffiti in the coinbase is by convention a quote
> from here. Code, genesis hash and network parameters:
> <REPO URL>. To play: build the `sigilcoin` binary, run
> `sigilcoin sync`, then `sigilcoin puzzle` to see the current target and
> `sigilcoin mine --solution '<your program>'` when you can beat the
> baseline it prints.

Before sending:

- [ ] `<REPO URL>` replaced.
- [ ] The claims match what shipped: worth nothing, no premine, one block a
      day, shortest program wins.
- [ ] The three commands were run against the real mainnet build, in that
      order, on a machine that is not the seed.
- [ ] The quote in genesis is credited to whoever said it, in the repository
      if not in the message.
- [ ] Nobody is asked to install anything unsigned from a stranger.

Do not post it as a coin launch, do not mention value, price, exchanges or
scarcity, and do not repeat it in other channels. The chain is a toy for one
community; the announcement should read like a toy.

## 7. Post-launch checks

**First hour:** seed reachable from off-host (`nc -vz`, run from elsewhere);
`sigilcoin-listen-proxy.socket` active; two `sigilcoin status` readings ten
minutes apart show `peer-successes` strictly larger in the second; explorer
serving.

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
resolving without intervention (expected: ties are the normal case, and the
tie-break is grindable through graffiti); `issued-supply` matching the
published emission schedule at the current height; disk growth measured and
extrapolated — 8192 bytes per block is about 3 MB a year, so this should be
a non-issue, and if it is not, something is wrong.

**Ongoing:** back up `wallet.key` and the database on a schedule; watch for
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
- Mine deliberately awkward blocks: a solution at exactly 256 bytes, graffiti
  at exactly 400 bytes, a block filled to the 8192-byte cap, a block at the
  earliest legal timestamp, and a competing block at the same height to force
  a tie-break.
- Restart both hosts at least once. Kill the seed with `SIGKILL` mid-write at
  least once, and confirm both units come back and the explorer recovers.
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
- `systemctl show sigilcoin-listen -p NRestarts` — record it daily. What
  matters is whether the rate is steady or accelerating, not the number.
  `systemctl is-active sigilcoin-listen-proxy.socket` must never have
  changed.
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
- Port 19444 is ever observed refusing a connection from off-host while the
  host is up. The socket unit holds it across restarts, so a refusal means
  that mechanism is not working.
- `peer-successes` is flat for a full day on either node while blocks are
  being mined.
- Memory or CPU climbs steadily over the soak rather than flattening.

Anything else — an explorer bug, an ugly log line, a missing convenience
flag — is a post-launch fix, not an abort.

---

## Decisions still owed by the operator

Every one of these is a placeholder in the current tree. None can be deferred
past step 5.

| # | Decision | Where it lives now |
| --- | --- | --- |
| 1 | The genesis quote, and permission from whoever said it | `coin-genesis-quote` in `packages/sigil-coin-node/src/sigil/coin/node/chain.sgl`: `"PLACEHOLDER: the launch-day #systemcrafters quote goes here"` |
| 2 | The genesis timestamp | `coin-genesis-time`, currently `1785542400` (2026-08-01T00:00:00Z) |
| 3 | The two derived genesis constants | `coin-genesis-header-constant` and `coin-genesis-id-constant`, both still derived from the placeholder quote |
| 4 | The real seed DNS name | `sigilcoin-main-chain` seed peers, currently `seed.sigilcoin.invalid:19444` |
| 5 | Where the repository is published | `<REPO URL>` in the announcement; `package.sgl` says `https://github.com/trevarj/sigil-coin`, unconfirmed |
| 6 | ~~`depsHash`~~ — RESOLVED. There is no vendoring derivation and no hash to fill in: every `from-git` dependency is a pinned flake input, so Nix fetches it and the sandbox stays offline. Bumping one is `nix flake update <input>` in `deploy/`. | — |
| 7 | ~~Confirm the explorer's flags~~ — RESOLVED. `--regtest`, `--data-dir`, `--host`, `--port` confirmed against `explorer-main` and against `sigilcoin-explorer --help` run from the built binary. | `services.sigilcoin-explorer.command` in `deploy/module.nix` |
| 8 | Seed host, domain, and TLS certificate for the explorer | Not in the tree at all |
| 9 | Whether to launch without an explorer if it is not ready | Recommendation: yes |
| 10 | ~~Whether `sigilcoin listen` gets a persistent accept loop before launch~~ — NOT DEFERRED, and no longer a launch blocker. The kernel holds port 19444: `sigilcoin-listen-proxy.socket` binds it with `Accept=no` and keeps the accept backlog across every restart of the node process, which binds loopback behind `systemd-socket-proxyd`. A restarting or crashing listener can no longer take the seed off the air. | `deploy/module.nix` |
| 10b | Whether to delete the proxy once the CLI can adopt an inherited fd | Real socket activation needs `run-listen` to take the fd in `$LISTEN_FDS` instead of calling `tcp-listen`; nothing in the Sigil runtime or sigil-bitcoin reads it today. Post-launch cleanup, not a blocker. |
