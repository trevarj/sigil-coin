# SigilCoin Consensus Specification

---

## 1. Overview of the six mechanisms

1. **Program-by-example (PBE) puzzles.** The seed yields `k` input/output
   pairs. A solution is a source that evaluates to a 1-arity procedure
   reproducing every pair. Nothing about the examples is stored on chain; every
   node derives them.
2. **Rotating constraints.** The seed selects one of eight syntactic rules for
   the height, checked over the parsed AST and the raw source bytes.
3. **Co-op blocks.** Up to 8 signed shares ride in the coinbase alongside the
   producer's own solution. Each share solves a task personalized by its payout
   pubkey and receives a mandatory payout output.
4. **Program-golf lottery.** `bits` commits to producer length `L` and
   complexity `C`; the uint32 header nonce is searched automatically. A
   full-header `HASH256` roll must meet the `C`-dependent target, and each byte
   below par doubles the odds, up to eight bytes.
5. **Margin retargeting.** Every 16 blocks, the median *relative* improvement
   below par adjusts `C`. That moves grammar width, example count, constraint
   tier, and the lottery base target, but never an evaluator cap.
6. **Commit–reveal.** Commitments for puzzle `H` ride in block `H`; reveals and
   share payouts ride in block `H+1`.

---

## 2. Frozen constants

### 2.1 Puzzle language and generator

| Constant | Value |
|---|---:|
| `puzzle-max-source-bytes` | 512 |
| `puzzle-max-parse-depth` | 64 |
| `puzzle-max-fuel` | 200000 |
| `puzzle-max-allocations` | 400000 |
| `puzzle-max-string-bytes` | 65536 |
| `puzzle-max-eval-depth` | 128 |
| integer magnitude | `< 2^256` |
| `puzzle-generator-max-fuel` | 20000 per attempt |
| `puzzle-min-par-bytes` | 24 |
| `puzzle-max-generator-retries` | 64 |
| ordinary input/output literal bytes | 8 / 24 |
| personalized anchor input/output | `"@"` / 66 characters |
| `puzzle-max-k` | 8 |
| grammar productions | 24 |
| `puzzle-complexity-min` | 16 |
| `puzzle-complexity-max` | 4095 |
| `puzzle-complexity-genesis` | 128 |

### 2.2 Consensus

| Constant | Value |
|---|---:|
| `coin-max-block-bytes` | 16384 |
| `coin-max-solution-bytes` | 512 |
| `coin-max-graffiti-bytes` | 400 |
| `coin-max-shares` | 8 |
| `coin-max-commitments` | 16 |
| `coin-min-block-spacing` | 72000 |
| `coin-max-future-drift` | 7200 |
| `coin-median-time-span` | 11 |
| `coin-retarget-window` | 16 |
| `coin-target-margin` | 100 milli-units |
| lottery work factor | 32 |
| lottery maximum bonus | 8 bytes |
| lottery maximum integer | `2^256 - 1` |
| lottery target ceiling | `2^255 - 1` |
| header `version` | 5 |
| coinbase scriptSig bytes | 8..6588 |

The block-subsidy schedule, scheduled maximum, and coinbase maturity are
consensus rules. SigilCoin sets maturity to 1 block, so an output created in
block `H` may first be spent in `H+1`; Bitcoin's block-rules default remains 100.

Wallet coin selection is deliberately stricter on mainnet without changing
consensus: the bundled mainnet wallet waits for six confirmations before it
selects a coinbase input. Testnet and regtest select at the consensus boundary
so transaction and reorg drills remain fast. Nodes still accept externally
created transactions that satisfy the one-block consensus rule.

### 2.3 Scheduled subsidy and issued supply

`coin-block-reward`, `coin-cumulative-supply`, and `coin-max-supply` describe
the scheduled subsidy curve and its upper cap. They do not claim that every
scheduled unit was minted.

Actual issued supply is the sum of active-chain coinbase issuance after
ordinary transaction conservation. A solo block deliberately leaves part of
its scheduled subsidy unminted; a cooperative block mints its full scheduled
subsidy. Both node and explorer derive branch-aware issued supply from the
active UTXO set. The node labels `coin-cumulative-supply(height)` separately as
`scheduled-supply-cap`; the explorer overview pairs issued supply with the
scheduled lifetime `max-supply`. See §6.5 for exact payout and minting rules.

## 3. Puzzle derivation

### 3.1 Seed

```
seed(H) = SHA256d( "SigilCoin/puzzle/1"          (18 ASCII bytes)
                 || prev_hash                      (32 B, internal order)
                 || u64le(H)
                 || u32le(C(H)) )

seed(0) = SHA256d( "SigilCoin/genesis/puzzle/1" )
```

**Determinism.** Fixed-width fields make the preimage injective, so no two
`(prev_hash, H, C)` triples share a seed. `C(H)` is derived from the parent
chain (§9), not read from the candidate header, so a block cannot choose its
own puzzle by lying in `bits`; §9.4 requires the header to match the derived
value exactly.

### 3.2 Puzzle spec

```
puzzle-spec :=
  height          integer
  complexity      C, 16..4095
  constraint      constraint-id, 0..7
  k               example count, 3..8
  examples        list of k (input . output) pairs, in draw order
  hidden-source   tightened generated reference solution
  table-solution  tightened generated lookup-table solution
  par             min byte length of those two tightened sources
  retries         rejected attempts consumed
```

`puzzle-spec-par-solution` returns the shorter verified generated witness,
choosing `hidden-source` when the lengths tie. Its byte length is exactly
`par`.

`coin-puzzle-for` produces the ordinary generated specification;
`coin-share-puzzle` derives the personalized share specification from a
cooperative context and public key. Both pass through the same canonical
rendering, wrapping, tightening, and post-wrap verification boundary.

None of this is serialized into a block. Every node computes it from
`(prev_hash, H)` and caches it keyed on `(prev_hash, H)`, because many siblings
at one height are validated against the same puzzle.

### 3.3 Derived complexity knobs

```
k(C)     = clamp(3 + floor(C / 512), 3, 8)
w(C)     = min(24, 6 + floor(C / 205))      ; enabled prefix of the frozen
                                            ; 24-entry production list
tier(C)  = 0 if C <  256
           1 if C < 1024
           2 otherwise
```

At `C = 128` (genesis): `k = 3`, `w = 6`, tier 0. At `C = 4095`: `k = 8`,
`w = 24`, tier 2.

`C` never touches `puzzle-max-fuel`, `puzzle-max-allocations`,
`puzzle-max-string-bytes`, `puzzle-max-eval-depth`, or
`puzzle-max-source-bytes`. This is the survey's hard conclusion: validation cost
must be a constant of the protocol, not a function of difficulty.

### 3.4 Generation pipeline

For seed `S`, height `H`, complexity `C`, and retry index `r`:

1. Compute the attempt hash and initialize its dedicated deterministic RNG.
2. Draw a constraint-compatible hidden body, render it with the canonical
   single-space AST printer, add the personalized anchor body when requested,
   apply the deterministic constraint wrapper, and lexically tighten the
   complete source.
3. Enforce the hidden source size, parse, and constraint checks before drawing
   ordinary inputs. A personalized attempt draws `k-1` ordinary inputs and
   appends the reserved public-key anchor as the final input.
