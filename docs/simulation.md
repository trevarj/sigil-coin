# Deterministic simulation

The simulator is a bounded, reproducible experiment over selected production
APIs plus an explicit observer model. It is not a network simulator,
profitability model, equilibrium result, or deployment soak.

The current runner targets schema 5 and scheduled proof-of-golf with height-only fork choice.
The checked schema-4 artifacts are archived unchanged in
`tools/simulation-output-schema-4-historical/`; they describe the superseded
nonce-PoW/first-seen experiment, not the replacement protocol. No schema-5
observations or successful validation run are claimed by this documentation
cutover.

## Reproduce

From the repository root, the runner interface is:

```sh
bash tools/run-simulation.sh
bash tools/run-simulation.sh --check
```

A current run rebuilds the simulator and writes schema-5 output to
`tools/simulation-output/`, including `SHA256SUMS`. `--check` compares two
fresh deterministic runs. It does not compare the new protocol to the archived
schema-4 golden digest, and no schema-5 golden hash is invented here. The old
artifacts remain historical even if a new run succeeds.

## Artifact contract

The output families are:

| File | Contents |
| --- | --- |
| `censorship.csv` | H/H+1 commitment, reveal, payout, scheduled subsidy, fees, minted, and unminted accounting |
| `market.csv` | bounded observer trace, synthetic score inputs, child observations, modeled transactions, payouts, and issuance |
| `payouts.csv` | deterministic solo/cooperative payout vectors with contribution sums, share amounts, minted, and unminted values |
| `puzzles.csv` | ordinary and forced-constraint generator observations |
| `results.json` | schema, fixed inputs, aggregates, and limitations |
| `shares.csv` | personalized candidate availability; absent candidates use zero numeric metrics |
| `strategy.csv` | the 21-row copy-and-attach key-pool/strategy matrix |
| `summary.txt` | human-readable results from that run |

Schema 5 uses `strategic_golf` and a `golf_scoring` object with
`max_savings`, `genesis_score`, `rule`, and `examples`. Those examples assume
valid producer lengths at `par = 100`; they exercise arithmetic, not solver
discoveries. Schema 4 used `strategic_mining`. Neither the old key nor its
numbers should be presented as a new run.
Schema-5 field names remain stable across the longest-height cutover. Existing
score-caused replacement counters stay zero: score changes cannot select a
branch. Score-tie and lower-score observations describe displayed quality only.

## Production contract and modeled seams

The production rules and displayed golf-quality arithmetic are:

```text
valid producer length: 1 <= L <= min(512, par), with a correct program
savings             = min(8, max(0, par - L))
block_score         = 1 + savings                 non-genesis only
chain_score(genesis) = 0
chain_score(block)   = chain_score(parent) + block_score(block)
replace incumbent   iff valid candidate.height > incumbent.height
```

The generated at-par fallback is valid and scores 1; one saved byte scores 2;
eight or more score 9. The public APIs are `coin-golf-max-savings`,
`coin-golf-savings(par, length)`, and `coin-golf-score(par, length)`.
An over-par source stays invalid even though the arithmetic clamp returns
zero savings. Equal height preserves the durable active incumbent, regardless
of golf score, hash, or arrival metadata. Golf scores display competition
quality; they do not select branches or currently alter subsidy.

