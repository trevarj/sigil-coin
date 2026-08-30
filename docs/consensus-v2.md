# SigilCoin Consensus Specification v2

Status: design, frozen for implementation. This document is normative. Where it
disagrees with the v1 code, the code changes.

v2 is a chain split, not a soft fork. `puzzle-language-version` becomes 2,
`puzzle-generator-version` becomes 2, `coin-header-version` becomes 5, and
genesis is regenerated. There is no migration path for a v1 chain and none is
wanted.

---

## 0. Why v2

Survey of 480 v1 puzzles:

| Observation | Value | Consequence |
|---|---|---|
| `par` is the quoted literal | 78.3% of puzzles | mining is constant transcription |
| minimal solution unique | 96.7% | competitors submit identical bytes |
| `(and 1 Q)`, `(or #f Q)`, ... | unbounded family | identical length/steps/allocations, grindable |
| peak fuel used | 0.03% of 1e6 | execution metrics inert |
| peak allocations used | 0.08% of 1e5 | execution metrics inert |
| structural golfer beat par | 30%, median 6 B, max 43 B | real headroom exists |
| par range | 25–149 B | absolute thresholds are non-uniform |

Two conclusions drive the whole design. First, the target must be a *function*,
not a constant, or the game degenerates. Second, difficulty must come from
widening what a solution has to express, never from tightening the evaluator's
resource caps, because every node re-evaluates every solution.

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
4. **Composite score.** `(length, memory, steps)` lexicographically, then
   aggregate verified share quality, packed into a single 32-bit header word.
5. **Margin retargeting.** A 12-bit complexity parameter `C` lives in `bits`,
   retargeted every 16 blocks on the median *relative* margin between par and
   achieved length. `C` moves grammar width, example count, and constraint
   tier. It never moves an evaluator cap.
6. **Commit–reveal.** Commitments for puzzle `H` ride in block `H`; reveals and
   share payouts ride in block `H+1`.

---

## 2. Frozen constants

### 2.1 Puzzle language (`sigil-coin-puzzle`)

| Constant | v1 | v2 | Justification |
|---|---|---|---|
| `puzzle-language-version` | 1 | 2 | split marker |
| `puzzle-max-source-bytes` | 256 | **512** | the liveness escape (§8) is a `k`-branch lookup table plus a constraint repair wrapper; at `k=8` it reaches 415 B globally and 458 B with a full-key share anchor |
| `puzzle-max-fuel` | 1000000 | **200000** | observed peak 300 steps (0.03% of 1e6); 200000 is 660x observed peak and cuts the hostile per-solution cost from ~5.5 s to ~1.1 s, which matters because v2 validates up to 9 solutions per block |
| `puzzle-max-allocations` | 100000 | **400000** | charging became honest (environment frames, boxes, closures and argument lists are counted, and `append`/`map`/`filter`/`fold` charge what they really cons), so the old number no longer meant the same thing; 400000 restores comparable headroom for real programs |
| `puzzle-max-string-bytes` | 65536 | 65536 | unchanged |
| `puzzle-max-eval-depth` | 128 | 128 | unchanged |
| `puzzle-max-parse-depth` | 64 | 64 | unchanged |
| `puzzle-max-integer` | 2^256 | 2^256 | unchanged |
| `puzzle-generator-max-fuel` | — | **20000** | per generation *attempt*, shared across every evaluation in that attempt; bounds puzzle derivation at 64 x 20000 = 1.28 M steps (§11) |

Builtins (41), special forms (7), value domain, and error kinds are unchanged.

### 2.2 Consensus (`sigil-coin-consensus`)

| Constant | v1 | v2 | Justification |
|---|---|---|---|
| `coin-max-solution-bytes` | 256 | **512** | tracks `puzzle-max-source-bytes` |
| `coin-max-graffiti-bytes` | 400 | 400 | unchanged; grinding it is inert in v2 (§5.4) |
| `coin-max-block-bytes` | 8192 | **16384** | worst-case coinbase is 6588 B of scriptSig plus ~390 B of outputs (§6.6); 16384 leaves ~9.4 KB for transactions, more than 8192 ever gave |
| `coin-max-shares` | — | **8** | see §6.6 sizing |
| `coin-max-commitments` | — | **16** | 16 x 32 B = 512 B; 2x the reveal cap, so competing candidates fit |
| `coin-min-block-spacing` | 72000 | 72000 | unchanged |
| `coin-max-future-drift` | 7200 | 7200 | unchanged |
| `coin-median-time-span` | 11 | 11 | unchanged |
| emission constants | — | unchanged | v2 changes how the subsidy is *split*, never how much is emitted; `coin-max-supply` = 14302999991970 daviwils is untouched |

### 2.3 Generator (`sigil-coin-puzzle/generator`)

| Constant | Value | Justification |
|---|---|---|
| `puzzle-generator-version` | 2 | split marker |
| `puzzle-min-par-bytes` | 24 | unchanged from v1; still the non-degeneracy floor, now on the hidden function's source |
| `puzzle-max-generator-retries` | 64 | unchanged |
| `puzzle-max-input-literal-bytes` | 8 | table-solution sizing (§8.3) |
| `puzzle-max-output-literal-bytes` | 24 | table-solution sizing (§8.3) |
| `puzzle-complexity-min` | 16 | floor of `C` |
| `puzzle-complexity-max` | 4095 | 12 bits |
| `puzzle-complexity-genesis` | 128 | tier 0, `k=3`, narrow grammar: a gentle launch |
| `puzzle-retarget-window` | 16 | ~13 days mainnet, 16 s regtest; with a 30% beat-par rate the 16-sample median is stable, and 2016 would be 4.6 years at 20 h spacing |
| `puzzle-target-margin` | 100 | milli-units: the retarget aims for the median achieved solution 10.0% under par. v1's observed beat-par median was 6 B on a 25–149 B par range, i.e. roughly 10% relative |

---

## 3. Puzzle derivation

### 3.1 Seed

```
seed(H) = SHA256d( "SigilCoin/puzzle/v2"          (19 ASCII bytes)
                 || prev_hash                      (32 B, internal order)
                 || u64le(H)
                 || u32le(C(H)) )

seed(0) = SHA256d( "SigilCoin/genesis/puzzle/v2" )
```