4. Execute the hidden function to obtain outputs under the shared generation
   budget.
5. Enforce exact example count and anchor layout, literal bounds and value
   shape; reject constant outputs and any puzzle solved by a one-arity builtin.
6. Render the table body from the final examples, apply the same wrapper, and
   lexically tighten its complete source.
7. Parse, constraint-check, and execute the table first, then re-check the
   hidden source, against every final example.
8. Set `par` to the shorter tightened source length, retain that source as the
   deterministic par witness (hidden on ties), and reject it below the minimum
   par floor.
9. Any rejected attempt advances the deterministic retry stream. After 64
   rejections, use the appropriate verified fallback; explicit-constraint and
   personalized fallbacks preserve the constraint, and personalized fallback
   preserves the anchor.

The wrapper tightener preserves the language rather than golfing text blindly.
Outside strings it consumes runs of space, tab, newline, and carriage return,
then emits one ASCII space only when the preceding emitted byte and next
non-whitespace byte are both bare-token characters. It emits no whitespace
next to `(`, `)`, `"`, or `'`, and trims leading and trailing whitespace.
Inside strings it copies bytes unchanged; a backslash copies itself and the
following byte, and only an unescaped `"` ends string mode. Escapes, quote
shorthand, symbols, numbers, and string contents are never rewritten. The
puzzle language has no comment syntax.

The canonical AST printer itself is unchanged. Tightening occurs only at the
generated-witness wrapping boundary, and both the hidden and table witnesses
are re-parsed and re-executed after tightening.

## 4. Solution validity

A producer candidate is a byte string `s`,
`1 <= |s| <= min(512, puzzle-spec-par)`. Thus `par` is both an upper bound on
the unknown true optimum and the consensus validity ceiling for producer work.
The verified generated par witness has length exactly `par`, so every puzzle
has at least one valid producer solution. Shares use the stricter personalized
rule `L < personalized_par` (§6.4).

### 4.1 Evaluation model

Exactly one machine per solution, budget `puzzle-max-fuel` (200000 steps),
`puzzle-max-allocations` cells, `puzzle-max-string-bytes` string bytes, shared
across the whole check:

1. `ast = puzzle-parse(s)`.
2. `proc = ev(m, ast, '(), 1)` — evaluate on machine `m`.
3. `proc` must satisfy `puzzle-procedure?` and accept exactly one argument:
   `arity-min <= 1` and (`arity-max = #f` or `arity-max >= 1`). A closure must
   have exactly one parameter.
4. For `i = 0 .. k-1` in generator draw order: apply `proc` to `input_i` on the
   *same* machine `m`, at depth 1. The result must satisfy `puzzle-value?`, must
   not be a procedure, and must be `puzzle-value=?` to `output_i`.
5. Report `steps = steps-used(m)` and `cells = machine-cells(m)` after step 4
   completes.

A single shared machine is the load-bearing choice: total validation cost for
one solution is bounded by one fuel budget *regardless of `k`*, so raising `k`
via `C` cannot raise node cost. The report retains deterministic `steps` and
`cells` for diagnostics; neither value affects block odds or fork choice.

Bare builtins are legal solutions (`car` is 3 bytes). Generation rejects any
puzzle reproduced by one.

### 4.2 Interpreter API

```
(puzzle-run-examples source pairs) -> puzzle-report
  puzzle-report-status     ok | error
  puzzle-report-value      the procedure, on ok
  puzzle-report-steps      integer
  puzzle-report-cells      integer
  puzzle-report-error-kind symbol, on error
  puzzle-report-index      failing example index, on solution-mismatch
```

`puzzle-result` includes a `cells` field so `puzzle-eval` also reports charged
allocations. Consensus calls `puzzle-run-examples` and nothing else.

### 4.3 Validation order and tags

`coin-check-solution(spec, s)` in order, first failure wins:

| # | Check | Tag |
|---|---|---|
| 1 | `s` is bytes or string | `solution-malformed` |
| 2 | `1 <= |s| <= 512` | `solution-oversize` / `solution-malformed` |
| 3 | `|s| <= spec.par` | `solution-over-par` |
| 4 | `constraint-ok?(spec.constraint, s)` — source-level part | `constraint-violated` |
| 5 | parses | `solution-parse-failed` (detail: interpreter kind) |
| 6 | `constraint-ok?(spec.constraint, ast)` — AST part | `constraint-violated` |
| 7 | evaluates to a value | `solution-eval-failed` (detail: interpreter kind) |
| 8 | result is a 1-arity procedure | `solution-not-a-procedure` |
| 9 | every example reproduced | `solution-mismatch` (detail: index) |
| — | anything raises | `internal-error` |

Constraint checking precedes evaluation because it is `O(|s|)` and evaluation
is not.

---

## 5. Header lottery and fork choice

### 5.1 The header budget

The serialized header remains Bitcoin's 80 bytes. SigilCoin gives three fields
consensus-specific meanings:

| Field | Bits | Use |
|---|---|---|
| `version` | 32 | pinned to 5 |
| `time` | 32 | real timestamp; MTP and drift rules unchanged |
| `bits` | 32 | producer length `L` and complexity `C` |
| `nonce` | 32 | uint32 lottery nonce |

`previous-block` and `merkle-root` retain their Bitcoin meanings. The nonce is
serialized as `u32le` and carries no score, rank, length, or share quality.

### 5.2 `bits` layout

```text
bits = 0x20600000 | ((L - 1) << 12) | C

bits & 0xffe00000 = 0x20600000
bits[20:12]       = L - 1       L in [1, 512]
bits[11:0]        = C           C in [16, 4095]
```

`L` is the producer source length in bytes. A validator derives `C` from the
parent chain and `par` from that puzzle, then requires the encoded `C` to match
and `L <= par`. The field supports header-first validation without claiming
anything about evaluator steps, allocations, shares, or payout quality.

`coin-bits-encode(complexity, length)` constructs this word.
`coin-bits-decode` returns `C` as a `coin-result`, and
`coin-bits-solution-length` returns `L` as a `coin-result`.

### 5.3 Exact lottery target

All arithmetic is over exact integers. Let:

```text
U      = 2^256
base   = floor(U / (32 * C)) - 1
bonus  = min(max(par - L, 0), 8)
mult   = 2^bonus
target = min(2^255 - 1, (base + 1) * mult - 1)
```

The inclusive target gives `target + 1` winning values among the `2^256`
possible hash rolls. The expected-rolls reporting value is
`ceil(2^256 / (target + 1))`. The ceiling limits acceptance probability to
one half even when low `C` and the full bonus would otherwise exceed it.

At `C = 128`, an at-par source has an expected 4096 nonce rolls. Each byte
saved doubles its odds until the eight-byte cap: at `par - 8`, the expected
count is 16. Further shortening remains valid and can matter to the 16-block
margin retarget, but it does not increase this block's lottery multiplier.

The consensus facade exposes the direct names
`coin-lottery-work-factor`, `coin-lottery-max-bonus`,
`coin-lottery-max-integer`, `coin-lottery-target-ceiling`,
`coin-lottery-bonus`, `coin-lottery-multiplier`,
`coin-lottery-target`, `coin-lottery-expected-rolls`, and
`coin-lottery-valid?`.

