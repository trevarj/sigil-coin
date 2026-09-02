# Deterministic simulation

The simulator is a reproducible executable experiment over production
consensus APIs. It is a bounded observer model, not a network simulator,
profitability model, equilibrium claim, or deployment soak.

## Reproduce

From the repository root:

```sh
bash tools/run-simulation.sh
bash tools/run-simulation.sh --check
```

The runner rebuilds the simulator, replaces `tools/simulation-output/`, writes
the eight schema-4 artifacts below, regenerates `SHA256SUMS`, and hashes that
manifest. The pinned reproducibility digest is:

```text
a23487ab2bb4eea4eb18b42169ae26b6ce6582967daf69d1c1af192f99ed578e
```

`--check` succeeds only when the regenerated manifest has that digest.

## Artifact contract

The tracked schema-4 output is exactly:

| File | Contents |
| --- | --- |
| `censorship.csv` | H/H+1 commitment, reveal, payout, scheduled subsidy, fees, minted, and unminted accounting |
| `market.csv` | per-height observer trace with legal arrivals before child, explicit child settlement, transactions, payouts, and issuance |
| `payouts.csv` | deterministic solo/cooperative payout vectors with contribution sums, min/max shares, minted, and unminted values |
| `puzzles.csv` | ordinary and forced-constraint generator observations |
| `results.json` | schema, frozen inputs, aggregates, and limitations |
| `shares.csv` | personalized candidate availability; absent candidates use zero numeric metrics |
| `strategy.csv` | the 21-row copy-and-attach key-pool/strategy matrix |
| `summary.txt` | concise human-readable results |

`ordering.csv` and the old `aggregate_ordering` result are gone. The schema-4
JSON key is `strategic_mining`.

## Production seams

The experiment calls the production generator, validators, score projection,
fork comparator, payout planner, builders, connector, header-context checks,
reward schedule, cumulative scheduled cap, and secp256k1 signing/verification.
In particular, signed share records pass through `coin-check-shares`;
contributions come from `coin-share-quality`; aggregate quality comes from
`coin-quality`; payouts come from `coin-payout-plan`; and replacement decisions
come from `coin-score-compare` and `coin-replaces-tip?`.

No simulator-local validity, quality, payout, or ranking formula substitutes
for those APIs.

## Puzzle and share sweep

The deterministic survey covers:

- 12 byte seeds,
- heights `0, 1, 16, 255, 4096`,
- complexities `16, 255, 256, 512, 1024, 2560, 4095`,
- all eight constraints through forced cases.

That yields 420 ordinary puzzles plus 8 forced-constraint cases. The current
artifact records:

| Metric | Result |
| --- | ---: |
| puzzles that retried | 83 / 420 |
| maximum retries | 3 |
| fallbacks | 0 |
| table bytes, min / median / max | 65 / 114 / 297 |
| par bytes, min / median / max | 24 / 29 / 72 |

Personalized candidates are derived semantically, never by deleting whitespace.
Every ordinary example input must be non-string; the exact tight anchor
predicate `(equal? x"@")` is replaced with `(string? x)`; the candidate must
pass `coin-check-share-solution/spec` and be strictly shorter than par. If an
ordinary input is a string, no candidate is recorded.

Across deterministic key scalars `1..1024`, 683 semantic candidates are
available and 341 are unavailable. All available candidates in this frozen set
contribute 1, with margins 17..18 milli-units. Unavailability is data, not a
fabricated zero-margin share.

## Payout matrix

`payouts.csv` contains 162 rows:

- heights `0, 1, 30, 31, 730, 731, 1460, 24820, 24821`,
- fees `0` and `12345`,
- share counts `0..8`,
- cooperative contributions cycling `(1,2,3,4,...)` in canonical share order.

The matrix exercises the production contract:

```text
solo producer = floor(4*S/5) + F

cooperative carrier    = floor(S/20)
cooperative share pool = floor(S/10)
share_i                = floor(share_pool * c_i / sum(c))
cooperative producer   = S + F - carrier - sum(share_i)
```

Solo rows leave the unused scheduled reserve unminted. Cooperative rows mint
the full scheduled subsidy plus fees; fees and integer residuals reach the
producer. Required zero-value share and carrier outputs remain represented.

## Copy-and-attach strategy experiment

The fixed attack matrix models an attacker copying the original public producer
source into a sibling and attaching valid shares committed by the parent.
Parameters are frozen:

| Parameter | Value |
| --- | ---: |
| height | 32 |
| scheduled subsidy | 10000000000 |
| fees | 12345 |
| parent clock | 1800000000 |
| minimum spacing | 3600 |
| future drift | 300 |
| original arrival | 1800003300 |
| pre-child copy arrival | 1800003360 |
| child height / arrival | 33 / 1800006900 |
| post-child copy arrival | 1800006960 |

The key pools are `{0,1,8,16,64,256,1024}` and the strategies are:

- `none`: no commitments or reveals;
- `minimum-quality`: select the available candidate with the lowest positive
  contribution, breaking a tie by pubkey;
- `maximum-quality`: rank contribution descending and pubkey ascending, commit
  at most 16, reveal at most 8 of those, then canonical-sort by pubkey.

The largest pool is derived once and smaller pools reuse its prefixes, so each
key/spec/candidate is evaluated once. Nonempty rows build real parent
commitment records and real signed sibling shares. The production share path
must accept them before their contributions, `Q`, raw score words, projected
rank words, or payouts are reported.

The copy can have a different raw `W` and higher authenticated `Q`, but copying
the producer source preserves `(L, MB, SB)`, so its projected rank word equals
the original. `legacy_quality_rule_would_replace` is explicitly the historical
counterfactual `copy Q > original Q`. `canonical_copy_replaces` is only the
production comparator's answer.

The 21 rows report availability and selection counts, both qualities and score
words, pre- and post-child decisions, original-solver capture, reveal
inclusion, top-share concentration, payout HHI, hypothetical copy payouts, and
realized original/attacker payouts. Frozen outcomes are:

- 12 rows would replace under the obsolete quality rule;
- 0 canonical copies replace before the child;
- 0 canonical copies replace after the child;
- every row records an accepted child and 1000 permille original-solver
  capture;
- every losing copy realizes zero attacker payout.

At this height the winning original solo block pays `8000012345`, mints
`8000000000` subsidy, and leaves `2000000000` scheduled subsidy unminted.
Hypothetical cooperative-copy amounts remain separate from realized payoff.

## Child-observed fork helper

A candidate is `(actor, height, arrival, header)`. Arrival and actor sort only
the observer trace; they are not fork-choice inputs.

The first same-height arrival becomes incumbent. Before a child, each later
sibling calls `coin-replaces-tip?` with `extended? #f`. A child is accepted
only at `height+1` and only when it links to the selected incumbent. After that
child, later siblings call the same production rule with `extended? #t` and
cannot replace the settled block.

There is no timeout-based settlement or modeled fork window.

## Twelve-height observer market

The market trace starts at clock `1800000000`, uses 3600-second minimum spacing,
300-second future drift, 1400 modeled envelope bytes, and a 14984-byte modeled
transaction cap. Transaction bytes and fees are modeled inputs rather than wire
serialization.

Five frozen actors submit candidates:

- `fair-eager`,
- `fair-fee-waiting`,
- `strong-golfer`,
- `future-dater`, which submits one too-early timestamp and then a legal
  candidate but never censors,
- `urgent-censor`, which uses legal timestamps and omits urgent transactions
  but never future-dates.

The last two retain the same frozen producer tuple `(33,72,270)` so their
behavioral difference is not a score difference. Each of heights 1..12 has five
legal observations before an explicit child. Heights 1..11 use the next
`fair-eager` child; a height-13 sentinel settles height 12. Rewards are counted
only after the child is accepted.

Current aggregate observations:

| Metric | Result |
| --- | ---: |
| mined / settled heights | 12 / 12 |
| future-drift rejections | 12 |
| fork-choice rank losses | 48 |
| settled late candidates | 0 |
| censorship observations | 16 |
| transactions generated / confirmed / outstanding | 76 / 71 / 5 |
| fees confirmed / outstanding | 93250 / 8450 |
| mean / maximum confirmation latency | 3609 / 6950 seconds |
| scheduled subsidy | 1200000000 |
| minted / unminted subsidy | 960000000 / 240000000 |
| producer payout / total coinbase | 960093250 / 960093250 |

`strong-golfer` wins all 12 rows under the production projected-rank
comparator. The observations show exactly what the frozen trace does; they do
not predict a live network or establish censorship profitability.

## Interpretation limits

The artifacts demonstrate deterministic production behavior for the selected
inputs:

- generated witnesses are tight and executable,
- payout floors and issuance accounting are reproducible,
- attaching higher authenticated quality cannot change a copied producer's
  projected rank,
- settlement is explicit and child-observed.

They do not establish economic equilibrium, participant independence,
real-world propagation, mempool policy quality, or resistance to a determined
adversary. Consensus proves distinct pubkey-personalized tasks and verified
work, not distinct owners.

