# SigilCoin launch checklist

Do these in order. The public testnet gate below must pass before the mainnet
soak begins. Steps 1 through 4 are irreversible once step 5 puts a public
mainnet node up: after that, changing any of them splits the network or
invalidates the chain. Mainnet operational detail lives in
[`deploy/RUNBOOK.md`](deploy/RUNBOOK.md); public testnet operations live in
[`docs/testnet.md`](docs/testnet.md).

Current state: the reset public testnet has been live since
`2026-09-06T05:30:15Z`; mainnet has never run publicly. The mainnet quote,
timestamp, calibrated target, and derived constants are selected for the
staffed launch window. Seed, explorer, and public-testnet pool hostnames are
live; the pool is not a mainnet service. See
[Decisions still owed](#decisions-still-owed-by-the-operator) for what is left.

The packed producer-length `version`, compact target `bits`, and nonce-lottery
cutover change every generated genesis header and hash. Chain state created
under the earlier rules is incompatible; each network starts from fresh state
for its matching genesis.

Compressed experimental-launch schedule:

- `2026-09-08T05:30:15Z`: earliest close of the 48-hour testnet gate.
- `2026-09-08T12:38:33Z`: corrected private mainnet rehearsal start.
- `2026-09-09T12:38:33Z`: earliest rehearsal close and final verification.
- Public launch postponed: select a new timestamp only after optimized-miner
  calibration, search-space rollover, and regenerated genesis complete.

---

## 0. Complete the public testnet

Mainnet preparation may continue in source, but the private mainnet rehearsal
must not start until the reset public testnet passes its 48-hour gate.

- [ ] `seed.testnet.sigilcoin.lol:19446` bootstraps a fresh, empty community
      node from the reset genesis emitted by the reviewed all-network constants
      generator, without a hand-entered IP.
- [ ] `explorer.testnet.sigilcoin.lol` serves through TLS while the explorer
      container remains host-loopback-only on 8080.
- [ ] `pool.testnet.sigilcoin.lol` has an A record to `104.223.122.157`, serves
      `/healthz` and coherent `sigilcoin-testnet` `/v1/context` through TLS, and
      its container remains host-loopback-only on 8082 with read-only chain
      state and a separate writable receipt store.
- [ ] Once DNS and the reviewed local checks pass, the public testnet and site
      are deployed only by the explicit operator handoff
      `./deploy/scripts/deploy-testnet-remote.sh racknerd-chi`; implementation
      work does not run this command.
- [ ] The four-role local drill proves a node-free contributor's commitment in
      H100; its reveal plus A-to-B transaction in H101; B's signed B-to-C
      transaction crossing real P2P into H102; restart durability at H103; and
      three-node/explorer agreement. D's directory contains only private
      wallet/commitment state and no node database; before H100, relay
      phase-one state contains no private key, blind, solution source,
      consensus share signature, or encoded share.
- [ ] Relay evidence covers all branch-projected statuses, exact replay,
      first-16 admission and seventeenth rejection, one pubkey per context,
      miner-owned contribution-first R8 selection, one-block payout maturity,
      reorgs, backups, incidents, and bounded resources without claiming Sybil
      resistance, custody, or guaranteed inclusion.
- [ ] The 48-hour gate in [`docs/testnet.md`](docs/testnet.md) passes after
      H16/H17 with independent-node, consensus, recovery, explorer/pool, abuse,
      log, and resource evidence.
- [ ] No unresolved consensus divergence, database corruption, premature
      contributor-secret disclosure, censorship incident, or resource-growth
      trend remains at the gate.
- [ ] Testnet coins and keys remain worthless and disposable; no production key
      or mainnet state was used, and no chain or pool testnet state is promoted
      to mainnet.
- [ ] Every prior public-testnet chain or relay database was archived or moved
      aside and no reset binary opened it. The reset starts at height 0 with
      marker
      `SigilCoin public testnet reset - 2026-09-02` and timestamp
      `1788307200`; retained `d3 7a 91 c5` magic is not evidence of state
      compatibility.

Passing this gate authorizes only the separate mainnet soak. It does not
authorize a mainnet push, deployment, DNS change, or launch.

## 1. Freeze the puzzle language and the generator

`packages/sigil-coin-puzzle` is consensus. The interpreter decides whether a
block's program solves its puzzle, and the generator decides what the puzzle
is. A node that disagrees with its peers about either one is on a different
chain, silently — there is no version negotiation on the wire that would
surface it.

- [ ] No open work on `src/sigil/coin/puzzle.sgl`,
      `src/sigil/coin/puzzle/constraints.sgl`, or
      `src/sigil/coin/puzzle/generator.sgl`. Merge or abandon it now.
- [ ] Full suite green:
      `nix develop /home/trev/Workspace/sigil -c /home/trev/Workspace/sigil/sigil/build/dev/bin/sigil test --redirects ./dev-redirects.sgl --no-color`
- [ ] Tag the freeze so the launch commit is nameable, and say in the tag
      message that the puzzle layer is frozen.

After this point a change to either file is a hard fork requiring every node
to upgrade in lockstep. Treat "we should add one more builtin" as a
post-launch discussion, not a launch blocker. `docs/consensus.md` is the sole
normative protocol specification.

The same freeze applies to `sigil-coin-consensus`: emission, solution rules,
header lottery, coinbase codec, and fork choice. Producer solutions must
satisfy `L <= par`; shares must satisfy `L < personalized_par`. The generator's
shorter verified witness (hidden on ties) has length exactly `par`, so an
eligible producer candidate is always available. It does not itself produce a
block: the builder must find a qualifying block cursor.

## 2. Choose the genesis quote and regenerate the constants

Genesis carries a quote from `#systemcrafters` in its coinbase. The quote IS
the genesis hash: change one byte and every constant below changes.

- [x] Quote: `Sigil - Practical Symbolic Power`, with no third-party text.
- [x] Replacement timestamp: `1789228800` (`2026-09-12T16:00:00Z`), a
      staffed launch window selected after the optimized nonce loop invalidated
      the previous target calibration.
- [x] From a clean cache, run the canonical all-network generator:

      cache=$(mktemp -d); trap 'rm -rf "$cache"' EXIT
      nix develop -c env XDG_CACHE_HOME="$cache" \
        sigil deps install --redirects ./dev-redirects.sgl
      nix develop -c env XDG_CACHE_HOME="$cache" \
        sigil deploy/genesis-constants.sgl --redirects ./dev-redirects.sgl

      The empty cache is part of the check: a launch-critical genesis must
      compile from the current source, never reuse bytecode from an older build.
      The 2026-09-11 run independently returned mainnet cursor `(6,
      3129183091)` and reproduced every checked-in mainnet, testnet, and regtest
      coinbase, merkle root, header, hash, and display id exactly.

      Record the selected final mainnet quote, timestamp, compact target,
      80-byte header hex, internal hash, and display id emitted by that run.
      Never reuse values generated before the packed `version`, compact target,
      and nonce-lottery cutover.

- [x] An independent OpenSSL scanner exhausted all `2^32` header nonces for
      coinbase lock-times 0 through 5, then found the first lock-time 6 hit at
      nonce `3129183091`. Before the final scan it reproduced the withdrawn
      genesis's known first nonce, header, hash, and id byte-for-byte.

- [x] Check `quote-bytes` against the 400-byte graffiti cap. 32 bytes used,
      368 to spare. It is a BYTE
      count of the UTF-8 the coinbase actually carries, not a character
      count, so a quote with any non-ASCII in it costs more than it looks.

- [x] Copied the replacement quote/time/target and atomic
      `(coinbase-lock-time, nonce, header, id)` constants to `chain.sgl` and
      `genesis.sgl`; testnet and regtest constants remain unchanged.
- [x] Focused consensus, node/genesis, network, CLI, site, and explorer
      integration suites pass. `test-node.sgl` rebuilds all three genesis
      blocks and checks the calibrated main header's time, target, coinbase
      lock-time, nonce, and lottery qualification.

## 3. Stand the seed host's DNS up

`sigilcoin-main-chain` ships `seed.sigilcoin.lol:19444`. The earlier
`.invalid` placeholder never resolved, by design — a node with no configured
peer found nothing and said so, rather than silently reaching a stranger's
host. It is gone.

- [x] `seed.sigilcoin.lol` A resolves publicly to `104.223.122.157`.
- [x] `seed-peers` in `chain.sgl` is `(("seed.sigilcoin.lol" . 19444))`.
- [ ] Re-run the suite, rebuild, and confirm a fresh data directory finds the
      seed with no `--peer` flag and no manual `peers add`.

DNS must resolve before step 5. Otherwise every new node needs a hand-typed
peer, and the first thing anyone would ask in the channel is what to type.

## 4. Publish the parameters

Publish before the announcement, so the first person who reads it can verify
rather than trust. A file in the repository is enough; a gist is not — it
should be in the same place the code is.

- [x] Genesis display id
      `000000000b25af1072272ae97b606d64b340fc8f61f78f04c3e794025832b969`;
      internal hash
      `69b932580294e7c3048ff7618ffc40b3646d607be92a277210af250b00000000`.
- [x] Genesis header
      `809061200000000000000000000000000000000000000000000000000000000000000000f7278556687a298a5f50eeea93a1bf1a6fabb91b164d6fca115ff754c90d5cd90077a56a04cf2b1c738b83ba`;
      coinbase lock-time `6`, header nonce `3129183091`, quote
      `Sigil - Practical Symbolic Power`.
- [ ] Network magic `8f d1 c0 a5`, default port 19444, protocol version
      70015, user agent `/sigilcoin-node:0.1.0/`.
- [ ] Address format: bech32, HRP `sgl`, so addresses read `sgl1…`.
- [ ] Scheduled subsidy: 1 SGL per block for heights 1..30, then 100 SGL
      halving every 730 blocks. The sum
      `14302999991970` daviwils (`143029.99991970 SGL`) is the scheduled
      maximum, not guaranteed issuance. Genesis is unspendable and pays zero.
- [ ] Actual issuance and payout: solo blocks mint `floor(4*S/5)` subsidy and
      route all fees to the producer, leaving the reserve unminted. Cooperative
      blocks mint `S+F`; shares in canonical pubkey order divide
      `floor(S/10)` by verified contributions 1..4, the parent carrier receives
      `floor(S/20)`, and output 0 receives fees and every integer residual.
      Required share/carrier outputs remain even at value zero.
- [ ] Rules a miner hits: producer solutions must be at most their generated
      par (`L <= par`) and 512 bytes; shares must be strictly below their
      personalized par (`L < personalized_par`); graffiti is at most 400 bytes,
      blocks at most 16384 bytes, and puzzles contain at most 8 example pairs.
      `version = 0x20600000 | ((L-1)<<12) | C`; `bits` is the canonical compact
      base target. The builder searches the uint32 header nonce, then increments
      the coinbase transaction's final uint32 `lock-time`, rebuilds its txid and
      merkle root, resets the nonce, and continues. The full-header roll must
      not exceed
      `min(2^255-1,(compact-target(bits)+1)*2^min(max(par-L,0),8)-1)`.
      Mainnet begins at `0x1c2bcf04`: about 25,098,045,881 rolls at par or
      98,039,242 at `par-8`. Every 16 blocks, the preceding 15 timestamp
      intervals retarget bits with a 0.25x..4x clamp toward one block per day.
      The one-second parent floor only keeps timestamps monotone; future drift
      is 7200 seconds. Coinbase maturity is 1; the mainnet wallet waits six.
- [ ] Fork choice, stated plainly: greater cumulative compact-target base work
      wins; equal work prefers greater height; an exact work-and-height tie
      retains the first valid arrival. Golf savings change admission odds, not
      credited chain work.
- [x] Initial target frozen after benchmarking both launch hosts with the
      optimized nonce loop. Measured at-par search was 290,487 rolls/s locally
      and 230,801 rolls/s on `racknerd-chi`; the faster host gives `0x1c2bcf04`,
      25,098,045,881 expected rolls or 24 hours at par. The final genesis uses
      this target.

Anyone can check the internal hash with `sigilcoin status` on a fresh data
directory and reproduce header, hash, and display id with
`deploy/genesis-constants.sgl`.

## 5. Stand up the seed node and the explorer

Follow [`deploy/RUNBOOK.md`](deploy/RUNBOOK.md); the checklist here is only
the launch-day gate.

- [x] `deploy/flake.lock` pins `sigil-bitcoin` at reviewed descendant
      `4ecc1f188c51887450eb448b991dae28ba36dfa0`, which contains the
      durable-parent seven-argument connector seam.
- [x] `cd …/sigil-coin/deploy && nix flake check` passes on the build host.
      The number it prints is what was left to build (three checks exist;
      zero once cached), so do not read it as a pass count. Force all three:
      `nix build --rebuild --no-link .#checks.x86_64-linux.module-eval .#checks.x86_64-linux.sigilcoin-runs .#checks.x86_64-linux.sigilcoin-durable-parent`.
      Checks build both binaries, mine H1 then close/reopen for H2 through the
      durable-parent seam, and validate node, sync and explorer units, their
      canonical flags and state paths, firewall port 19444,
      wallet/data-directory modes, and absence of any
      `sigilcoin-listen-proxy` unit.
- [x] Final remote image `sigilcoin-local:mainnet` built from the reviewed
      source with image id
      `sha256:d782e6104def14cd7f59fed37c714c33f61d0d9cccfe8de4a295d322ad2be86a`.
      Fresh containers returned zero for `sigilcoin help`, `sigilcoin version`,
      `sigilcoin-explorer --help`, and `sigilcoin-explorer --version`; both
      versions print `0.1.0`.
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
- [ ] Explorer up at `explorer.sigilcoin.lol` behind a TLS reverse proxy. The
      mainnet explorer itself stays bound to `127.0.0.1:8081`; the proxy is the
      only public path. Smoke-test canonical routes `/`, `/blocks`, `/difficulty`,
      `/block/0`, `/api/summary`, `/api/blocks`, `/api/difficulty`, and
      `/api/block/0`. If explorer is not ready, launch without it and say so
      rather than delaying — a chain with no explorer is fine; a chain with no
      seed is not.
- [ ] A second node, on different hardware and a different network, syncs
      from the seed and reaches the same tip. One node is not a network.

## 6. The announcement

`#systemcrafters` on Libera tolerates roughly one message a day. This is
that message. Post it once, do not follow up with a thread, and answer only
direct questions.

Draft, to send as-is:

> SigilCoin is up: a blockchain where program golf weights a lightweight
> header-nonce lottery. Each block publishes input/output pairs and a rule for
> the day. Write a function no longer than the printed par; every byte saved
> doubles its odds, up to eight bytes, while the CLI searches the nonce
> automatically. Mining with a model or search script is the intended way to
> play, not a loophole. It's written in Sigil, it's worth nothing and is never
> intended to be worth anything, and there's no premine. Blocks target one a
> day. Graffiti in the coinbase is by convention a quote from here. Code and
> network parameters: https://github.com/trevarj/sigil-coin. To play: build
> `sigilcoin`, run `sigilcoin sync`, then `sigilcoin puzzle` and
> `sigilcoin mine --solution '<your program>'`.

Before sending:

- [ ] The claims match what shipped: worth nothing, no premine, one block a
      day, producer `L <= par`, and shorter programs improve capped lottery
      odds rather than deterministically winning.
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
resolving without intervention (same-height accepted siblings retain the first
arrival until an explicit child settles the height);
`issued-supply` matching active-chain coinbase issuance and never exceeding
`scheduled-supply-cap`; disk growth measured and extrapolated. At 16384 bytes
per block, roughly 6 MB a year should be a non-issue.

**Ongoing:** back up `wallet/wallet.key` and the database on a schedule; watch for
anyone reporting a solution their node accepts and the seed rejects, which
is the consensus-divergence signal and the one thing worth waking up for.

---

## Pre-launch mainnet soak

Do not begin this soak until every checkbox in
[Complete the public testnet](#0-complete-the-public-testnet) is checked with
preserved evidence. Public testnet completion does not replace this mainnet-rules
soak. Run it before step 5, not after.

Run mainnet rules — `--chain sigilcoin-main`, not regtest — on two nodes for
**at least 24 hours**. The remote tag
`sigilcoin-rehearsal:pre-calibration-optimized` pins image
`sha256:a242ba169e64b28255ed65fc9e6f05e972c354278cbf4500bca3afc7d6749163`
to mine through H17 quickly within the 768 MiB container limit, so both H16
retargets execute; that accelerated
chain tests consensus, not final cadence. Then leave both nodes connected for
the full rehearsal while
observing cumulative-work fork choice, disconnect/reconnect behavior, restart
recovery, commit/reveal, and exact agreement. This compressed rehearsal accepts
that long-duration resource and network behavior remains untested.

The corrected rehearsal ran from `2026-09-08T12:38:33Z` through
`2026-09-09T12:41:14Z`. Twenty-seven hashed snapshots record both nodes at
the same H20 tip, work `352326912`, 20 validated bodies, and
`16.00000000 SGL` issued. Both containers remained inside their limits with
no OOM or unplanned restart; disconnect/reconnect, clean restart, planned
hard-kill recovery, restore, over-par rejection, 400/401-byte graffiti, and
first-seen sibling/child drills completed.

This closes the elapsed-time, synchronization, recovery, and resource portion
only. It does not close the launch gate while the public-testnet checklist and
the operational exact-size, forced-timestamp, exact-target, and full varied
sibling drills below remain unresolved.

On `racknerd-chi`, the prepared launcher refuses to run before the testnet gate:

```sh
bash /srv/sigilcoin/sigil-coin/deploy/scripts/start-mainnet-rehearsal.sh
```

What to run:

- Two isolated mainnet nodes with separate databases: rehearsal A listens only
  on the private Docker network and rehearsal B syncs from A. Same-host failure
  independence is deliberately not claimed by this compressed rehearsal.
- Mine deliberately awkward blocks: a producer solution exactly at par,
  graffiti at exactly 400 bytes, a block filled to the 16384-byte cap, and a
  block at the earliest legal timestamp. Confirm a producer source above par
  and a header roll just above its target are rejected, while the boundary
  target is accepted. Submit same-height qualifying siblings with different
  lengths, contributions, nonces, and hashes; none may displace the first valid
  arrival. Submit the incumbent's child, then a late sibling, to exercise
  first-seen retention and explicit child settlement.
- Restart both rehearsal containers at least once. Kill rehearsal A with
  `SIGKILL`, restart it, and require B to regain the identical validated tip.
  If SQLite leaves a hot journal, let the writable node open the database and
  complete rollback before any read-only inspection; never delete the journal.
- Restore matching chain state into a separate empty directory and confirm the
  address, balance, tip, target, and cumulative work match.

What to watch daily, all as changes between two readings rather than as
absolute values:

- `validated-blocks` identical on both nodes at the same height. Not
  "rising" — identical. A difference here is the consensus signal.
- `peer-successes` larger than yesterday's reading on both nodes. This
  replaces "`sync-last-error` empty", which no healthy node can satisfy: a
  peer hanging up is the normal end of a conversation and leaves an error
  string behind.
- `issued-supply` matching the active UTXO aggregate and independently summed
  actual subsidy issuance, with `issued-supply <= scheduled-supply-cap`.
- Record `docker inspect` restart counts and running state for
  `sigilcoin-main-rehearsal-a` and `sigilcoin-main-rehearsal-b` at start and
  finish. Any unplanned restart is a failure.
- Record `docker stats --no-stream` CPU, memory, PIDs, and block I/O for both
  containers; usage must flatten under the configured limits.

**Abort the launch if any of these happen:**

- The two nodes disagree about the tip at the same height for any reason
  other than a reorg that resolves within one block. That is a consensus
  split, and it is fatal.
- A block one node accepts, the other rejects.
- `issued-supply` differs from active-chain actual issuance by one daviwil or
  exceeds `scheduled-supply-cap`.
- The database is corrupt after a hard kill, or a restore does not reproduce
  the balance.
- A single uncached worst-case block exceeds the documented roughly 74.3-second
  consensus ceiling, or ordinary blocks routinely approach it. Validation is
  bounded but not cheap; measure hostile blocks separately from normal ones.
- Rehearsal B cannot reach `main-a:19444` on the private
  `sigilcoin-main-rehearsal` network while A reports running. No host port is
  published during this rehearsal; off-host reachability is a launch-day check.
- `peer-successes` is flat for a full day on either node while blocks are
  being mined.
- Memory or CPU climbs steadily over the soak rather than flattening.

Anything else — an explorer bug, an ugly log line, a missing convenience
flag — is a post-launch fix, not an abort.

---

## Decisions still owed by the operator

The table is the authoritative list. Several choices remain in addition to
DNS and TLS, and nothing unresolved here can be deferred past step 5.

| # | Decision | Where it lives now |
| --- | --- | --- |
| 1 | ~~The genesis quote~~ — RESOLVED: `Sigil - Practical Symbolic Power`, the operator's own words, so no third-party permission is needed. 32 UTF-8 bytes, 368 under the 400-byte graffiti cap. | `coin-genesis-quote` in `packages/sigil-coin-node/src/sigil/coin/node/chain.sgl` |
| 2 | ~~The genesis timestamp~~ — RESOLVED: `1789228800` (`2026-09-12T16:00:00Z`). | `coin-genesis-time` in `packages/sigil-coin-node/src/sigil/coin/node/chain.sgl` |
| 3 | ~~Final mainnet genesis constants~~ — RESOLVED by an exhaustive independent scan: first qualifying pair `(coinbase lock-time 6, header nonce 3129183091)` for the selected quote, timestamp, and `0x1c2bcf04` target. | `coin-genesis-coinbase-lock-time-constant`, `coin-genesis-nonce-constant`, `coin-genesis-header-constant`, and `coin-genesis-id-constant` in `genesis.sgl` |
| 4 | ~~The real seed DNS name~~ — RESOLVED: `seed.sigilcoin.lol:19444`, on the operator's own domain. The A/AAAA records still have to exist before step 5. | `sigilcoin-main-chain` seed peers in `chain.sgl` |
| 5 | ~~Where the repository is published~~ — RESOLVED and confirmed: `https://github.com/trevarj/sigil-coin`, the operator's account. Every `package.sgl` and the announcement now say so. | `package.sgl` files, the step 6 announcement |
| 6 | ~~`depsHash`~~ — RESOLVED. There is no vendoring derivation and no hash to fill in: every `from-git` dependency is a pinned flake input, so Nix fetches it and the sandbox stays offline. Bumping one is `nix flake update <input>` in `deploy/`. | — |
| 7 | ~~Confirm the explorer's flags~~ — RESOLVED. `--regtest`, `--data-dir`, `--host`, `--port` confirmed against `explorer-main` and against `sigilcoin-explorer --help` run from the built binary. | `services.sigilcoin-explorer.command` in `deploy/module.nix` |
| 8 | The TLS certificate for `explorer.sigilcoin.lol` | Still owed. The domain is `sigilcoin.lol` and the explorer's public name is `explorer.sigilcoin.lol` (`deploy/RUNBOOK.md`), but nothing in the tree issues or terminates a certificate: that is the reverse proxy's job on the host. |
| 9 | Whether to launch without an explorer if it is not ready | Recommendation: yes |
| 10 | Complete the 48-hour public-testnet gate, then run the 24-hour private mainnet rehearsal | Required for the compressed experimental launch; see [Complete the public testnet](#0-complete-the-public-testnet) and [Pre-launch mainnet soak](#pre-launch-mainnet-soak). |
| 11 | Whether to accept untested payout incentives | Still owed. Solo targets 80%; cooperative targets 85% producer, 10% contribution-weighted shares, and 5% carrier, with fees and residuals to the producer. Regtest proves exact enforcement, not public participant behaviour. |
| 12 | ~~Whether `sigilcoin listen` gets a persistent accept loop before launch~~ — RESOLVED IN THE CLI, not worked around. `run-listen` now loops indefinitely under `--max-connections 0` (`operate.sgl`: `((= max-connections 0) (loop last))`) and serves each connection inside its own guard, so a hangup, garbage bytes or a silent drop kill that connection only. Re-measured against this build: idle at `--accept-timeout 2000` it was alive at 30 s and 55 s and ended only by an external `timeout`; six hostile connections were absorbed and a seventh still accepted. The seed therefore binds 19444 itself. | `packages/sigil-coin-cli/src/sigil/coin/cli/operate.sgl`, `deploy/module.nix` |
| 13 | Replace local deployment source pins with public forge URLs after the approved push | The current flake deliberately uses local `git+file:` inputs because required SigilCoin and sigil-bitcoin commits are not public yet. Manual local testnet approval and explicit push permission come first; then pin the pushed revisions and repeat every Nix check. |
| 14 | ~~Whether to delete the socket proxy once the CLI can adopt an inherited fd~~ — DELETED NOW, and no fd adoption was needed. The proxy existed only because the old listener died on an accept timeout and on hostile input; with that fixed it was pure cost: an extra unit pair and hop, no inbound peer address ever reaching the node (which forecloses abuse-banning), and a `Restart=always` without `StartLimitIntervalSec=0` that could park `systemd-socket-proxyd` in `failed` and take port 19444 out of service — the outage it was supposed to prevent. `nix flake check`'s `module-eval` now fails if any `sigilcoin-listen-proxy` unit comes back. | `deploy/module.nix`, `deploy/flake.nix` |