### 5.4 Full-header nonce search

For the canonical 80-byte header serialization, define:

```text
roll = integer(HASH256(header))
```

where `HASH256` is double SHA-256 and `block-header-work-value` interprets its
32-byte result as a little-endian unsigned 256-bit integer. Header acceptance
requires `roll <= target`.

A block builder validates the producer solution, finalizes the complete body
and merkle root once, encodes `L` and `C` in `bits`, then tries nonce values
from `0` through `0xffffffff`. The first qualifying nonce is used. If the
range is exhausted, construction fails; the public par witness supplies a
valid at-par program, not an automatic winning block.

Shorter programs therefore receive more lottery tickets. They do not
deterministically outrank siblings, and the numerically lower block hash does
not win a fork.

### 5.5 Header-to-body binding

Header checks can derive `L`, `C`, `par`, the target, and the full-header roll
without the body. Once the body arrives, validation runs the producer source
against the puzzle and requires its actual byte length to equal the header's
encoded `L`. A false length claim invalidates the block and its descendants.

Share quality and contribution remain authenticated by signatures, validation,
and coinbase payout shape. They are not header fields and never affect the
lottery target or fork choice.

### 5.6 Fork-choice order

Every accepted block contributes exactly one unit. Selection is:

1. a child already observed on the selected incumbent settles that height
   against later siblings;
2. otherwise, greater validated height wins;
3. at equal height, neither sibling replaces the other, so the first valid
   arrival remains incumbent.

There is no score, program-length, evaluator-cost, share-quality, nonce, or
block-hash sibling tie-break. Arrival order is local rather than a hidden
globally reproducible ordering; a valid child linking the selected incumbent
makes the chain taller and converges selection.

### 5.7 First-seen behavior and child settlement

The first valid same-height arrival becomes incumbent. A later sibling cannot
replace it merely by carrying a shorter program, a luckier nonce, more shares,
or a lower displayed hash. A child at `height + 1` must link to the selected
incumbent; once observed, it prevents later siblings at the parent's height
from displacing that settled branch.

Observers that receive different siblings first can temporarily retain
different incumbents. The next accepted child, not deterministic sibling
ranking, settles the height.

### 5.8 Persisted chain work

Persisted cumulative chain work is the count of accepted blocks: one unit per
block. It therefore represents height, not accumulated hash difficulty or
program-golf savings. Status may report the tip's encoded solution length
directly from `bits`; it must not infer share quality, evaluator cost, or a
historical rank from chain work.

## 6. Co-op shares

### 6.1 Coinbase payload

The scriptSig is exactly five minimally-encoded data pushes:

| # | Push | Size | Contents |
|---|---|---|---|
| 1 | HEIGHT | 0–5 B | BIP34 script number, unchanged |
| 2 | SOLUTION | 1–512 B | the producer's own solution for puzzle `H` |
| 3 | SHARES | 0–5145 B | reveals for puzzle `H-1` (§6.2) |
| 4 | COMMITS | 0–513 B | commitments for puzzle `H` (§7.1) |
| 5 | GRAFFITI | 0–400 B | opaque |

Decoder tags include `wrong-field-count`, `shares-oversize`,
`shares-malformed`, `commits-oversize`, and `commits-malformed`.

### 6.2 SHARES encoding

```
SHARES := u8 R                       ; 0 .. 8
          share[0] .. share[R-1]

share  := pubkey     33 B            ; compressed secp256k1
          signature  64 B            ; ECDSA, fixed-width r||s, low-s
          blind      32 B            ; the commitment's blind, opened here (§7.1)
          len        2 B  u16le      ; 1 .. 512
          solution   len B
```

Fixed-width fields throughout; the only variable field is length-prefixed. A
trailing byte or a short read is `shares-malformed`. Maximum
`1 + 8 * (33 + 64 + 32 + 2 + 512) = 5145` bytes (the 32 is the blind, published in the reveal — see §7.1).

Shares MUST appear in strictly ascending lexicographic order of `pubkey`. This
is canonical (one encoding per set), it forces distinct payout keys, and it
makes duplicate detection a linear scan. Out of order or repeated key is
`shares-unordered`.

Block validity requires canonical pubkey order, not miner preference order. The
reference miner first fully verifies every distinct eligible reveal, ranks them
by contribution descending and pubkey ascending, keeps at most eight, then
sorts the selected set by pubkey for serialization. Contributions remain
aligned with the selected canonical share order.

### 6.3 Personalized share puzzle and signature preimage

The producer still solves the one unchanged global puzzle for height `P`. Each
share instead solves a public task personalized by its compressed payout key:

```
global_seed = seed(P)
share_seed  = SHA256d( "SigilCoin/share-puzzle/1"
                     || global_seed
                     || pubkey )
```

Run bounded PBE generation with `(share_seed, P, C(P))`, forcing the constraint
id selected by the global puzzle. Height, `C`, `k`, grammar width and rotating
constraint are therefore identical to the producer puzzle. The global producer
puzzle is unchanged. A personalized puzzle has `k-1` seed-generated examples
followed by this mandatory anchor pair:

```
input  = "@"
output = encode_ap(pubkey)
```

`"@"` is reserved: no ordinary generated example may use it. `encode_ap`
encodes each nibble of the full 33-byte compressed pubkey as `a` through `p`
(`a=0`, ..., `p=15`), producing exactly 66 characters. The output is digit-free
and self-evaluating as a string literal without `quote`, so every constraint can
carry it. Encoding is injective and untruncated. Since every deterministic
function has one output for `"@"`, no source can solve personalized puzzles for
two distinct compressed pubkeys, regardless of alpha-renaming or wrappers.

The explicit-constraint generator uses the same 64-attempt bound and, on
exhaustion, a constraint-preserving fallback with seed-specific ordinary
examples plus the same anchor. Its real table solution is parsed,
constraint-checked and evaluated before publication.

Neither graffiti, any block hash after `global_seed`, nor the including block
enters `share_seed`. Distinct compressed pubkeys therefore receive distinct
seeded tasks, while changing unrelated block fields cannot move a task.

The signature preimage remains:

```
share_preimage = SHA256d( "SigilCoin/share/1"        (17 ASCII bytes)
                        || parent_prev_hash            (32 B)
                        || u64le(P)                    (the share's height)
                        || u32le(C(P))
                        || SHA256d(solution)           (32 B)
                        || pubkey                      (33 B) )
```

where `P = H - 1` is the puzzle the share solves, and `parent_prev_hash` is the
hash of block `P`'s parent — i.e. the same `prev_hash` that derived puzzle `P`.

What this binds, and why each field is there:

- `parent_prev_hash` and `P` pin the share to exactly one puzzle on exactly one
  branch. Replaying it at another height or on another branch fails.
- `C(P)` pins the retarget epoch, so a reorg that changes `C` invalidates
  stale shares rather than silently repricing them.
- `SHA256d(solution)` pins the program, so a producer cannot swap in a
  different solution under a valid signature.
- `pubkey` pins the payout, so a producer cannot redirect the reward. Since the
  payout script is derived from `pubkey` (§6.5), signing `pubkey` signs the
  payout.