`prev_hash` is the internal 32-byte double-SHA256 header hash, never the
reversed display id. Domain separation from v1 is by the tag. `C(H)` is folded
in so that a retarget changes the puzzle, which prevents a miner from
pre-computing solutions across a retarget boundary.

**Determinism.** Fixed-width fields make the preimage injective, so no two
`(prev_hash, H, C)` triples share a seed. `C(H)` is derived from the parent
chain (§9), not read from the candidate header, so a block cannot choose its
own puzzle by lying in `bits`; §9.4 requires the header to match the derived
value exactly.

### 3.2 Puzzle spec

```
puzzle-spec-v2 :=
  height          integer
  complexity      C, 16..4095
  constraint      constraint-id, 0..7
  k               example count, 3..8
  examples        list of k (input . output) pairs, in draw order
  hidden-source   canonical source of the generator's own function
  par             min(|hidden-source|, |table-solution|), >= 24
  table-solution  the liveness escape, canonical source
  retries         rejected attempts consumed
```

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

The constraint is drawn from a *separate* stream so retries never move it:

```
g_c   = puzzle-prng-open(seed, H, 0xFFFFFFFF)
ci    = tier-catalogue[tier(C)][ puzzle-prng-below!(g_c, |tier-catalogue[tier(C)]|) ]
```

One attempt, keyed `(seed, H, retry)`, under a shared 20000-step budget:

1. `g = puzzle-prng-open(seed, H, retry)`.
2. Synthesise a function body from the constraint-restricted sub-grammar at
   width `w(C)`; form `F = (lambda (x) BODY)`.
3. `source_F = puzzle-print-expression(F)`. Reject if `|source_F| > 512` or
   `constraint-ok?(ci, source_F) = #f`.
4. Draw `k(C)` pairwise-distinct inputs from the constraint's input domain
   (§7.3). Reject if any input literal exceeds
   `puzzle-max-input-literal-bytes`.
5. Apply `F` to each input. Reject if any application fails, exceeds the
   attempt budget, yields a procedure, yields a non-`puzzle-value?`, or yields
   a literal longer than `puzzle-max-output-literal-bytes`.
6. Reject if all `k` outputs are `puzzle-value=?` equal (the constant function
   would win trivially).
7. Reject if any 1-arity builtin, applied to all `k` inputs, reproduces every
   pair. This is 41 x k trivial applications and it kills the case where the
   hidden function is extensionally `car`.
8. Build the table solution `T` (§8.2), apply the constraint repair transform
   (§8.4), and reject unless `|T| <= 512`, `T` parses, `constraint-ok?(ci, T)`,
   and `T` reproduces all `k` pairs within the consensus caps.
9. `par = min(|source_F|, |T|)`. Reject if `par < 24`.
10. Accept.

After 64 rejections, `puzzle-fallback(H, C)` returns a frozen puzzle whose
`constraint` is forced to 0 and whose examples are frozen constants. It
re-checks every acceptance condition and raises if any fails, because a failure
there is a bug in this module rather than a bad block.

**Determinism.** SplitMix64 over exact integers with explicit 64-bit masking,
FNV-1a absorption of `(seed, H, retry)` with LEB128 self-delimiting integers,
`let*`-sequenced draws, and the frozen v2 interpreter. No clock, no filesystem,
no host randomness.

---

## 4. Solution validity

A candidate solution is a byte string `s`, `1 <= |s| <= 512`.

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
via `C` cannot raise node cost. It also makes `steps` and `cells` well-defined
single numbers for the score.

Bare builtins are legal solutions (`car` is 3 bytes). §3.4 step 7 guarantees no
published puzzle is solved by one.

### 4.2 New interpreter API

```
(puzzle-run-examples source pairs) -> puzzle-report
  puzzle-report-status     ok | error
  puzzle-report-value      the procedure, on ok
  puzzle-report-steps      integer
  puzzle-report-cells      integer
  puzzle-report-error-kind symbol, on error
  puzzle-report-index      failing example index, on solution-mismatch
```

`puzzle-result` gains a `cells` field so `puzzle-eval` also reports charged
allocations. Consensus calls `puzzle-run-examples` and nothing else.

### 4.3 Validation order and tags

`coin-check-solution(spec, s)` in order, first failure wins:

| # | Check | Tag |
|---|---|---|
| 1 | `s` is bytes or string | `solution-malformed` |
| 2 | `1 <= |s| <= 512` | `solution-oversize` / `solution-malformed` |
| 3 | `constraint-ok?(spec.constraint, s)` — source-level part | `constraint-violated` |
| 4 | parses | `solution-parse-failed` (detail: interpreter kind) |
| 5 | `constraint-ok?(spec.constraint, ast)` — AST part | `constraint-violated` |
| 6 | evaluates to a value | `solution-eval-failed` (detail: interpreter kind) |
| 7 | result is a 1-arity procedure | `solution-not-a-procedure` |
| 8 | every example reproduced | `solution-mismatch` (detail: index) |
| — | anything raises | `internal-error` |

Constraint checking precedes evaluation because it is `O(|s|)` and evaluation
is not.

---

## 5. Score, header budget, and ranking

### 5.1 The header budget

80 bytes, of which SigilCoin controls three fields.

| Field | Bits | v2 use |
|---|---|---|
| `version` | 32 | pinned to 5 |
| `time` | 32 | real timestamp, MTP and drift rules unchanged |
| `bits` | 32 | complexity commitment (§9.4) |
| `nonce` | 32 | score word `W` |

`previous-block` and `merkle-root` are Bitcoin's. There is no spare space, and
none is asked for.

**No proof of work runs anywhere.** `(sigil coin node rules)` never hashes a
header against a target and `next-required-bits` is never called, so repurposing
`bits` cannot accidentally impose real hashing. `consensus-params
pow-limit-bits` stays `#x207fffff` for the seam's sake.

### 5.2 `bits` layout

