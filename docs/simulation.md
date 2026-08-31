# Reproducible survey and economic simulation

`tools/simulator/src/sigil/coin/simulation.sgl` reproduces puzzle, personalized-share, payout, commitment/reveal timing, and aggregate-ordering evidence through canonical APIs. It uses no clock, input files, host randomness, floating point, or network data.

## Run

From repository root:

```sh
bash tools/run-simulation.sh
bash tools/run-simulation.sh --check
```

Runner builds a native simulator so canonical libsecp256k1 bindings are present, writes `tools/simulation-output/`, and hashes generated artifacts. Checked aggregate hash:

```text
0a87130cd6387bf778669516aa806471d7e60e21e24c51ba5b15ca7395a5c277
```

Outputs:

- `puzzles.csv`: global and forced-constraint puzzles plus validation costs
- `shares.csv`: 64 personalized tasks, pure-preview candidates, margins, and quality
- `payouts.csv`: canonical split plans over emission boundaries, fees, and `R=0..8`
- `censorship.csv`: explicit commitment-height and reveal-height actors, decisions, and payouts
- `ordering.csv`: three-strong versus eight-weak aggregate ordering
- `results.json`: machine-readable parameters, API inventory, and aggregates
- `summary.txt`: human summary
- `SHA256SUMS`: per-artifact hashes

## Canonical measurements and cross-checks

Measured values come from these APIs:

- puzzle derivation and validation: `coin-puzzle-for`, `puzzle-for/constraint`, `coin-share-puzzle`, `coin-check-solution`, `coin-check-share-solution`
- personalized and aggregate quality: preview tuple `(spec report contribution)` from `coin-check-share-solution`, then `coin-share-margin-milli`, `coin-share-contribution`, and `coin-quality`
- ordering: `coin-score-encode`, `coin-score-better?`
- rewards: `coin-split-unit`, `coin-split-plan`, `coin-block-reward`, `coin-cumulative-supply`
- keys: `secp256k1-seckey-verify?`, `secp256k1-pubkey-create`, `secp256k1-pubkey-parse`

Simulator does not substitute local formulas for these results. Independent arithmetic exists only as assertions against API output:

- split weight/unit, producer remainder, and value conservation versus `coin-split-unit` and `coin-split-plan`
- contribution band arithmetic versus pure-preview `contribution`; simulator never reads verified-cache `coin-share-quality`
- packed score-word unsigned comparison versus `coin-score-better?`

Puzzle `steps` and `allocations` are exact canonical interpreter totals, not wall-clock or host-allocation measurements.

## Frozen parameters

| Parameter | Value |
|---|---|
| Seed bytes | `byte[j] = (11 + 31*seed_index + 7*j) mod 256` |
| Global seed indexes | `0..11`; height 0 uses canonical zero previous hash |
| Heights | `0, 1, 16, 255, 4096` |
| Complexities | `16, 255, 256, 512, 1024, 2560, 4095` |
| Forced constraints | IDs `0..7`, seed 23, height 8192, `C=4095` |
| Personalized keys | scalars `1..64`; every secret verified, pubkey derived, and pubkey parsed by libsecp256k1 |
| Personalized context | previous hash from seed 99, height 4096, `C=4095` |
| Known share candidate | par source with reader-delimiter whitespace removed, then canonical personalized validation |
| Payout heights | `0, 1, 30, 31, 730, 731, 1460, 24820, 24821` |
| Fees | `0`, `12345` daviwils |
| Share counts | `R=0..8` |
| Timeline | commitments in block `H=31`; reveal selection and payouts in block `H+1=32` |
| Aggregate comparison | producer length 32, cells 80, steps 300 |
| Strong / weak shares | 3 at margin 150 (`4` each) / 8 at margin 1 (`1` each) |

## Results

### Puzzle survey

420 global rows plus eight forced-constraint rows were generated and both known solutions validated.