What it deliberately does not bind: the including block. A share is valid in
*any* block at height `P+1` on the right branch, which is what makes it a share
rather than a block-specific artifact, and lets any producer include it.

Verification is standard ECDSA over `share_preimage` with `pubkey`, using
`sigil-bitcoin`'s secp256k1 binding. Non-canonical (high-s) signatures are
rejected: `share-bad-signature`.

### 6.4 Share and payout validation order

Validation is **breadth-first by cost**, not one share from start to finish.
For a block at height `H` with `R` shares, first failure in each stage wins:

| Stage | Checks | Representative tags |
|---|---|---|
| 1 — cheap share metadata | `H >= 1`; count and field sizes; valid compressed pubkeys; strict pubkey order; commitment membership in block `H-1`; raw solution dedup against producer and earlier shares | `shares-at-genesis`, `shares-oversize`, `share-bad-pubkey`, `shares-unordered`, `share-uncommitted`, `share-duplicate-solution` |
| 2 — cheap payout | solo exact output value, or cooperative output count, canonical share scripts, exact carrier script/value, and total `S+F` | `coinbase-output-shape`, `coinbase-output-value` |
| 3 — prepare every source | derive each pubkey-personalized spec once; enforce `L < personalized_par`; raw source/parse/AST constraint/one-argument procedure checks without evaluating the examples | `share-not-under-par`, inherited parse/constraint/arity tags, `internal-error` only on implementation failure |
| 4 — signatures | verify every signature against its share preimage | `share-bad-signature` |
| 5 — producer | evaluate the producer solution and require its byte length to equal encoded `L` | §4.3 producer tags, `solution-length-mismatch` |
| 6 — shares | evaluate each already-prepared share against its personalized examples exactly once; cache its verified report and contribution | inherited §4.3 tags prefixed `share-` |
| 7 — exact payout | price every output from verified contributions | `coinbase-output-value` |

The cheap payout check runs before source derivation, signature verification,
producer execution, or share PBE. For a cooperative block it checks `R+2`
outputs, canonical share and carrier scripts, carrier value `floor(S/20)`, and
total value `S+F`; it cannot yet trust contribution-weighted share values. A
cheap shape or total failure performs no PBE. A proportional misallocation
with otherwise valid shape and total is necessarily rejected only after every
accepted share has been fully verified once.

Each personalized spec is derived once and reused for the under-par check,
share evaluation, and verified contribution. Prepared-cache or source-shape
data never price outputs.

**Dedup.** Duplicates are rejected at the block level, not silently dropped,
because "reject" is total and "drop" needs a re-ordering rule. The producer
controls what he includes, so he simply includes one of any identical pair. The
canonical form for dedup remains the **raw solution bytes**, not a normalized
AST. AST normalization is a large new consensus surface for no gain. Raw-byte
dedup is only a canonical block rule; personalized tasks plus under-par quality
prevent **free source reuse**, not self-dealing. Superficially different
wrappers under several keys do not solve those keys' distinct example sets and
contribute nothing. One actor may still control all eight keys, but must solve eight
distinct personalized puzzles strictly under par; consensus proves work, not
ownership.

**Count.** `R <= 8`. Sizing in §6.6. A block with `R > 8` is `shares-oversize`.
`R` determines the required cooperative output count.

**Contribution.** For each fully verified share:

```text
margin_milli = floor(1000 * (personalized_par - L) / personalized_par)
contribution = 1 + min(3, floor(margin_milli / 50))
```

`margin_milli` is positive because at-par shares are rejected. Contributions
are exact integers from 1 through 4: 1 for margins 1..49, 2 for 50..99, 3 for
100..149, and 4 for 150 or more. The aligned contribution list prices the
share pool. Share count, contribution, and margin affect payout selection and
amounts, never the producer lottery or fork choice.

“Independent shares” means distinct pubkey-personalized tasks. It does not
claim or require independent owners: one owner may control several keys, but
each key must solve its own derived task and cannot reuse one wrapper eight
times.

### 6.5 Payout and issuance contract

Let `S` be the scheduled block subsidy, `F` the block fees, and `R` the
accepted share count. Both `S` and `F` are separate non-negative exact
integers. Output 0 always pays the producer to an otherwise unconstrained
script.

The public payout surface is:

```scheme
(coin-payout-plan subsidy fees shares contributions carrier-script)
(coin-check-payout-cheap tx subsidy fees shares carrier-script)
(coin-check-payout tx subsidy fees shares contributions carrier-script)
```

The cheap checker trusts no contribution list; the full planner and checker
require one entry per share.

With no shares (`R = 0`):

```text
producer = floor(4*S/5) + F
```

The coinbase has exactly one output and mints that amount. The reserve
`S - floor(4*S/5)` is unminted.

With shares (`1 <= R <= 8`), let each fully verified contribution `c_i` be an
exact integer in `1..4`, aligned one-for-one with canonical share order, and
let `C = sum(c_i)`:

```text
carrier      = floor(S/20)
share_pool   = floor(S/10)
share_i      = floor(share_pool * c_i / C)       independently for each i
producer     = S + F - carrier - sum(share_i)
```

The cooperative coinbase mints exactly `S+F`. All fees and every proportional
rounding residual land in output 0, so the nominal percentages are targets:
the producer receives about 85%, shares divide 10% by verified contribution,
and the parent carrier receives 5%.

Output order is consensus-critical:

1. producer,
2. one P2WPKH `OP_0 <HASH160(pubkey)>` output per share in canonical pubkey
   order,
3. the carrier script from output 0 of the parent coinbase.

Required share and carrier outputs remain present even when their value is
zero. For `S < 10`, share outputs are zero; for `S < 20`, the carrier is zero.
At `S=1`, a solo block mints zero while a cooperative block pays one to the
producer. At `S=0`, all fees go to the producer.

For the canonical example `S=5,000,000,000`, `F=0`, and contributions
`(1,2,4)`, the pool is `500,000,000`, carrier is `250,000,000`, and the share
outputs are `71,428,571`, `142,857,142`, and `285,714,285`. The residual is 2,
so the producer receives `4,250,000,002`.

Wrong output count or share/carrier script is `coinbase-output-shape`; wrong
value or total is `coinbase-output-value`; malformed trusted payout arguments
are `internal-error`.

### 6.6 Size budget

Worst-case coinbase scriptSig:

```
HEIGHT     5 data +   1 opcode  =    6
SOLUTION 512 data +   3         =  515   (OP_PUSHDATA2)
SHARES  5145 data +   3         = 5148
COMMITS  513 data +   3         =  516
GRAFFITI 400 data +   3         =  403
                                 ------
                                   6588  = coin-max-coinbase-script-bytes
```

`coin-min-coinbase-script-bytes` is derived from the encoder as today, and is 8:
height 0 (`OP_0`, 1), a 1-byte solution (2), `SHARES = #u8(0)` (2),
`COMMITS = #u8(0)` (2), empty graffiti (`OP_0`, 1). SHARES and COMMITS are never
zero-length pushes because the count byte is always present, which is what makes
the canonicality re-encode check unambiguous.