```
bits = 0x207F0000 | C          C in [16, 4095]
       ^^^^                    frozen; keeps the value <= 0x207fffff so any
                               Bitcoin-side reader still sees a max-target-ish
                               compact number
bits[15:12] MUST be 0
bits[11:0]  = C
```

### 5.3 `nonce` layout: the score word `W`

Lower `W` is better. Plain unsigned 32-bit comparison *is* the composite order.

```
bit  31              22 21     15 14      8 7    4 3    0
    +------------------+---------+---------+------+------+
    |      L - 1       |   MB    |   SB    |15-Q  | 0000 |
    +------------------+---------+---------+------+------+
       10 bits           7 bits    7 bits   4 bits 4 bits
```

| Field | Width | Domain | Meaning |
|---|---|---|---|
| `L-1` | 10 | 0..511 | producer solution length in bytes, 1..512 |
| `MB` | 7 | 0..127 | bucket of `cells` charged by the producer's solution |
| `SB` | 7 | 0..127 | bucket of `steps` spent by the producer's solution |
| `15-Q` | 4 | 0..15 | `Q` = aggregate verified share quality, 0..15 |
| reserved | 4 | 0 | MUST be zero |

```
W = (L - 1) << 22 | MB << 15 | SB << 8 | (15 - Q) << 4
```

Reserving the low nibble and deriving every other field from the body means the
header nonce carries **zero free entropy**. There is no nonce to grind.

Field order is the ranking: producer length dominates memory dominates steps,
then aggregate verified share quality. Quality is last because co-op work may
break producer ties but never outrank a genuinely better producer program.
`R` remains separately capped at 8 and controls only the reward split; it is not
encoded in `W`.

### 5.4 Bucketing

`cells` (0..100000) and `steps` (0..200000) do not fit 7 bits. They are
bucketed at six buckets per octave, ~12.2% resolution, using exact integer
arithmetic only:

```
T = (1000, 1122, 1260, 1414, 1587, 1782)      ; floor(1000 * 2^(i/6))

bucket7(x):
  if x = 0: return 0
  kk = bit-length(x) - 1                       ; floor(log2 x)
  j  = |{ t in T : t * 2^kk <= 1000 * x }| - 1 ; j in 0..5
  return min(127, 1 + 6*kk + j)
```

Range check: `bucket7(100000) = 100`, `bucket7(200000) = 106`. Both fit in 7
bits with headroom. `bucket7` is monotone non-decreasing.

**The bucketed value is the consensus value.** Fork choice compares header words
and never body integers, so two solutions in one bucket are exactly tied and
fall through to aggregate share quality. There is no second, finer order to keep consistent
with the header. Precision loss is deliberate.

At the survey's observed magnitudes (~300 steps, ~80 cells) the buckets are
still fine: `bucket7(300) = 50` and `bucket7(340) = 51`. The metrics were inert in
v1 because nothing read them, not because they lacked resolution.

Worked example: `bucket7(1) = 1`, `bucket7(2) = 7`, `bucket7(300) = 50`,
`bucket7(340) = 51`.

### 5.5 Header-to-body commitment

`W` is a *claim*. Body validation recomputes `W` from the validated body and
requires byte equality with the header. A mismatch is `score-mismatch`, the
block is invalid, and the node marks the header and its descendants invalid
permanently — the same discipline v1 used for the length commitment. This is
what keeps fork choice decidable from headers alone without letting a liar
outrank an honest chain.

### 5.6 The order

Define the block key `key(b) = (height(b), W(b))`.

```
b1 < b2   iff   height(b1) > height(b2)
                or (height(b1) = height(b2) and W(b1) < W(b2))
```

("<" means "is the better tip".)

**Strict weak ordering.** Let `f(b) = (-height(b), W(b))` in Z x Z with the
lexicographic order, which is a strict total order on Z x Z.

- *Irreflexive*: `f(b) < f(b)` is false because lexicographic `<` on a totally
  ordered product is irreflexive.
- *Asymmetric* (hence antisymmetric): `f(b1) < f(b2)` and `f(b2) < f(b1)`
  cannot both hold, again by lexicographic order on a total order.
- *Transitive*: inherited from the lexicographic order.
- *Transitivity of incomparability*: `b1` and `b2` are incomparable iff
  `f(b1) = f(b2)`. Equality is transitive, so incomparability is an equivalence
  relation. This is exactly the definition of a strict weak ordering, and the
  equivalence classes are "same height, same score word".

`W` is a 32-bit unsigned integer with all fields packed most-significant-first
in ranking order, so unsigned `<` on `W` equals lexicographic `<` on
`(L, MB, SB, 15-Q)`. The aggregate co-op quality composes with the producer's own
solution by occupying strictly lower-order bits than every producer field: it
decides exactly the comparisons the producer's own solution leaves tied, and
nothing else.

**The block-hash tie-break of v1 is deleted from consensus.** This is the
producer's protection (§10.5). `coin-hash-compare` survives only for stable
display ordering in the explorer and CLI, where it is not consensus.

### 5.7 Tip selection

At equal `key`, blocks are incomparable and the incumbent tip is kept. This is
first-seen, exactly as Bitcoin resolves equal-work siblings. It is order-
dependent across nodes and converges the moment a child arrives, because height
dominates the key. The `extended?` hysteresis of v1 is retained unchanged: a
height that a taller header has already outgrown is settled and no sibling
displaces it.

`coin-better-chain?(candidate, incumbent)` in order:

1. live beats settled (`extended?` as in v1)
2. greater height wins
3. lower `W` wins
4. otherwise `#f` (incumbent keeps the tip)

### 5.8 `chain-work` packing

The `sigil-bitcoin-node` seam persists one integer.

```
saving(b)   = 2^32 - W(b)                     ; 1 .. 2^32, 0 reserved
              0 for a header with an illegal W
coin-rank-base = 2^32 + 1
work        = accumulated * coin-rank-base + saving
accumulated = sum of saving over the chain, with an illegal header
              contributing 1
```

`saving <= 2^32 < coin-rank-base`, so the digits never collide and both are
recoverable. `accumulated` is strictly increasing along any chain, so no chain
ranks below its own ancestor. As in v1, height outranks the packed number in
`better-chain?`, and the packed number only ever decides between siblings.