| Metric | Result |
|---|---:|
| `k` min / median / max | 3 / 4 / 8 |
| width min / median / max | 6 / 8 / 24 |
| table bytes min / median / max | 63 / 119 / 319 |
| par min / median / max | 24 / 30 / 78 |
| hidden validation steps min / median / max | 30 / 61 / 297 |
| hidden validation allocations min / median / max | 22 / 56 / 393 |
| puzzles requiring retry | 49 / 420 |
| maximum retries | 3 |
| fallbacks | 0 |

Forced rows ensure every rotating constraint executes independently of sampled global mix.

### Personalized shares and key selection

All 64/64 scalars passed canonical secret-key validation. All 64/64 derived compressed pubkeys passed canonical parsing and were distinct. Their personalized tasks were distinct; every known candidate passed pure `coin-check-share-solution` preview and was strictly under par. Preview results supplied `(spec report contribution)` directly; no candidate entered the verified-share cache.

Margins were 8 / 24 / 42 milli-units at min / median / max. Every candidate had canonical contribution 1. First eight keys produced mean margin 23 and `Q=8`; selecting easiest eight among 64 raised mean margin to 36 but still produced `Q=8`.

This measures deterministic ex-post selection at width 64. It does not establish identity independence or realistic key-search cost.

### Rewards and emission

`payouts.csv` uses `coin-split-plan` for every row. Genesis rows with fees or shares remain arithmetic boundary probes and have `consensus_feasible=0`.

| Height | Subsidy | Cumulative emission |
|---:|---:|---:|
| 30 | 100000000 | 3000000000 |
| 31 | 10000000000 | 13000000000 |
| 730 | 10000000000 | 7003000000000 |
| 731 | 5000000000 | 7008000000000 |
| 24820 | 1 | 14302999991970 |
| 24821 | 0 | 14302999991970 |

At value `10000012345` and `R=8`, canonical plan pays producer `1818184066`, each share and carrier `909092031`, and shares total `7272736248`. If reveal producer controls all eight distinct share keys, that actor receives `9090920314`; carrier remains separate.

### Commitment and reveal timeline

Actors and keys remain separate:

- block-H carrier: `carrier-A`, `key-63`; decides which commitments block 31 carries
- block-H+1 producer: `producer-B`, `key-64`; decides which eligible reveals block 32 includes
- external shares: `keys-1..R`; self-controlled rows assign those distinct keys to `producer-B`

Representative `R=8` payout accounting at H+1:

| Strategy | Commits at H | Eligible at H+1 | Selected at H+1 | Producer | Shares | Carrier | Q |
|---|---:|---:|---:|---:|---:|---:|---:|
| carry and reveal external | 8 | 8 | 8 | 1818184066 | 7272736248 | 909092031 | 8 |
| carrier censors commitments | 0 | 0 | 0 | 10000012345 | 0 | 0 | 0 |
| producer censors reveals | 8 | 8 | 0 | 10000012345 | 0 | 0 | 0 |
| carry and reveal self-controlled | 8 | 8 | 8 | 1818184066 | 7272736248 | 909092031 | 8 |

These rows only account for block-H+1 payout routing and quality. They do not establish censorship profitability or benefit: fork survival, future rewards, network races, repeated play, market share, and strategic response are outside model.

### Aggregate ordering

At identical producer fields, three strong shares produce canonical `Q=12` and score word `131281456`; eight weak shares produce `Q=8` and score word `131281520`. `coin-score-better?` ranks strong cohort first. Independent raw-word comparison asserts same result.

## Caveats

- Distinct canonical pubkeys and preview-validated personalized work do not imply distinct owners, persons, or organizations.
- Known candidates only remove redundant reader-delimiter whitespace from generator-known par sources.
- No signature generation, commitment encoding, full block construction, networking, or wall-clock performance is simulated.
- Timeline rows are bounded two-block accounting, not equilibrium, censorship-resistance, or profitability analysis.