Production chain configs hardcode `(height . internal-hash)` checkpoints, and
incompatible branches cannot cross them. Checkpoints advance only in reviewed
software releases; nodes must upgrade to share a newer one. Mainnet currently
pins H0 and H1 on the replacement slogan chain; public testnet and regtest
remain H0-only, protecting genesis but no post-genesis history. Reorgs remain
possible above H1 on mainnet and above H0 on testnet and regtest. The mistaken
marker-quote mainnet H0/H1 and its H1 checkpoint are abandoned; the current
slogan-chain identity and H1 hashes are in
[the consensus specification](consensus.md#58-hardcoded-release-checkpoints).
There is no automatic or signed-checkpoint finality.

Headers stay 80 bytes. Non-genesis time is exactly
`parent.time + network_spacing` and must not be in the future; mainnet uses
86400 seconds, with shorter configured test-network slots. Nonce is zero and
`bits` is fixed at the network pow limit as a compatibility field. A
non-genesis coinbase has version 1, one input with sequence `0xffffffff`, no
witness, zero `nLockTime`, and empty graffiti. The producer builds one complete
candidate without hash-target validation, search, or hash-difficulty retarget.

Puzzle VM caps, `L <= par` producer validity, the relative-margin
puzzle-complexity retarget, co-op commitments and signatures, strict
`L < personalized_par` shares, ordinary transactions, and payout arithmetic
remain unchanged.

The puzzle/share sweeps and copy-and-attach path call the production generator,
source validators, signing/verification, builders, and connector. Verified
shares pass through `coin-check-shares`; contributions use `coin-share-quality`
and payouts use `coin-payout-plan`.

The observer market is deliberately narrower. Its bodyless candidates carry
synthetic par/program-length inputs and use the real golf arithmetic. They are
not full valid blocks and do not demonstrate that a solver found programs of
those lengths. The fork helper compares supplied heights in a bounded tree.
It is not the durable production node, does not enforce release checkpoints,
and does not establish full block validity or a second consensus rule.

## Puzzle and share sweep

The configured survey retains:

- 12 byte seeds,
- heights `0, 1, 16, 255, 4096`,
- complexities `16, 255, 256, 512, 1024, 2560, 4095`,
- all eight constraints through forced cases.

That is 420 ordinary puzzles plus 8 forced-constraint cases. For each ordinary
puzzle the shorter verified hidden/table witness, hidden on ties, supplies an
at-par producer candidate. No hash search is needed to use it in a scheduled
score-1 candidate; the other block rules still apply.

Personalized candidates are derived semantically, never by deleting whitespace.
Every ordinary example input must be non-string; the exact tight anchor
predicate `(equal? x"@")` is replaced with `(string? x)`; the candidate must
pass `coin-check-share-solution/spec` and be strictly shorter than par. If an
ordinary input is a string, no candidate is recorded. The configured key sweep
uses deterministic scalars `1..1024`. Availability is measured output, not an
assumption or a fabricated zero-margin share.

### Historical schema-4 observations

The archived run recorded these generator results:

| Metric | Historical result |
| --- | ---: |
| puzzles that retried | 83 / 420 |
| maximum retries | 3 |
| fallbacks | 0 |
| table bytes, min / median / max | 65 / 114 / 297 |
| par bytes, min / median / max | 24 / 29 / 72 |

It also recorded 705 available semantic candidates and 319 unavailable among
1024 keys. All available candidates in that old fixture contributed 1, with
margins 17..18 milli-units. These numbers are retained as historical evidence
only; unchanged generator rules do not turn them into a new execution.

## Payout and censorship matrices

The payout matrix is configured for 162 rows:

- heights `0, 1, 30, 31, 730, 731, 1460, 24820, 24821`,
- fees `0` and `12345`,
- share counts `0..8`,
- cooperative contributions cycling `(1,2,3,4,...)` in canonical share order.

It calls the unchanged production contract:

```text
solo producer = floor(4*S/5) + F

cooperative carrier    = floor(S/20)
cooperative share pool = floor(S/10)
share_i                = floor(share_pool * c_i / sum(c))
cooperative producer   = S + F - carrier - sum(share_i)
```

Solo blocks leave the unused scheduled reserve unminted. Cooperative blocks
mint the full scheduled subsidy plus fees; fees and integer residuals reach
the producer. Required zero-value share and carrier outputs remain represented.
The censorship matrix has 32 configured rows covering the commitment/reveal
path and its payout accounting. Row counts and formulas are experiment inputs,
not new measured results or evidence of incentive compatibility.

## Copy-and-attach strategy experiment

The fixed 21-row matrix models copying a public producer source into a sibling
and attaching valid shares committed by the parent. It crosses key pools
`{0,1,8,16,64,256,1024}` with no-share, minimum-contribution, and
maximum-contribution strategies.

The largest pool is derived once and smaller pools reuse its prefixes.
Unlike the bodyless observer market, this path constructs real parent
commitments, signed shares, and complete blocks for production connection.
Canonical empty graffiti, zero nonce, and fixed `bits` replace the old search
cursors. A run must validate those bodies before reporting their payouts.

Copying the same producer source preserves its displayed block score. Attached
share quality changes payout accounting, not fork choice. Only a strictly taller
valid checkpoint-compatible branch can replace the incumbent; equal height
cannot. Shortening a source alone cannot win, and a child does not settle
history above the latest checkpoint.
Hypothetical cooperative-copy payouts are separate from realized payoff.

### Historical schema-4 strategy outcomes

The old first-seen fixture recorded 12 of 21 rows with a quality-only
counterfactual copy advantage, no pre-child copy replacements, and no
post-child copy replacements. Every row accepted the original's child and
reported 1000 permille original-solver capture; losing copies realized zero
attacker payout.

Those outcomes belong to the archived helper and retired admission rules.
They do not prove copy resistance, authorship protection, or finality under
the current protocol, and are not schema-5 results.

## Bounded fork helper and observer market

The helper observes one sibling height and immediate children of any observed
sibling, rather than a full chain. It tracks the selected root sibling and the
best root/child tip, comparing heights strictly. Equal height keeps its
incumbent, irrespective of score, hash, or arrival metadata. Trace outcomes are
`taller-chain`, `height-tie`, or `shorter-chain`. `child-observed?` reports a
child on the selected branch; it does not mean finality. This bodyless helper
does not model the production node's release checkpoints.

The market uses exact `parent.time + 3600` slots and zero future drift. Its
program lengths and par values are synthetic score inputs; transaction sizes
and fees are modeled rather than wire-serialized inputs. Payouts, censorship,
arrival order, timestamp rejection, and child observations are bounded
scenario behavior, not a live-network propagation or profitability result.

Its fixed synthetic par is 256 bytes. Ordinary producer length 256 gives
savings 0 and score 1; the strong-golfer length 248 gives savings 8 and score 9.
These are not measured source sizes or executed programs. Genesis score is
zero; timestamps follow `start + height * slot`, independently of actor arrival
delays. CSV exposes the synthetic inputs, parent/branch scores, and child/tip
observations so the arithmetic is distinguishable from solver output.

The height-13 sentinel is lookahead only. Payout and fee accounting covers
selected heights 1..12 without a child-based reward gate or irreversibility
claim. No resulting winner counts or cumulative totals are asserted here.

The historical schema-4 twelve-height trace used a 3600-second minimum spacing
and 300-second future allowance. It retained `fair-eager` at all 12 heights and
counted 48 later candidates as first-seen losses; a height-13 sentinel was
treated as settling the last modeled height. Those timestamp and settlement
assumptions are superseded. None of those outcomes is asserted for schema 5.

## Interpretation limits and network cutover

The old launch was retired before height 1 because compute burn contradicted
the project's intent. Replacement networks start from new genesis identities
in fresh `state/*-proof-of-golf` directories; old state is archived and never
reused. A low-CPU scheduled producer builds a complete candidate once. No old
hash-search compatibility path is retained.
The authorized mainnet slogan reset changes its genesis identity and transport
magic to `SGM4`, retaining timestamp `1789228800`. Abandoned marker-quote
mainnet chain and relay state must be archived, not reused. Testnet and regtest
retain their genesis identities, timestamps, and `SGT3` / `SGR3` magic; their
existing proof-of-golf H0 state may be reused.

The bounded simulation does not exercise durable-node restart persistence,
arbitrary deep branches, real peers, network convergence, propagation delay,
or hostile validation traffic. In particular it must not be used to dismiss
these production limitations:

- Public witnesses make equal-height alternatives cheap to build. Past slots
  need no new wall-clock wait, but better golf score cannot make a shorter or
  equal-height branch win. Missed slots offer an opportunity for a replacement
  to become strictly taller.
- Equal-height forks retain local durable incumbents, not a globally agreed
  hash winner. Partitions can preserve different local branches.
- Reorgs remain possible above the latest release checkpoint: H1 on mainnet,
  H0 on testnet and regtest. Only reviewed releases and node upgrades advance
  that boundary.
  A child adds height, not finality.
- Fixed nonce and coinbase metadata do not eliminate parent-template
  manipulation through valid source, payout, transaction, commitment, or reveal
  choices that change the next puzzle.
- Personalized shares prove key-bound tasks and payouts, not distinct owners,
  scarce key generation, resistance to censorship, or economic equilibrium.

Scheduled proof-of-golf is a hobby-chain game, not settlement-grade security.
Historical observations, deterministic arithmetic, and reproducible model output
do not justify relying on it for valuable balances or payments.