---

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

Decoding is strict and total, and closes with the same one-shot canonicality
check v1 uses: re-encode what was read and require byte equality with the input.
That single check rejects non-minimal pushes, non-minimal height encodings, and
trailing bytes.

New decoder tags: `wrong-field-count` (now expects 5), `shares-oversize`,
`shares-malformed`, `commits-oversize`, `commits-malformed`.

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

### 6.3 Personalized share puzzle and signature preimage

The producer still solves the one unchanged global puzzle for height `P`. Each
share instead solves a public task personalized by its compressed payout key:

```
global_seed = seed(P)
share_seed  = SHA256d( "SigilCoin/share-puzzle/v2"
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
share_preimage = SHA256d( "SigilCoin/share/v2"        (18 ASCII bytes)
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

### 6.4 Share validation order

For a block at height `H` with `R` shares, per share `i`, first failure wins:

| # | Check | Tag |
|---|---|---|
| 1 | `H >= 1` when `R > 0` (genesis carries no shares) | `shares-at-genesis` |
| 2 | `pubkey` is a valid compressed point | `share-bad-pubkey` |
| 3 | `pubkey[i] > pubkey[i-1]` lexicographically | `shares-unordered` |
| 4 | `SHA256d(commitment_preimage)` for this share is in block `H-1`'s COMMITS | `share-uncommitted` |
| 5 | signature verifies against `share_preimage` | `share-bad-signature` |
| 6 | `solution` differs byte-wise from the producer's SOLUTION and from every earlier share's solution | `share-duplicate-solution` |
| 7 | derive the pubkey-personalized puzzle using the global puzzle's constraint | `internal-error` only on implementation failure |
| 8 | `L < personalized_par`; equality or excess is invalid | `share-not-under-par` |
| 9 | `coin-check-solution(personalized_spec, solution)` passes | inherits §4.3 tags, prefixed `share-` |

Checks are ordered cheapest-first: a 32-byte set membership before a signature
verification before a puzzle evaluation.

**Dedup.** Duplicates are rejected at the block level, not silently dropped,
because "reject" is total and "drop" needs a re-ordering rule. The producer
controls what he includes, so he simply includes one of any identical pair. The
canonical form for dedup remains the **raw solution bytes**, not a normalized
AST. AST normalization is a large new consensus surface for no gain. Raw-byte
dedup is only a canonical block rule; personalized tasks plus under-par quality
prevent **free source reuse**, not self-dealing. Same-score wrappers under
several keys do not solve those keys' distinct example sets and contribute
nothing. One actor may still control all eight keys, but must solve eight
distinct personalized puzzles strictly under par; consensus proves work, not
ownership.

**Count.** `R <= 8`. Sizing in §6.6. A block with `R > 8` is `shares-oversize`.
`R` remains the number of accepted reveals and is used by reward splitting only.

**Aggregate quality.** For each accepted share:

```
margin_milli = floor(1000 * (personalized_par - L) / personalized_par)
contribution = 1 + min(3, floor(margin_milli / 50))
Q            = min(15, sum(contribution for every accepted share))
```

`margin_milli` is positive because at-par shares are rejected. Contributions
are 1 for margins 1..49, 2 for 50..99, 3 for 100..149, and 4 for 150 or more.
Ranking therefore measures aggregate verified work, not raw reveal count. Three
shares at least 15% below their personalized pars contribute `Q=12` and outrank
eight shares below 5%, which contribute `Q=8`, when producer fields tie.

“Independent shares” means distinct pubkey-personalized tasks. It does not claim
or require independent owners: one owner may control several keys, but each key
must solve its own derived task and cannot reuse one wrapper eight times.

### 6.5 Reward split

Let `V = subsidy(H) + total_fees(H)`. Let `R` be the accepted share count.

```
carrier = 1 if R >= 1 else 0
Wtot    = 2 + R + carrier
u       = floor(V / Wtot)

output 0        : producer, value  V - R*u - carrier*u
output 1..R     : share i, value u, script from share i's pubkey
output R+1      : carrier,  value u          (only when R >= 1)
```

Exactly `1 + R + carrier` outputs. Any other output count is
`coinbase-output-shape`. Values must match exactly; the outputs sum to `V`
exactly, so Bitcoin's value-conservation check passes unchanged.

- **Weights.** Producer 2, each share 1, carrier 1. At `R = 8` the producer
  keeps 2/11 = 18.2% plus the remainder, each sharer gets 9.1%. Including
  shares costs the producer real reward; winning ties is what pays for it, and
  ties are the normal case.
- **Rounding.** Floor division; the remainder `V mod Wtot`, at most 10
  daviwils, goes to the producer. Dust never goes to fees and never burns, so
  emission is exactly as scheduled.
- **Carrier.** Output `R+1` pays the *producer of block `H-1`*, whose script is
  `scriptPubKey` of output 0 of block `H-1`'s coinbase. That block is the
  parent, so every validator has it. This is the in-protocol reason a producer
  carries other miners' commitments (§7.4): he is paid, one block later, for
  every commitment he carried that was revealed.
- **Share script.** P2WPKH `OP_0 <HASH160(pubkey)>`, derived from the signed
  pubkey. Fixed form, so there is no script-choice surface.

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

Plus 10 outputs at ~34 B and ~50 B of transaction overhead: ~6720 B of
coinbase. Against `coin-max-block-bytes = 16384` that leaves ~9.6 KB for
transactions, which is more than the whole v1 block.

`coin-min-coinbase-script-bytes` is derived from the encoder as today, and is 8:
height 0 (`OP_0`, 1), a 1-byte solution (2), `SHARES = #u8(0)` (2),
`COMMITS = #u8(0)` (2), empty graffiti (`OP_0`, 1). SHARES and COMMITS are never
zero-length pushes because the count byte is always present, which is what makes
the canonicality re-encode check unambiguous.

`R = 8` is chosen so the coinbase stays under 7 KB at a 16 KB cap. Raising `R`
to 16 needs a 32 KB cap; that is the documented upgrade path, not a v2 concern.