`R = 8` is chosen so the coinbase stays under 7 KB at a 16 KB cap. Raising `R`
to 16 needs a 32 KB cap; that is the documented upgrade path, not a current concern.

### 6.7 Determinism

Every share field is fixed-width or length-prefixed, ordering is canonical,
the signature preimage is a fixed-width concatenation, ECDSA verification is
deterministic, and every payout uses integer arithmetic with explicit
independent floors. Given `S`, `F`, canonical shares, their verified aligned
contributions, and the carrier script, two nodes derive identical outputs.

## 7. Commit–reveal

### 7.1 Commitment format

```
commitment = SHA256d( "SigilCoin/commit/1"     (18 ASCII bytes)
                    || share_preimage           (32 B, exactly as in §6.3)
                    || blind                    (32 B, miner-chosen) )

COMMITS := u8 K                                  ; 0 .. 16
           commitment[0] .. commitment[K-1]      ; 32 B each
```

Commitments MUST appear in strictly ascending lexicographic order and be
pairwise distinct: `commits-unordered`. Maximum `1 + 16 * 32 = 513` bytes.

The `blind` is 32 bytes of the miner's choosing. Without it, the commitment
would be a hash over public-plus-solution data and an attacker with a guessable
solution space could confirm a guess. With it, the commitment is hiding.

**The blind is published in the reveal.** A validator needs it to recompute
the commitment and prove membership in the parent's COMMITS. The blind rides
alongside the signature:

```
reveal := pubkey (33 B) || sig (64 B) || blind (32 B) || u16le len || solution
```

This costs nothing in hiding. The blind's only job is to keep the commitment
opaque during the window between commit and reveal; once the solution itself is
published, the blind protects nothing and its disclosure lets every validator
verify the commitment matched. Derived size caps move accordingly (5145 and
6588 bytes), and the binding constraint — the coinbase staying under about
7 KB inside a 16384-byte block — still holds at roughly 6976 bytes.

### 7.2 The pipeline

The puzzle for height `H` is only knowable once block `H-1` exists. Therefore:

| Block | Carries | For puzzle |
|---|---|---|
| `H` | COMMITS | `H` |
| `H` | SOLUTION (producer's own) | `H` |
| `H+1` | SHARES (reveals) + share payouts | `H` |

A share revealed in a block at height `H` solves puzzle `H-1`, and its
commitment must appear in COMMITS of block `H-1`. Both are on the same branch by
construction, since `H-1` is the validated parent.

At mainnet spacing (20 h) a miner has the whole interval to solve puzzle `H`,
publish a commitment for inclusion in block `H`, and reveal in `H+1`. At regtest
spacing (1 s) the window is not humanly usable; regtest tests construct
commitments and reveals directly.

### 7.3 Unrevealed commitments

Nothing. A commitment that is never revealed expires when block `H+1` is
accepted. There is no penalty, no refund, and no state kept beyond one block:
validating a block at height `H` requires only the COMMITS set of block `H-1`,
which is at most 16 hashes and is already in the node's block store.

Consequences: commitment spam is bounded to 513 B per block; a miner may commit
to a solution and never reveal at no cost; and a miner may commit to several
candidate solutions (up to the producer's 16 slots) and reveal the best one.
That last is a feature, not an attack: only one reveal per pubkey is possible
per block anyway (§6.2 ordering forces distinct pubkeys).

### 7.4 Why a producer includes commitments

The carrier output (§6.5) pays `floor(S/20)` to output 0 of block `H-1` when
block `H` contains at least one valid reveal. The parent producer earns this
fixed 5% target for making the commitment path available. Fabricated
commitments earn nothing because no one can reveal them, and carrying more
commitments does not multiply the carrier output.

### 7.5 What an attacker can and cannot steal

**Cannot:**

- *Steal an unrevealed share solution.* The commitment is `SHA256d` over the
  solution hash plus a 32-byte blind. Nothing about the program is recoverable.
- *Steal a revealed share solution.* A reveal for puzzle `P` is published in a
  block at height `P+1`. To use it, a thief would have to mine a sibling of
  block `P` — but height `P` is already extended by the very block that carried
  the reveal, so §5.7's `extended?` hysteresis refuses to displace it. **The
  reveal is safe precisely because publishing it requires a block that settles
  its height.** This is the whole reason the pipeline is `H` / `H+1` and not
  same-block.
- *Redirect a share's payout.* `pubkey` is in the signed preimage and the payout
  script is derived from it.
- *Include a share without its required contribution-weighted payout.* Output
  shape and exact values are consensus (§6.5).
- *Replay a share at another height, branch, or retarget epoch.*
  `parent_prev_hash`, `P` and `C(P)` are in the preimage.
- *Use a lower hash to win a sibling tie.* A qualifying header hash proves only
  lottery acceptance; block hash and nonce do not order same-height siblings
  (§5.6).

**Can:**

- *Copy the producer's own solution for puzzle `H`.* It is revealed in block `H`
  with no commitment, and no commitment is possible, because puzzle `H` is
  unknown before block `H-1` exists. See §10.5 for what protects the producer.
- *Censor commitments and reveals.* A producer chooses what his block carries.
  Censoring may forgo a future carrier output or current share participation,
  but share count and contribution do not improve or worsen fork position.
  There is no in-protocol defence beyond the bounded one-height opportunity;
  see Open Question 1.
- *Withhold a reveal.* Costs the withholder his own payout.
- *See, at reveal time, the full program of every sharer.* Programs are public
  once revealed, and reusing one at a later height is worthless because the
  puzzle changed.

### 7.6 Non-normative public-testnet relay

The reference public testnet operates
`https://pool.testnet.sigilcoin.lol` as an optional coordination relay. This
service, its HTTP routes, authorization signature, first-16 admission order,
source-address limits, receipt database, and status names are operational
policy only. They are not serialized into blocks, consulted by validators, or
part of fork choice. Nodes continue to enforce only the commitment and share
rules above.

`sigilcoin contribute --relay https://pool.testnet.sigilcoin.lol --testnet`
derives the personalized puzzle and signs locally without opening a node
database. The wallet key never leaves the contributor. The blind, source, and
consensus share signature stay local until the exact commitment appears in
canonical block `H`; only then is the reveal submitted for possible inclusion
in `H+1`. A producer opts in with `sigilcoin mine --relay ... --testnet`,
revalidates relay material, and retains the consensus-defined choice of at most
eight reveals.

Admission does not prove hidden work or resist Sybil keys. The relay or either
producer can delay, omit, or censor a commitment or reveal, so no receipt
guarantees inclusion or payment. They cannot redirect a valid included share's
payout because §6 binds its pubkey and required output; that direct coinbase
output follows SigilCoin's one-block maturity and is spendable in the following
block. The relay holds no balance or private key and is not a custodian. This
implementation exposes no mainnet pool.

---

## 8. Mechanically available producer candidate

**Claim.** For every height, every constraint `ci`, and every complexity `C`,
there is a consensus-valid solution of length exactly `par` that any producer
can construct mechanically from public data. The producer must still search
the uint32 header nonce for a qualifying full-header lottery roll.

### 8.1 Public data available to a miner

`prev_hash` (from the parent header), `H`, `C(H)` (derived, and committed in
`bits`), hence `seed(H)`, hence the whole puzzle spec including the `k`
input/output pairs and the constraint id. A miner runs the same generator every
validator runs.

### 8.2 The generated par witness

For pairs `(i_0, o_0) .. (i_{k-1}, o_{k-1})`, the mechanically generated
lookup is a nested `if`:

```text
(lambda(x)(if(equal? x'i_0)'o_0(if(equal? x'i_1)'o_1 ...'o_{k-1})))
```

This is schematic notation; the emitted literals replace the subscripts and
the lexical tightener removes every unnecessary separator. The last branch is
the default, so `k` pairs produce `k-1` tests. It reproduces every pair by
construction, since `equal?` on the puzzle value domain is
`puzzle-value=?`, which is what §4.1 step 4 compares with.

The generator also verifies its hidden source. `puzzle-spec-par-solution`
returns whichever verified witness is shorter, choosing the hidden source on a
tie. This deterministic result has length exactly `par`; the table establishes
the size bound even when the hidden source is the selected witness.

### 8.3 Size bound

After lexical tightening, each additional table test costs
`16 + |i| + |o|` bytes. The bare wrapper costs 11 bytes; the widest
`letrec` repair adds 29 bytes over it and the `fold` repair adds 23.

Exact generator bounds include:

| Case | Maximum bytes | Headroom below 512 |
|---|---:|---:|
| global, `k=10`, widest `letrec` repair | 496 | 16 |
| global, `k=10`, `fold` repair | 491 | 21 |
| global, frozen `k=8` | 400 | 112 |
| personalized, frozen `k=8` | 443 | 69 |

Although ten global examples now fit, the margin is too narrow for the shared
global/personalized protocol cap. `k` therefore remains frozen at a maximum of
8. Difficulty above that point grows through grammar width `w`, which does not
lengthen the table.

These are generated-source bounds, not permission for arbitrary source
rewriting. The generator constructs the actual hidden and table witnesses,
tightens the complete wrappers, then parses, constraint-checks, and executes
both against all examples before publishing the specification.
`puzzle-spec-par-solution` selects the shorter witness, hidden on ties, so its
length is exactly `par` and it meets the producer validity ceiling.

Deterministic simulator and local-drill fixtures may derive a semantic
under-par share from a personalized generated witness only when every ordinary
input is non-string. They replace the exact tight anchor predicate
`(equal? x"@")` with `(string? x)`, run the production share checker, and accept
the candidate only when its byte length is strictly below par. A specification
with a string ordinary input has no such candidate. Removing whitespace by
hand or fabricating a margin is not a valid fixture strategy.

### 8.4 Constraint repair transforms

Each transform is mechanical and its cost is bounded:

| `ci` | Rule | Repair | Added bytes |
|---|---|---|---|
| 0 | none | none | 0 |
| 1 | no digits | none needed: the generator draws the example domain from digit-free values (symbols, strings, booleans and lists of those) whenever `ci = 1` | 0 |
| 2 | no `quote` | print literals with a quote-free printer: integers and strings are self-evaluating, lists become `(list ...)`; the example domain excludes symbols when `ci = 2` | varies, bounded by the printer and re-checked |
| 3 | `letrec` required | `(lambda(x)(letrec((f(lambda(y)y)))(f BODY)))` | +29 |
| 4 | at most `D` distinct builtins | none needed: the table uses only `equal?`, and `if`/`lambda`/`quote` are special forms, not builtins. `1 <= D` always | 0 |
| 5 | exactly one `lambda` | none needed: the table has exactly one | 0 |
| 6 | no integer literal with \|n\| > 9 | none needed: the generator restricts the example domain to \|n\| <= 9 when `ci = 6` | 0 |
| 7 | `fold` required | `(lambda(x)(fold(lambda(a b)a)BODY'()))`; `fold` on the empty list returns its init | +23 |

For every accepted puzzle the generator has already evaluated concrete hidden
and table witnesses against all examples, under the constraint, budget, and
source-size rules. It deterministically exposes the shorter one (hidden on
ties) as the par witness. Every published puzzle therefore has a mechanically
available producer candidate of length exactly `par`. The table bound is 400
bytes globally or 443 bytes when personalized at the frozen `k=8`; `par` may
be shorter because it is the minimum of the two verified witnesses. A builder
using that candidate must still search the header nonce and meet §5's target.

Genesis uses the same par-witness selection, finalizes its body, and searches
the same uint32 nonce lottery. Changes to witness selection, `bits` layout, or
lottery rules change genesis; older chain state is incompatible and each
network requires fresh state for its matching genesis.

## 9. Retargeting

### 9.1 Signal

Per block `i`, the *relative* margin in milli-units:

```
m_i = clamp( floor( 1000 * (par_i - L_i) / par_i ), -1000, 1000 )
```

`par_i` is the shorter tightened generated-witness length for that height,
computed by every validator; `L_i` is the accepted producer solution length
from the header and consensus requires `L_i <= par_i`. The margin is therefore
in `0..999` and is relative so the same proportional improvement has the same
signal across puzzles with different par lengths.

Integer division floors toward negative infinity as a general arithmetic rule;
valid producer lengths make the numerator non-negative.

### 9.2 Window and median

The window is 16 blocks: heights `H-16 .. H-1`. Sort the 16 values ascending
and take index 8 (the upper median). No averaging is used, so the result is
always one observed value and needs no rounding rule.

### 9.3 Adjustment and clamping

```
f  = clamp(1000 + m_med - 100, 250, 4000)      ; the 4x clamp, both directions
C' = clamp( floor(C * f / 1000), 16, 4095 )
```

- `m_med > 100` (producers beating par by more than 10%) raises `C`, which
  lowers the next epoch's lottery base target.
- `m_med < 100` lowers `C`, which raises the base target.
- `f` is clamped to `[250, 4000]`, i.e. `0.25x .. 4x` per window, matching
  Bitcoin's clamp. For valid blocks `m_med` is non-negative, so the raw factor
  is in `[0.9, 1.899]`; the wider clamp remains part of the frozen arithmetic.
- Absolute bounds `[16, 4095]` fit the 12-bit field. `C = 16` is tier 0, `k = 3`,
  `w = 6`: still a real puzzle. `C = 4095` is tier 2, `k = 8`, `w = 24`.

Retarget fires at heights where `H mod 16 = 0` and `H >= 16`. Between retargets
`C(H) = C(H-1)`.

### 9.4 Early chain and encoding

`C(0) = puzzle-complexity-genesis = 128`. For `1 <= H < 16`, `C(H) = 128`. No
partial window is ever used: the first retarget is at `H = 16` with a full
window of heights 0..15, genesis included, which has a well-defined `par`.

`bits` MUST equal
`0x20600000 | ((L(H) - 1) << 12) | C(H)`. Its fixed prefix, decoded length,
complexity range, derived `C`, and `L <= par` are all validated as described in
§5.2.

Neither `C` nor `L` is freely chosen: `C` comes from the parent chain and `L`
must equal the validated body solution's byte length. Encoding both supports
constant-time header checks and determines the header's lottery target.

### 9.5 Determinism

`par_i` is a pure function of `(prev_hash_i, i)`, `L_i` is read from the header,
all arithmetic is exact integer with explicit floors and clamps, and the median
is a sort of exactly 16 values with a fixed index. A reorg recomputes `C` from
the new branch's own 16 blocks, which is why `C(P)` is bound into the share
preimage (§6.3).

---

## 10. Constraints

### 10.1 Catalogue

| `ci` | Name | Rule |
|---|---|---|
| 0 | `none` | no restriction |
| 1 | `no-digits` | no source byte in `0x30..0x39` |
| 2 | `no-quote` | no source byte `0x27`, and no AST form whose head is `quote` |
| 3 | `letrec-required` | at least one AST form whose head is `letrec` |
| 4 | `builtin-cap` | at most `D` distinct free identifiers that resolve to builtins; `D = 6` at tier 1, `D = 4` at tier 2 |
| 5 | `single-lambda` | exactly one AST form whose head is `lambda` |
| 6 | `small-literals` | every integer literal in the AST, including inside quoted data, satisfies \|n\| <= 9 |
| 7 | `fold-required` | at least one free identifier `fold` |

Each rule is a decidable predicate over the raw bytes, the parsed AST, or both,
computed in one pass, with no evaluation.

### 10.2 Tier catalogues and selection

```
tier 0 : (0)
tier 1 : (0 1 3 5)
tier 2 : (1 2 4 6 7)

g_c = puzzle-prng-open(seed, H, 0xFFFFFFFF)
ci  = tier-catalogue[tier(C)][ puzzle-prng-below!(g_c, |tier-catalogue[tier(C)]|) ]
```

The dedicated `retry = 0xFFFFFFFF` stream means generation retries never move
the constraint: the constraint is a function of `(seed, H, C)` alone and a miner
knows it before starting.

Tier 0 is unconstrained so the early chain, and any chain that has retargeted
down to trivial puzzles, is never made harder by a rule. Tier 1 holds rules that
cost a wrapper or a printing change. Tier 2 holds rules that materially restrict
what a program may say.

### 10.3 Checking algorithm

One shared AST walker, `constraint-walk(ast)`, carrying a set `B` of bound
names, collecting in a single pass:

```
walk(node, B, quoted?):
  if quoted?:                          ; inside (quote d)
      record integer literals for rule 6
      do not record identifiers, lambdas, letrecs
      recurse into list elements with quoted? = #t
      return
  if node is an integer: record it for rule 6; return
  if node is a boolean or string: return
  if node is a symbol:
      if node not in B and node in puzzle-builtin-names:
          add node to the free-builtin set
      return
  if node is a list:
      head = car(node)
      if head = 'quote  : mark quote-seen; walk(cadr, B, #t); return
      if head = 'lambda : mark lambda-seen (count it)
                          B' = B + params
                          walk(body, B', #f); return
      if head = 'let    : for each (v e): walk(e, B, #f)
                          B' = B + vars; walk(body, B', #f); return
      if head = 'letrec : mark letrec-seen
                          B' = B + vars
                          for each (v e): walk(e, B', #f)
                          walk(body, B', #f); return
      if head in (if and or): walk each subform with B; return
      otherwise: walk(head, B, #f); walk each argument with B; return
```

Then each rule is a read of the collected facts:

| `ci` | Predicate |
|---|---|
| 0 | `#t` |
| 1 | no source byte in `0x30..0x39` (lexical only; no walk needed) |
| 2 | no source byte `0x27` **and** `quote-seen = #f` |
| 3 | `letrec-seen = #t` |
| 4 | `|free-builtin-set| <= D` |
| 5 | `lambda-count = 1` |
| 6 | `max |integer literal| <= 9` |
| 7 | `fold` in `free-builtin-set` |

Rule 2 checks both the byte and the AST deliberately. The lexical check alone
would miss a hand-built `(quote x)`; the AST check alone would miss nothing, but
the byte check is `O(n)` and runs before parsing, which is the cheap rejection
path.

Costs: one `O(|s|)` byte scan plus one `O(|ast|)` walk, both bounded by 512
bytes of source. Negligible against evaluation.

### 10.4 Failure tag

All constraint failures share the tag `constraint-violated`, with the detail
string naming the constraint (`no-digits`, `no-quote`, `letrec-required`,
`builtin-cap`, `single-lambda`, `small-literals`, `fold-required`). The detail
is not consensus.

### 10.5 What protects the producer

The producer's own solution for puzzle `H` is necessarily revealed in block
`H` and cannot be committed in advance, because puzzle `H` does not exist until
block `H-1` does. A copier receives the same `L`, bonus, and target but must
independently find a qualifying nonce for a different full header. If that
sibling arrives later, it cannot displace the first-seen incumbent: neither a
shorter replacement program, a lower hash, nor more shares is a fork-choice
advantage. A valid child must link to the selected incumbent and settles its
height against still later siblings.

Before the child, observers that receive different valid siblings first may
temporarily retain different incumbents. This is an arrival-order race, not a
program-rank race; the next accepted child settles the height.


## 11. Validation cost

Per block, worst case, with the frozen caps:

| Work | Bound | Notes |
|---|---|---|
| header checks | O(1) | version, `bits`, MTP, drift, spacing, one full-header `HASH256`, target comparison |
| block size | one serialization | first body rule, bounds everything after |
| coinbase decode | O(6588) bytes | five pushes + one re-encode |
| global puzzle derivation | 65 x 20000 = 1.30 M steps | 64 rejected attempts plus one verified fallback; cached per `(prev_hash, H)` so siblings pay once |
| personalized puzzle derivation | 8 x 65 x 20000 = 10.40 M steps | one bounded explicit-constraint derivation per distinct share pubkey, including fallback; cacheable by `(global_seed, pubkey)` |
| producer solution | 200000 steps | one machine across all `k` applications |
| share solutions | 8 x 200000 = 1.6 M steps | same, per share |
| signature verification | 8 ECDSA | ~0.5 ms total |
| dedup | 9 x 9 byte compares of <= 512 B | ~40 KB of memcmp |
| commitment lookup | 8 lookups in a 16-element set | parent's COMMITS |
| transactions | Bitcoin's existing cost | unchanged |

```
solutions      :  1.8 M steps ~=  9.9 s
producer puzzle:  1.3 M steps ~=  7.2 s   (once per height, fallback included)
share puzzles  : 10.4 M steps ~= 57.2 s   (eight worst-case derivations)
                 ----------------------
worst case     : 13.5 M steps ~= 74.3 s before caching; personalized specs are
                 cacheable by `(global_seed, pubkey)` across sibling blocks
```

The machine boundary is executable: a 20000-step evaluation succeeds, the same
program on 19999 fuel stops at 19999, and an attempt containing a formerly
unbounded single evaluator call returns `budget-exhausted` at exactly 20000.
A deterministic audit of 1280 full derivations (20 seeds, two heights, four
complexities and all eight constraints) measured 2117 steps for both the
heaviest attempt and heaviest complete non-fallback derivation. The hard bounds,
not the sample, govern consensus.

Against 72000 s mainnet spacing the theoretical 74.3 s is about 0.1% duty.

**Pre-validation gate (required).** A node MUST order body validation
cheapest-first. The canonical order is:

1. header acceptance: version, time, `bits` prefix, derived `C`, `L <= par`,
   and full-header lottery roll,
2. block size and merkle commitment,
3. canonical coinbase payload and actual producer-source length equal to the
   header's encoded `L`,
4. cheap share count, shape, order, deduplication, and parent-commitment checks,
5. transaction-fee derivation and cheap payout shape/value/total checks,
6. derive each personalized spec once; enforce source length, strict under-par,
   parse, AST constraint, and arity for every share,
7. verify every share signature,
8. evaluate the producer,
9. evaluate every prepared share exactly once and derive verified contributions,
10. require exact contribution-weighted payout values,
11. invoke Bitcoin's connector with the SigilCoin rules record.

A block that fails cheap payout shape or total reaches no PBE. Exact
contribution-weighted misallocation cannot be decided until stage 10.

A node SHOULD additionally bound the number of siblings at one height it will
validate bodies for concurrently. That is policy, not consensus.

**Never call `sigil-bitcoin`'s `connect-block` or `connect-block/structural`
directly on a SigilCoin block.** They enforce Bitcoin's 100-byte coinbase
scriptSig cap and Bitcoin's block subsidy; a real SigilCoin coinbase scriptSig
is up to 6588 bytes. `coin-connect-block` passes SigilCoin's own rules record
into Bitcoin's connector, which is the only supported path.

---

## 12. Complete failure tag index

| Tag | Source | Meaning |
|---|---|---|
| `not-bytevector`, `malformed-script`, `wrong-field-count`, `not-a-push`, `bad-height`, `non-canonical` | coinbase codec | malformed or non-canonical payload |
| `solution-empty`, `solution-oversize`, `graffiti-oversize` | coinbase codec | field exceeds frozen bounds |
| `shares-oversize`, `shares-malformed`, `shares-unordered`, `shares-at-genesis` | SHARES codec | invalid reveal set |
| `commits-oversize`, `commits-malformed`, `commits-unordered` | COMMITS codec | invalid commitment set |
| `solution-malformed`, `solution-over-par`, `solution-parse-failed`, `solution-eval-failed` | solution check | malformed source, source above the puzzle's par ceiling, or interpreter failure |
| `solution-not-a-procedure`, `solution-mismatch` | solution check | wrong result shape or examples not reproduced |
| `constraint-violated` | constraint check | source or AST violates selected rule |
| `share-bad-pubkey`, `share-bad-signature`, `share-uncommitted`, `share-duplicate-solution`, `share-not-under-par` | share check | personalized task or binding failed |
| `share-solution-*` | share check | solution rejection, prefixed for a share |
| `coinbase-output-shape`, `coinbase-output-value` | payout validation | output count, scripts, or values differ |
| `malformed-header`, `bits-prefix`, `complexity-range`, `complexity-mismatch` | header/`bits` check | malformed fields, invalid prefix or complexity, or encoded `C` differs from the parent-derived value |
| `solution-length-mismatch` | body connection | encoded `L` differs from the validated solution byte length |
| `height-mismatch`, `missing-coinbase`, `block-oversize`, `malformed-block` | block check | malformed block envelope or body |
| `internal-error` | any check | implementation failure while validating |

---

## 13. Open questions

**1. Commitment censorship has no in-protocol defence.**
A producer can simply omit COMMITS. The carrier output (§7.4) pays him to
include them, but a miner who expects to win most heights is better off
excluding everyone. *Recommendation:* ship as specified and measure. The
cheapest real fix, if censorship shows up, may be to feed commitment count into
the existing `C` retarget, making persistent omission raise both puzzle
complexity and lottery difficulty. That changes consensus and is intentionally
not built until behavior is observed.

**2. Contribution bands are launch constants.**
The 5%, 10%, and 15% margin thresholds assign payout contributions 1 through
4. They affect reveal selection and payout weights, not producer lottery odds
or fork choice. No live co-op margin distribution exists yet. *Recommendation:*
ship the four frozen bands and measure. Distinct shares mean distinct
personalized tasks, not distinct owners; ownership identity is neither
observable nor required by
consensus. Revisit bands only through an explicit hard fork if observed
margins cluster pathologically around a boundary.

**3. `k` and grammar width both scale with `C`, and they interact.**
Lexical tightening reduces an added table branch from 18 fixed bytes to 16.
A ten-example global witness now fits in at most 496 bytes, but leaves only 16
bytes of headroom under the shared 512-byte source cap. `k` remains frozen at a
maximum of 8: the exact global bound is 400 bytes and the personalized bound is
443 bytes, leaving 112 and 69 bytes respectively. Difficulty above that point
climbs through grammar width, which does not lengthen the table. Widening the
grammar raises the hidden function's complexity independently.

*Recommendation:* retain `k <= 8` and the generator's explicit source-size and
post-wrap execution checks. If deterministic retry rates climb at high `C`,
decouple `k` from `C` and drive it from a separate, slower signal.

**4. The selected payout percentages have no public incentive data.**
Solo blocks mint 80% of scheduled subsidy plus fees. Cooperative blocks mint
the full scheduled subsidy plus fees, target 85% for the producer, divide 10%
by contributions 1 through 4, and pay 5% to the parent carrier; floors and
residual routing are consensus. Coverage proves output shape, conservation,
and payout binding, not that participants will commit, reveal, or carry
others' work. Changing the formula after launch is a hard fork.

**5. Permissionless keys are not identities and can be ground.**
One actor may control all eight share keys. The full-key anchor proves each
accepted source solves its chosen pubkey's distinct puzzle, but pubkeys are free
to generate, so a miner can sample keys and work only on unusually easy
personalized puzzles. Contribution is capped at 4 per share for selection and
payout, not fork-choice benefit; no rule proves distinct owners or makes key
selection scarce.

**6. Public-network behaviour is untested.**
Only local loopback nodes have run. Reorg frequency, peer churn, sustained
SQLite contention, hostile validation load and long-running resource use remain
unknown until the required two-host soak completes.

---

## 14. Network and implementation status (non-consensus)

The sole public rule surface is `(sigil coin consensus)`; node code consumes it
through `(sigil coin node)`.

- Mainnet uses version 5, magic `8f d1 c0 a5`, port 19444, and HRP `sgl`.
  Its quote is `Sigil - Practical Symbolic Power`; timestamp `1785542400` and
  every derived genesis constant remain launch placeholders until the operator
  chooses the final timestamp and regenerates them together.
- The reset public testnet keeps magic `d3 7a 91 c5`, port 19446, HRP `tsgl`,
  one-hour minimum spacing, and five-minute future drift. Its quote is
  `SigilCoin public testnet reset - 2026-09-02` and timestamp `1788307200`.
  Previous public-testnet databases and history are incompatible; operators
  must archive or move the old directory themselves and initialize an empty
  one. Software does not delete it.
- Regtest uses magic `a5 c0 d1 8f`, port 19445, HRP `sgl`, and one-second
  spacing.

The all-network generator is the source of current display/internal genesis
hashes. Par-witness selection, the `bits` layout, and searched lottery nonce
all affect the serialized genesis header. Pre-cutover chain state is
incompatible and each network requires fresh matching state. A node validates
genesis, not network magic alone.