### 6.7 Determinism

Every share field is fixed-width or length-prefixed, the ordering is canonical,
the preimage is a fixed-width concatenation, ECDSA verification is
deterministic, the split is integer arithmetic with a single floor, and the
output shape is fully determined by `R`. Two nodes cannot disagree.

---

## 7. Commit–reveal

### 7.1 Commitment format

```
commitment = SHA256d( "SigilCoin/commit/v2"     (19 ASCII bytes)
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

**The blind is published in the reveal, not withheld.** An earlier draft of
this section said it was never published, which made §6.4's commitment check
uncheckable: no validator can recompute `commitment` without it, so the check
would have to be dropped, and dropping it makes the carrier payment fakeable
— a producer could claim carrier weight for commitments nobody ever made. The
blind therefore rides in the reveal alongside the signature:

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

The carrier output (§6.5). The producer of block `H-1` is paid weight 1 out of
`2 + R + 1` in block `H`, once, for having carried commitments that were
revealed. He cannot fake it: he is paid only if a *later* producer includes a
valid reveal whose commitment was in *his* block. Fabricated commitments earn
nothing because nobody can reveal them.

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
- *Include a share without paying it.* The output shape and values are
  consensus (§6.5).
- *Replay a share at another height, branch, or retarget epoch.*
  `parent_prev_hash`, `P` and `C(P)` are in the preimage.
- *Grind the block hash to win a tie.* The hash tie-break is deleted (§5.6).
- *Grind the nonce.* Every bit of `W` is derived from the body, and the low
  nibble is reserved zero (§5.3).

**Can:**

- *Copy the producer's own solution for puzzle `H`.* It is revealed in block `H`
  with no commitment, and no commitment is possible, because puzzle `H` is
  unknown before block `H-1` exists. See §10.5 for what protects the producer.
- *Censor commitments and reveals.* A producer chooses what his block carries.
  He forfeits the carrier output and aggregate-quality tie-break by doing so, and
  he only controls one height. There is no in-protocol defence beyond that; see
  Open Question 1.
- *Withhold a reveal.* Costs the withholder his own payout.
- *See, at reveal time, the full program of every sharer.* Programs are public
  once revealed, and reusing one at a later height is worthless because the
  puzzle changed.

---

## 8. Liveness

**Claim.** For every height, every constraint `ci`, and every complexity `C`,
there exists a solution that any miner can construct mechanically from public
data.

The v1 escape — quote the target literal — is gone, because the answer is a
function and there is no literal to quote. It is replaced by the **table
solution**.

### 8.1 Public data available to a miner

`prev_hash` (from the parent header), `H`, `C(H)` (derived, and committed in
`bits`), hence `seed(H)`, hence the whole puzzle spec including the `k`
input/output pairs and the constraint id. A miner runs the same generator every
validator runs.

### 8.2 The table solution

For pairs `(i_0, o_0) .. (i_{k-1}, o_{k-1})`:

```
(lambda(x)(if(equal? x 'i_0)'o_0 (if(equal? x 'i_1)'o_1 ... 'o_{k-1})))
```

The last branch is the default, so the innermost `if` is omitted: `k` pairs
produce `k-1` tests. It reproduces every pair by construction, since `equal?`
on the puzzle value domain is `puzzle-value=?`, which is what §4.1 step 4
compares with.

### 8.3 Size bound

Per test branch: 18 + `|i|` + `|o|`. The bare wrapper `(lambda(x)` + `)` is 11
bytes, and a constraint repair adds to it: `ci 3` (`letrec` required) is the
worst at +29, `ci 7` (`fold` required) +24.

**The arithmetic in the first draft of this section was wrong, and the
implementation caught it.** At `k = 10`, `|i| <= 8`, `|o| <= 24`, the worst
reachable table is not 486 bytes:

```
ci 3, k = 10 : 40 + 9 * (18 + 8 + 24) + 25 = 515   > 512, INFEASIBLE
ci 7, k = 10 : 35 + 9 * 50 + 25            = 510   fits, 2 bytes spare
ci 3, k =  8, global : 40 + 7 * 50 + 25    = 415   fits, 97 bytes spare
ci 3, k =  8, share  : 40 + 7 * 50 + 68    = 458   fits, 54 bytes spare
```

`k = 10` is therefore unreachable: `k` is frozen at a maximum of 8. Global
puzzles retain the 415-byte bound. Personalized puzzles replace the final
ordinary 25-byte quoted output with the exact 68-byte self-evaluating anchor
string (66 encoded characters plus delimiters), giving an exact worst case of
458 bytes and 54 bytes of headroom. The anchor is last, so it is the default and
adds no test branch or input literal to the table.

**`k` is therefore frozen at a maximum of 8.** Difficulty above that point
grows through grammar width `w`, which does not lengthen the table. These bounds
are exact rather than sampled: ordinary pairs enforce `|i| <= 8` and
`|o| <= 24`; personalized puzzles enforce one final `("@" . encode_ap(pubkey))`
pair with an exactly 66-character output. The expression above is therefore a
true maximum over all accepted inputs.

The generator does not trust any of this arithmetic: §3.4 step 8 constructs the
actual table solution, prints it, parses it, constraint-checks it, and runs it
against all `k` pairs before a puzzle can be published. That check is what
found the 515-byte case; the numbers here are documentation, not the guarantee.

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
| 7 | `fold` required | `(lambda(x)(fold(lambda(a b)a)BODY '()))` — `fold` on the empty list returns its init | +24 |

**Therefore the claim holds:** for every accepted puzzle the generator has
already evaluated a concrete, constraint-satisfying, in-budget, in-size table
solution against all `k` pairs. Every published puzzle is provably solvable by
anyone who can read the chain. The chain cannot stall.

Overfitting is self-punishing: the table solution is by construction the longest
thing anybody would submit (415 bytes globally or 458 bytes personalized at the
frozen `k = 8`), so any structural program beats it on the primary ranking key.

---

## 9. Retargeting

### 9.1 Signal

Per block `i`, the *relative* margin in milli-units:

```
m_i = clamp( floor( 1000 * (par_i - L_i) / par_i ), -1000, 1000 )
```

`par_i` is the generator's own known-shortest length for that height, computed
by every validator; `L_i` is the accepted solution length from the header. The
margin is relative because par ranges 25–149 bytes, so an absolute "beat par by
N" threshold is non-uniform by a factor of 6 across the observed range.

Integer division floors toward negative infinity, specified explicitly so
negative margins are unambiguous.

### 9.2 Window and median

`W = 16` blocks: heights `H-16 .. H-1`. Sort the 16 values ascending and take
index 8 (the upper median). No averaging, so the result is always one of the
observed values and no rounding rule is needed.

### 9.3 Adjustment and clamping

```
f  = clamp(1000 + m_med - 100, 250, 4000)      ; the 4x clamp, both directions
C' = clamp( floor(C * f / 1000), 16, 4095 )
```

- `m_med > 100` (miners beating par by more than 10%) raises `C`.
- `m_med < 100` lowers it.
- `f` is clamped to `[250, 4000]`, i.e. `0.25x .. 4x` per window, matching
  Bitcoin's clamp. Since `m_med - 100` is in `[-1100, 900]`, the raw factor is
  in `[-0.1, 1.9]`; the lower clamp is what stops a negative or collapsing
  factor, and it is load-bearing, not decorative.
- Absolute bounds `[16, 4095]` fit the 12-bit field. `C = 16` is tier 0, `k = 3`,
  `w = 6`: still a real puzzle. `C = 4095` is tier 2, `k = 8`, `w = 24`.

Retarget fires at heights where `H mod 16 = 0` and `H >= 16`. Between retargets
`C(H) = C(H-1)`.

### 9.4 Early chain and encoding

`C(0) = puzzle-complexity-genesis = 128`. For `1 <= H < 16`, `C(H) = 128`. No
partial window is ever used: the first retarget is at `H = 16` with a full
window of heights 0..15, genesis included, which has a well-defined `par`.

`bits` MUST equal `0x207F0000 | C(H)` where `C(H)` is the value the validator
derives from the parent chain. Tags: `bits-reserved-nonzero` (bits[15:12] != 0),
`bits-prefix` (bits[31:16] != 0x207F), `complexity-mismatch` (C disagrees with
the derived value), `complexity-range` (C outside [16, 4095]).

`C` is therefore never miner-chosen. Encoding it in the header at all is for
headers-first sync: a node ranking headers needs `C` to derive the puzzle, and
re-deriving it from the parent chain during a header flood is the same work
either way — the field makes it checkable in constant time.

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

Rule 4's "free" is essential: a solution that binds `(let ((map ...)) ...)` uses
`map` as a local, not a builtin, and the walker's `B` set gets that right
because builtin names are shadowable in v1/v2 semantics while special-form names
are not.

Costs: one `O(|s|)` byte scan plus one `O(|ast|)` walk, both bounded by 512
bytes of source. Negligible against evaluation.

### 10.4 Failure tag

All constraint failures share the tag `constraint-violated`, with the detail
string naming the constraint (`no-digits`, `no-quote`, `letrec-required`,
`builtin-cap`, `single-lambda`, `small-literals`, `fold-required`). The detail
is not consensus.

### 10.5 What protects the producer

The producer's own solution for puzzle `H` is necessarily revealed in block `H`
and cannot be committed in advance, because puzzle `H` does not exist until
block `H-1` does. Three things together make copying it unprofitable:

1. **No hash tie-break.** A thief who copies the solution byte-for-byte produces
   an identical `(L, MB, SB)`. In v1 he would then grind the 400-byte graffiti
   until his block hash was lower and take the tip with certainty. In v2 an
   equal `W` never displaces an incumbent (§5.6, §5.7), so the grind buys
   nothing.
2. **Aggregate verified work.** To get a strictly lower `W` at equal
   `(L, MB, SB)` the thief must carry greater `Q`: under-par solutions to
   pubkey-personalized tasks, from commitments in block `H-1`, with every
   accepted reveal paid by the unchanged reward split. Extra keys or
   same-score wrappers alone contribute nothing.
3. **`extended?` hysteresis.** Once any taller header exists, height `H` is
   settled and no sibling displaces it at all.

What remains: a thief who copies the solution *and* matches aggregate quality
produces an incomparable sibling. Nodes that saw the producer's block first keep
it; nodes syncing from scratch may adopt either; the next block settles it. That
is Bitcoin's equal-work race, unchanged, and it is the honest limit of what a
same-block reveal can be protected against.

---

## 11. Validation cost

Per block, worst case, with the frozen v2 caps:

| Work | Bound | Notes |
|---|---|---|
| header checks | O(1) | version, bits, `W` field ranges, MTP, drift, spacing |
| block size | one serialization | first body rule, bounds everything after |
| coinbase decode | O(6588) bytes | five pushes + one re-encode |
| global puzzle derivation | 64 x 20000 = 1.28 M steps | cached per `(prev_hash, H)` so siblings pay once |
| personalized puzzle derivation | 8 x 64 x 20000 = 10.24 M steps | one bounded explicit-constraint derivation per distinct share pubkey; cacheable by `(global_seed, pubkey)` |
| producer solution | 200000 steps | one machine across all `k` applications |
| share solutions | 8 x 200000 = 1.6 M steps | same, per share |
| signature verification | 8 ECDSA | ~0.5 ms total |
| dedup | 9 x 9 byte compares of <= 512 B | ~40 KB of memcmp |
| commitment lookup | 8 lookups in a 16-element set | parent's COMMITS |
| transactions | Bitcoin's existing cost | unchanged |

Puzzle-language steps calibrate at ~5.5 microseconds per step under hostile
programs (5.5 s per 1e6 steps, measured in v1). So:

```
solutions      : 1.8 M steps   ~=  9.9 s
producer puzzle: 1.28 M steps  ~=  7.0 s   (once per height)
share puzzles  : 10.24 M steps ~= 56.3 s   (eight worst-case derivations)
                ------------------------
worst case     : ~73 s before caching; personalized specs are cacheable by
                 `(global_seed, pubkey)` across sibling blocks
```

Against 72000 s mainnet spacing that is 0.024% duty. Typical cost is
microseconds: the survey's observed peak was 300 steps.

**Pre-validation gate (required).** A node MUST order body validation
cheapest-first and MUST NOT evaluate a solution before the block has passed
size, payload decode, and header-commitment checks. Recommended order:

1. header accept (`O(1)`)
2. block size
3. coinbase payload decode and canonicality
4. `W` field ranges and reserved-nibble check
5. output shape and split arithmetic (integer only)
6. constraint check on all `R+1` solution sources (byte scan)
7. parse all `R+1` solutions
8. commitment membership for all shares
9. signature verification for all shares
10. derive personalized specs and reject every `L >= personalized_par`
11. producer solution evaluation
12. personalized share solution evaluations and aggregate `Q`
13. recompute `W`, require equality with the header
14. Bitcoin's connector

A node SHOULD additionally bound the number of siblings at one height it will
validate bodies for concurrently. That is policy, not consensus.

**Never call `sigil-bitcoin`'s `connect-block` or `connect-block/structural`
directly on a SigilCoin block.** They enforce Bitcoin's 100-byte coinbase
scriptSig cap and Bitcoin's block subsidy; a real SigilCoin coinbase scriptSig
is up to 6588 bytes. `coin-connect-block` passes SigilCoin's own rules record
into Bitcoin's connector, which is the only supported path.

---

## 12. Migration

### 12.1 `sigil-coin-puzzle`

- `puzzle.sgl`: bump `puzzle-language-version` to 2; `puzzle-max-source-bytes`
  512; `puzzle-max-fuel` 200000; add `cells` to `puzzle-result`; add
  `puzzle-run-examples` and the `puzzle-report` record; add a quote-free value
  printer for constraint 2. The evaluator core, builtins, special forms, error
  kinds, and value model are untouched.
- `generator.sgl`: substantially rewritten. `puzzle-spec` gains `complexity`,
  `constraint`, `k`, `examples`, `hidden-source`, `table-solution` and loses
  `target` and `solution`. New: the constraint catalogue and walker, the
  constraint-restricted example domains, the 1-arity builtin degeneracy probe,
  the table-solution builder and repair transforms, and
  `puzzle-generator-max-fuel`. `puzzle-prng` is unchanged and stays frozen.
- New module `puzzle/constraints.sgl` holding the catalogue, the walker, and
  `constraint-ok?`, imported by both the generator and consensus. Keeping it out
  of `puzzle.sgl` keeps the interpreter free of anything that is not the
  language.

**Tests that break:** `test-generator.sgl` entirely — every assertion about
`puzzle-spec-target`, `puzzle-spec-solution`, the target byte band
(`puzzle-min-target-bytes` / `puzzle-max-target-bytes` are deleted), the
`iota`-run par rewrite, and the fallback source. `test-puzzle.sgl` breaks only
where it asserts `puzzle-max-source-bytes = 256` or `puzzle-max-fuel = 1000000`,
plus any test asserting `puzzle-result` field arity.

### 12.2 `sigil-coin-consensus`

- `seed.sgl`: new tag, `C` folded into the preimage, new genesis tag. Signature
  becomes `coin-puzzle-seed(prev-hash, height, complexity)`.
- `coinbase.sgl`: five pushes instead of three; SHARES and COMMITS codecs; new
  tags. The canonicality re-encode check is kept verbatim — it is the single
  best thing in the v1 codec.
- `solution.sgl`: PBE checking against `k` pairs on one machine, 1-arity
  procedure requirement, constraint checks, and the new tags.
- `fork-choice.sgl`: `coin-solution-compare` and `coin-better-solution?` are
  replaced by `coin-score-compare` over 32-bit words. `coin-hash-compare` stays
  but leaves consensus. `coin-replaces-tip?` requires a strictly lower `W`.
- New `score.sgl`: `bucket7`, `coin-score-encode`, `coin-score-decode`,
  `coin-score-from-block`; its low field commits `(15-Q)`, not raw `R`.
- New `shares.sgl`: personalized share seed and PBE derivation, under-par
  validation, contribution and `Q`, share preimage, verification, ordering,
  dedup, and unchanged split arithmetic.
- New `retarget.sgl`: margin, median, clamp, `bits` codec.
- `rules.sgl`: `coin-max-block-bytes` 16384. Timestamp rules unchanged.
- `emission.sgl`: **unchanged**. The split is an output-shape rule; total
  emission and `coin-max-supply` are untouched.

**Tests that break:** `test-coinbase.sgl` entirely (three-push format).
`test-consensus.sgl` where it asserts solution semantics or fork-choice
tie-breaking by hash. `test-emission.sgl` should pass unchanged, and if it does
not, emission was touched by mistake.

### 12.3 `sigil-coin-node`

- `rules.sgl`: `coin-header-version` 5; `coin-header-bits` becomes the
  `0x207F0000 | C` codec plus a derived-value check instead of an equality
  check; `coin-header-solution-length` becomes `coin-header-score`;
  `coin-rank-base` becomes `2^32 + 1` and `coin-solution-saving` becomes
  `2^32 - W`; `coin-better-chain?` drops the hash tie-break.
  `coin-accept-header?` gains the `C` derivation, which means it now needs the
  parent chain's last 16 headers — `previous-headers` already supplies a
  window, and the window requirement grows from 11 (MTP) to 16.
- `body.sgl`: coinbase script bounds become 8..6588; new validation order
  (§11); the header commitment check compares `W`, not a length.
- `chain.sgl`: `max-block-bytes`, `max-solution-bytes`, `max-coinbase-script-bytes`
  and the advertised `puzzle-generator-version` all move; add
  `complexity-genesis` and `retarget-window` to the advertised parameters.
- `genesis.sgl`: builds a v2 genesis (version 5, `bits = 0x207F0080`, `nonce` =
  the genesis block's own `W`, five-push coinbase with empty SHARES and
  COMMITS).
- `miner.sgl`: mines against examples rather than a target; must construct the
  table solution as its floor and then search for something shorter; must
  collect reveals and build the split outputs.

**Tests that break:** `test-node.sgl` and `test-chain.sgl` wherever they build
headers with version 4, `bits = 0x207fffff`, or a nonce holding a solution
length; `test-network.sgl` block construction, which builds coinbases directly.
The network test's own findings still hold and are unaffected by v2:
`sigil-bitcoin` has no getdata/block responder, and
`db-best-chain-header-rows-after` resolves locators by height across branches.

### 12.4 `sigil-coin-cli` and `sigil-coin-explorer`

- CLI `mine`: the whole solver changes; add `commit` and `reveal` subcommands
  and a share wallet key.
- CLI `operate`/status: renders `W` fields instead of a solution length.
- Explorer: block pages show the examples, the constraint, `C`, the score
  fields, and the share table with payouts. `store.sgl` gains share and
  commitment columns.

### 12.5 Genesis regeneration

Required, because the seed tag, the header version, `bits`, and the coinbase
format all change.

1. Derive `seed(0) = SHA256d("SigilCoin/genesis/puzzle/v2")` and generate the
   height-0 puzzle at `C = 128`.
2. Solve it (the table solution is acceptable for genesis).
3. Build the coinbase: height `OP_0`, the solution, empty SHARES (`R = 0`),
   empty COMMITS (`K = 0`), the chosen graffiti.
4. Compute `W` from the body and set `nonce = W`; set `bits = 0x207F0080`,
   `version = 5`.
5. Regenerate `deploy/genesis-constants.sgl` with the new header, hash, and
   merkle root.
6. Update `LAUNCH.md`.

Genesis carries no shares, so `Q = 0` and its `W` quality field is `15-Q = 15`
in bits [7:4], with zero in [3:0].

---

## 13. Complete failure tag index

| Tag | Source | Meaning |
|---|---|---|
| `not-bytevector`, `malformed-script`, `wrong-field-count`, `not-a-push`, `bad-height`, `non-canonical` | coinbase codec | as v1, `wrong-field-count` now expects 5 |
| `solution-empty`, `solution-oversize`, `graffiti-oversize` | coinbase codec | as v1, new solution bound 512 |
| `shares-oversize`, `shares-malformed`, `shares-unordered`, `shares-at-genesis` | SHARES codec | |
| `commits-oversize`, `commits-malformed`, `commits-unordered` | COMMITS codec | |
| `solution-malformed`, `solution-parse-failed`, `solution-eval-failed` | solution check | |
| `solution-not-a-procedure` | solution check | result is not a 1-arity procedure |
| `solution-mismatch` | solution check | detail is the failing example index |
| `constraint-violated` | constraint check | detail names the rule |
| `share-bad-pubkey`, `share-bad-signature`, `share-uncommitted`, `share-duplicate-solution`, `share-not-under-par` | share check | personalized task or share binding failed |
| `share-solution-*` | share check | the solution tags above, prefixed |
| `coinbase-output-shape`, `coinbase-output-value` | split check | |
| `score-mismatch` | header commitment | recomputed `W` differs from the header |
| `score-reserved-nonzero` | header field check | low nibble non-zero; every `15-Q` nibble is legal |
| `bits-prefix`, `bits-reserved-nonzero`, `complexity-mismatch`, `complexity-range` | `bits` check | |
| `height-mismatch`, `missing-coinbase`, `block-oversize`, `malformed-block` | as v1 | |
| `internal-error` | anywhere | a check raised; always a bug |

---

## 14. Open questions

**1. Commitment censorship has no in-protocol defence.**
A producer can simply omit COMMITS. The carrier output (§7.4) pays him to
include them, but a miner who expects to win most heights is better off
excluding everyone. *Recommendation:* ship v2 as specified and measure. The
cheapest real fix, if censorship shows up, is to make the commitment count a
soft input to retargeting — a chain whose blocks carry no commitments is
treated as easier and gets a higher `C` — which costs the censor difficulty
rather than requiring a new mechanism. Do not build that until the behaviour is
observed.

**2. The producer/share weight split (2 vs 1) is a guess.**
At `R = 8` the producer keeps 18.2%. If that is too little, producers will carry
less share work than the quality tie-break rewards; if too much, sharing is not worth the
sharer's effort. There is no survey data on this, because v1 had no shares.
*Recommendation:* start at 2/1/1 and treat it as the first constant to revisit
after a month of mainnet. It is a pure output-shape rule, so changing it is a
one-line consensus change with no structural consequences.

**3. Aggregate-quality bands are launch constants.**
The 5%, 10%, and 15% contribution steps prevent raw-key multiplication from
ranking like deep work, but no live co-op margin distribution exists yet.
*Recommendation:* ship the four frozen bands and measure. Distinct shares mean
distinct personalized tasks, not distinct owners; ownership identity is neither
observable nor required by consensus. Revisit bands only in a future chain
version if observed margins cluster pathologically around a boundary.

**4. Retarget window of 16 is short.**
At mainnet spacing that is ~13 days, but the margin distribution is heavy-tailed
(70% of v1 blocks did not beat par at all), so a 16-sample median can jump. The
0.25x–4x clamp bounds the damage per window, but `C` could oscillate.
*Recommendation:* 16 for launch, because a young chain needs feedback more than
it needs stability, and revisit to 32 if two consecutive retargets move `C` by
more than 2x in opposite directions.

**5. `k` and grammar width both scale with `C`, and they interact.**
Raising `k` makes overfitting more expensive (good) but also makes the table
solution longer, which pushes against the 512-byte cap. This was measured and
resolved: `k = 10` reaches 515 bytes under the `letrec` repair and does not
fit at all, so `k` is frozen at a maximum of 8 (global worst case 415 bytes;
personalized full-key-anchor worst case 458 bytes, 54 spare) and difficulty
above that point climbs through grammar width, which
does not lengthen the table. Widening the grammar raises the hidden function's
complexity independently.
*Recommendation:* as specified, with the generator's explicit `|T| <= 512`
re-check as the backstop — if the two knobs ever conflict, the generator
re-rolls rather than publishing an unsolvable puzzle. If re-roll rates climb
above a few percent at high `C`, decouple `k` from `C` and drive it from a
separate, slower signal.
