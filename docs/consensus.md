# SigilCoin Consensus Specification

This specification applies to replacement proof-of-golf networks from height 0.
The nonce-PoW launch was retired before height 1 because its compute burn
contradicted the project's intent. Its launch record is historical and
superseded; retired nonce-PoW state is archived, never reused or validated under
two rule sets. This is a hobby chain, not settlement-grade security (§13).

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
4. **Scheduled proof-of-golf and longest-height selection.** Header `version`
   commits producer length `L` and puzzle complexity `C`. Validity requires
   `L <= par`. Golf score displays quality, not selection weight or subsidy.
   Only a strictly taller valid branch wins; equal height retains the durable
   active incumbent. Hardcoded release checkpoints bound reorgs (§5.8).
5. **Exact slots and puzzle-complexity retarget.** A non-genesis timestamp is
   exactly its parent's time plus the network spacing and MUST NOT be in the
   future. Header nonce is zero and `bits` is fixed at the network pow limit;
   there is no hash-target check, search, or hash-difficulty retarget. Every
   16 blocks, median relative improvement below par still adjusts `C`.
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
| `coin-max-graffiti-bytes` | 400 in the payload codec; non-genesis graffiti MUST be empty |
| `coin-max-shares` | 8 |
| `coin-max-commitments` | 16 |
| `coin-min-block-spacing` | 86400 s on mainnet; configured shorter slots on test networks |
| `coin-max-future-drift` | 0 |
| `coin-median-time-span` | 11 |
| mainnet/testnet/regtest exact slot spacing | 86400 / 3600 / 1 s |
| mainnet/testnet/regtest fixed `bits` (pow limit) | `0x1c2bcf04` / `0x1f00ffff` / `0x2000ffff` |
| `coin-retarget-window` | 16 |
| `coin-target-margin` | 100 milli-units |
| `coin-golf-max-savings` | 8 bytes |
| non-genesis block score / genesis score | 1..9 / 0 |
| header nonce / non-genesis coinbase `nLockTime` | 0 / 0 |
| header `version` prefix | `0x20600000` under `0xffe00000` |
| coinbase scriptSig bytes | codec 8..6583; non-genesis at most 6186 |

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

**Determinism.** Fixed-width fields make the preimage encoding injective.
`C(H)` is derived from the parent chain (§9), not read from the candidate
header, so a block cannot choose its own complexity by lying in `version`;
§9.4 requires the header to match the derived value exactly. Hash collision
resistance is assumed, not mathematical injectivity of SHA256d. A producer
can still vary an otherwise valid parent template to change its hash and thus
sample the next puzzle (§13).

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

## 5. Scheduled proof-of-golf and fork choice

### 5.1 The header budget

The serialized header remains Bitcoin's 80 bytes:

| Field | Bits | Use |
|---|---|---|
| `version` | 32 | producer length `L` and puzzle complexity `C` |
| `time` | 32 | exact scheduled timestamp |
| `bits` | 32 | fixed per-network pow-limit value, for header compatibility only |
| `nonce` | 32 | MUST be zero |

`previous-block` retains its Bitcoin meaning. `merkle-root` instead commits
the full `wtxid` of every transaction, so ordinary SegWit and Taproot witnesses
are part of the header identity without a separate BIP141 coinbase commitment.
A block MUST NOT contain duplicate `wtxid` values; this closes the odd-leaf
duplication ambiguity in Bitcoin's Merkle algorithm. Headers are hashed for
block identifiers and linkage, not to meet a target.

### 5.2 `version` layout

```text
version = 0x20600000 | ((L - 1) << 12) | C

version & 0xffe00000 = 0x20600000
version[20:12]       = L - 1       L in [1, 512]
version[11:0]        = C           C in [16, 4095]
```

`L` is the producer source length in UTF-8 bytes. A validator derives `C` from
the parent chain and `par` from that puzzle, then requires encoded `C` to match
and `L <= par`. Full body validation later requires the actual source byte
length to equal encoded `L`.

`coin-version-encode`, `coin-version-decode`,
`coin-version-solution-length`, and `coin-check-version` own this layout.

### 5.3 Exact schedule and fixed `bits`

For every non-genesis block:

```text
header.time = parent.time + network_spacing
header.time <= validator_current_time
header.bits = network_pow_limit_bits
header.nonce = 0
```

Mainnet spacing is 86400 seconds; public testnet uses 3600 seconds and regtest
uses 1 second. Future drift is zero on every network. Parent linkage and MTP
checks remain; an otherwise valid future slot must wait until the local clock
reaches it. Genesis uses its configured timestamp because it has no parent.

`bits` remains in the 80-byte header and MUST equal the network's fixed pow-limit
value at every height. It does not encode puzzle complexity or security effort.
There is no hash-target validation, nonce search, elapsed-time target retarget,
or requirement for a low block hash. Puzzle-complexity retargeting (§9) remains.

Exact timestamps schedule chain time, not the effort spent constructing a
branch. Past slots can be constructed without waiting a real slot between
them. A caught-up incumbent cannot be overtaken before another slot becomes
eligible, but missed slots and partitions can let a replacement become taller.
Checkpoint-compatible reorgs remain possible above the latest checkpoint.

### 5.4 Capped additive quality score

All arithmetic is exact integer arithmetic:

```text
savings = min(8, max(0, par - L))
score   = 1 + savings
```

Block validity separately requires `1 <= L <= min(512, par)` and a correct
program. The clamp does not make an over-par source valid. The public
`coin-golf-max-savings` constant is 8;
`coin-golf-savings(par, length)` and `coin-golf-score(par, length)` implement
the formula for positive exact-integer arguments.

A valid at-par fallback scores 1. Saving one byte scores 2; saving eight or
more scores 9. Further shortening remains valid and affects the uncapped
relative-margin signal for puzzle complexity, but adds no more block score.
Genesis contributes exactly 0, regardless of its witness length; the
non-genesis formula is not applied to genesis.

Block and cumulative golf scores are displayed competition quality only. They
MUST NOT affect canonical fork choice and currently do not alter subsidy.
Source length still participates in validity and puzzle-complexity retargeting.

### 5.5 One complete candidate, without grinding

The producer chooses a valid solution, transactions, payouts, commitments,
and reveals, builds the complete candidate once, encodes `L/C`, and sets the
scheduled timestamp, fixed `bits`, and zero nonce. It does not search hashes
or retry coinbase/header variations for a qualifying result.

A non-genesis coinbase MUST have transaction version 1, one input with final
sequence `0xffffffff`, no witness, `nLockTime = 0`, and empty graffiti. The
five-push payload, commitments, shares, ordinary transactions, and exact
payout rules remain in force. These canonical fields remove former free
cursors; they do not make the whole block template unique (§13).

The generated at-par witness is sufficient for a score-1 candidate without
program optimization. That candidate must still satisfy all body, payout,
transaction, and timestamp rules; validity does not guarantee selection over
a taller competing branch or an equal-height incumbent.

### 5.6 Header-first and body validation

Header acceptance requires:

1. canonical `version` shape and zero nonce;
2. linkage, exact parent-relative slot, MTP, and no future timestamp;
3. encoded `C` equal to the parent-derived complexity;
4. `bits` equal to the fixed network pow-limit value;
5. encoded `L <= par`;
6. agreement with each reached hardcoded checkpoint (§5.8).

Header download prioritization uses height, not claimed or verified golf
score. Valid peer `headers` responses must be contiguous, and body requests
rotate to less-tried valid branches after the preferred path has been tried.
Before persistence, a body must fit the 16 KiB cap, match the full-witness
Merkle commitment, and contain no duplicate `wtxid`.

Only full body validation may activate a branch. It reruns the puzzle and
requires actual UTF-8 source length to equal encoded `L`. Persisted scores and
any descendant score rebasing are display-quality accounting, not ordering
inputs. A false length claim or invalid program invalidates the block and
descendants. Non-genesis coinbase canonicality is mandatory, not merely a
builder preference.

### 5.7 Strict longest-height fork choice

```text
height(genesis) = 0
height(block)   = height(parent) + 1
replace incumbent iff valid candidate.height > incumbent.height
```

Only a strictly taller fully validated, checkpoint-compatible branch replaces
the active chain. Equal height MUST retain the durable active incumbent,
including after restart. Golf score, producer length, share quality, raw block
hash, nonce, and arrival metadata MUST NOT displace that incumbent. There is no
global deterministic hash ordering.

Different nodes can retain different equal-height incumbents, notably across
a partition. Building such a branch is cheap but cannot by itself replace the
incumbent. A child can make a branch strictly taller; it does not finalize any
ancestor above the latest checkpoint. Missed slots offer a takeover opportunity
because a replacement can fill elapsed slots without new wall-clock waits.

### 5.8 Hardcoded release checkpoints

Each network's chain config publishes a hardcoded, strictly height-ascending
list of `(height . internal-hash)` pairs. Heights are unique nonnegative exact
integers; each hash is the 32-byte internal `block-header-hash` bytevector,
not the reversed display identifier.

A branch MUST match every checkpoint at or below its tip height. Checkpoints
above that tip are not yet applied; an incompatible branch MUST NOT cross one.
Once a checkpoint at height `K` is reached, its hash and ancestry through `K`
are fixed under that release. Reorgs remain possible above `K`.

Checkpoints advance only in reviewed software releases. Nodes MUST upgrade to
share a newer checkpoint; there is no automatic, signed-broadcast, or
confirmation-count finality mechanism. Mainnet pins H0 and the live H1 block:

- H1 internal hash: `24f2cbbf4a5dbbce67abbcc047e300cda17c600e7ab3565846d27a0eb6b041d2`.
- H1 reversed display ID: `d241b0b60e7ad2465856b37a0e607ca1cd00e347c0bcab67cebb5d4abfcbf224`.

Mainnet rejects reorgs below H1; reorgs above H1 remain possible. Public
testnet and regtest still pin H0 only, fixing genesis but no post-genesis
history. This fork-choice/checkpoint cutover leaves block bytes, proof-of-golf
genesis hashes, and genesis timestamps
unchanged. Transport magic becomes `SGM3` / `SGT3` / `SGR3` on mainnet /
testnet / regtest to isolate older score-ranked peers. Existing proof-of-golf
H0 state may be reused; retired nonce-PoW state may not.

Opening durable state whose active branch conflicts with an installed
checkpoint fails rather than silently replacing active history. Operators
must compare released checkpoints as well as genesis when diagnosing a split.

## 6. Co-op shares

### 6.1 Coinbase payload

The scriptSig is exactly five minimally-encoded data pushes:

| # | Push | Size | Contents |
|---|---|---|---|
| 1 | HEIGHT | 0–5 B | BIP34 script number, unchanged |
| 2 | SOLUTION | 1–512 B | the producer's own solution for puzzle `H` |
| 3 | SHARES | 0–5145 B | reveals for puzzle `H-1` (§6.2) |
| 4 | COMMITS | 0–513 B | commitments for puzzle `H` (§7.1) |
| 5 | GRAFFITI | 0–400 B in codec | MUST be empty in non-genesis blocks; genesis marker only |

Decoder tags include `wrong-field-count`, `shares-oversize`,
`shares-malformed`, `commits-oversize`, and `commits-malformed`.

Non-genesis coinbases also obey §5.5's fixed version, input sequence, witness,
and lock-time rules. Ordinary transaction versions, sequences, witnesses,
lock times, and payouts are unchanged.

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
amounts, never producer block score or fork choice.

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

Payload-codec size bound (height 0 is the only height allowing a marker):

```
HEIGHT     0 data +   1 opcode  =    1   (height 0, OP_0)
SOLUTION 512 data +   3         =  515   (OP_PUSHDATA2)
SHARES  5145 data +   3         = 5148
COMMITS  513 data +   3         =  516
GRAFFITI 400 data +   3         =  403
                                 ------
                                   6583  = coin-max-coinbase-script-bytes
```

This is an encoder bound, not a valid genesis with shares: full validation
forbids shares at genesis. Non-genesis heights need at most 6 bytes for HEIGHT
and require a one-byte empty GRAFFITI push, so their actual maximum scriptSig
is `6 + 515 + 5148 + 516 + 1 = 6186` bytes.

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
verify the commitment matched. SHARES is capped at 5145 bytes; the payload codec
is capped at 6583 bytes, and a non-genesis scriptSig at 6186 bytes (§6.6).
These remain bounded within a 16384-byte block.

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

At mainnet's one-day scheduled spacing, an up-to-date producer normally has the
interval to solve puzzle `H`, publish a commitment for block `H`, and reveal in
`H+1`. This is not a guaranteed wall-clock window: overdue slots and replacement
branches can be built immediately. At regtest's one-second spacing, tests
construct commitments and reveals directly.

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

- *Recover a blinded share merely from its commitment.* The 32-byte blind
  prevents confirming solution guesses, assuming the blind remains secret and
  the hash is secure.
- *Rebind an included signed reveal to the thief's payout key.* The personalized
  puzzle and signature bind its key; knowing a revealed program does not remove
  those checks. The `H` / `H+1` pipeline proves prior commitment on that branch,
  not finality. A taller checkpoint-compatible branch can reorganize both heights.
- *Redirect a share's payout.* `pubkey` is in the signed preimage and the payout
  script is derived from it.
- *Include a share without its required contribution-weighted payout.* Output
  shape and exact values are consensus (§6.5).
- *Replay a share at another height, branch, or retarget epoch.*
  `parent_prev_hash`, `P` and `C(P)` are in the preimage.
- *Use a better golf score or lower hash to win an equal-height fork.* Golf
  scores display quality; hashes identify and link blocks. Neither displaces
  an equal-height incumbent (§5.7).

**Can:**

- *Copy the producer's own solution for puzzle `H`.* It is revealed in block `H`
  with no commitment, and no commitment is possible, because puzzle `H` is
  unknown before block `H-1` exists. See §10.5 for what protects the producer.
- *Censor commitments and reveals.* A producer chooses what his block carries.
  Censoring may forgo a future carrier output or current share participation,
  but share count and contribution do not improve or worsen fork position.
  There is no in-protocol defence; repeated production or a replacement branch
  can repeat the censorship. See §13.
- *Withhold a reveal.* Costs the withholder his own payout.
- *See, at reveal time, the full program of every sharer.* Programs are public
  once revealed, and reusing one at a later height is worthless because the
  puzzle changed.

### 7.6 Non-normative public-testnet relay

The reference public-testnet relay interface uses
`https://pool.testnet.sigilcoin.lol` as an optional coordination endpoint. This
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
can construct mechanically from public data. Used in an otherwise valid
non-genesis block at its scheduled timestamp, it earns score 1 without hashing
search or program optimization.

### 8.1 Public data available to a miner

`prev_hash` (from the parent header), `H`, `C(H)` (derived, and committed in
`version`), hence `seed(H)`, hence the whole puzzle spec including the `k`
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
using that candidate must still meet §5's schedule and the ordinary block rules.

Genesis uses the same par-witness selection, a zero header nonce, and fixed
network `bits`, but contributes score 0. The replacement networks began with
fresh genesis identities and fresh state from height 0. There is no nonce-PoW
compatibility path and no reuse of retired chain state (§14).

## 9. Puzzle-complexity retargeting

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

- `m_med > 100` (producers beating par by more than 10%) raises `C`, adjusting
  the generator's example count, grammar width, and constraint tier.
- `m_med < 100` lowers `C`. Neither case changes slot spacing or fixed `bits`.
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

Header `version` MUST equal
`0x20600000 | ((L(H) - 1) << 12) | C(H)`. Its fixed prefix, decoded length,
complexity range, derived `C`, and `L <= par` are all validated as described in
§5.2.

Neither `C` nor `L` is freely chosen: `C` comes from the parent chain and `L`
must equal the validated body solution's byte length. Encoding both supports
header length/complexity checks and determines the claimed additive score.

### 9.5 Determinism

`par_i` is a pure function of `(prev_hash_i, i, C(i))`, `L_i` is read from the
header, all arithmetic is exact integer with explicit floors and clamps, and
the median is a sort of exactly 16 values with a fixed index. A reorg recomputes
`C` from the new branch's own 16 blocks, which is why `C(P)` is bound into the
share preimage (§6.3).

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

The producer's own solution for puzzle `H` is revealed in block `H` without
a prior commitment. A copier can use the same source in a sibling with the
same parent, obtaining the same `L` and block score without a nonce search.
That alone cannot displace an equal-height active incumbent at the receiving
node. A shorter valid source improves displayed score, not fork position; only
a strictly taller valid, checkpoint-compatible branch can replace it.

This is limited local incumbent protection, not authorship protection or
settlement. Different observers can retain different equal-height branches.
Children add height, not finality above the latest checkpoint. Public witnesses
make alternate histories cheap to build, and missed slots or partitions may
let one become taller.

## 11. Validation cost

Per block, worst case, with the frozen caps:

| Work | Bound | Notes |
|---|---|---|
| header checks | O(1) after puzzle derivation | version, fixed `bits`, zero nonce, MTP, exact slot, no future time, provisional base point; hashes only for identity/linkage |
| block size and commitment | one serialization plus `wtxid` tree | checked before persistence; commits ordinary transaction witnesses |
| coinbase decode | O(6583) bytes | five pushes + one re-encode; non-genesis at most 6186 |
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

The timing estimates above and derivation audit below are historical
measurements of the bounded puzzle VM, not a new validation run or a
throughput/security claim for the replacement networks.

The machine boundary is executable: a 20000-step evaluation succeeds, the same
program on 19999 fuel stops at 19999, and an attempt containing a formerly
unbounded single evaluator call returns `budget-exhausted` at exactly 20000.
A deterministic audit of 1280 full derivations (20 seeds, two heights, four
complexities and all eight constraints) measured 2117 steps for both the
heaviest attempt and heaviest complete non-fallback derivation. The hard bounds,
not the sample, govern consensus.

At 86400 s mainnet spacing, the historical 74.3 s estimate is about 0.1% of one
slot. This does not bound hostile traffic or repeated validation of siblings.

**Pre-validation gate (required).** A node MUST order body validation
cheapest-first. The canonical order is:

1. header acceptance: canonical version, zero nonce, exact slot and no future
   time, derived `C`, fixed network `bits`, and `L <= par`,
2. block size and merkle commitment,
3. canonical non-genesis coinbase version, sequence, witness, lock-time and
   empty graffiti; canonical payload and actual producer-source length equal
   to the header's encoded `L`,
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
has a 6583-byte codec bound. `coin-connect-block` passes SigilCoin's own rules record
into Bitcoin's connector, which is the only supported path.

---

## 12. Complete failure tag index

| Tag | Source | Meaning |
|---|---|---|
| `not-bytevector`, `malformed-script`, `wrong-field-count`, `not-a-push`, `bad-height`, `non-canonical` | coinbase codec | malformed or non-canonical payload |
| `solution-empty`, `solution-oversize`, `graffiti-oversize` | coinbase codec | field exceeds frozen bounds |
| `non-canonical-graffiti` | coinbase codec | nonempty graffiti at a non-genesis height |
| `shares-oversize`, `shares-malformed`, `shares-unordered`, `shares-at-genesis` | SHARES codec | invalid reveal set |
| `commits-oversize`, `commits-malformed`, `commits-unordered` | COMMITS codec | invalid commitment set |
| `solution-malformed`, `solution-over-par`, `solution-parse-failed`, `solution-eval-failed` | solution check | malformed source, source above the puzzle's par ceiling, or interpreter failure |
| `solution-not-a-procedure`, `solution-mismatch` | solution check | wrong result shape or examples not reproduced |
| `constraint-violated` | constraint check | source or AST violates selected rule |
| `share-bad-pubkey`, `share-bad-signature`, `share-uncommitted`, `share-duplicate-solution`, `share-not-under-par` | share check | personalized task or binding failed |
| `share-solution-*` | share check | solution rejection, prefixed for a share |
| `coinbase-output-shape`, `coinbase-output-value` | payout validation | output count, scripts, or values differ |
| `non-canonical-coinbase` | body connection | non-genesis coinbase version, sequence, witness, or lock time is not canonical |
| `bad-slot`, `time-too-far-ahead` | header context | timestamp differs from the exact parent-relative slot or is in the future |
| `malformed-header`, `version-prefix`, `complexity-range`, `complexity-mismatch` | header/version check | malformed fields, invalid prefix or complexity, or encoded `C` differs from the parent-derived value |
| `solution-length-mismatch` | body connection | encoded `L` differs from the validated solution byte length |
| `height-mismatch`, `missing-coinbase`, `block-oversize`, `malformed-block` | block check | malformed block envelope or body |
| `internal-error` | any check | implementation failure while validating |

The header predicate also rejects nonzero nonce or non-network `bits`; those
boolean failures do not expose separate detailed tags.

---

## 13. Limitations and open questions

**1. Commitment censorship has no in-protocol defence.**
A producer can simply omit COMMITS. The carrier output (§7.4) pays for a valid
commitment path, but does not force inclusion. Repeated producers and taller
checkpoint-compatible replacement branches can repeat censorship. No commitment-count retarget or
other anti-censorship rule is part of this protocol.

**2. Contribution bands are launch constants.**
The 5%, 10%, and 15% margin thresholds assign payout contributions 1 through
4. They affect reveal selection and payout weights, not producer block score
or fork choice. No replacement-network co-op margin distribution is claimed. *Recommendation:*
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
residual routing are consensus. The payout contract binds output shape,
conservation, and signed keys; it does not prove that participants will commit,
reveal, or carry others' work. Changing the formula after launch is a hard fork.

**5. Permissionless keys are not identities and can be ground.**
One actor may control all eight share keys. The full-key anchor proves each
accepted source solves its chosen pubkey's distinct puzzle, but pubkeys are free
to generate, so a miner can sample keys and work only on unusually easy
personalized puzzles. Contribution is capped at 4 per share for selection and
payout, not fork-choice benefit; no rule proves distinct owners or makes key
selection scarce.

**6. Alternative histories are cheap above the latest checkpoint.**
Old puzzles and solutions are public, and descendants can be rebuilt with
mechanically available witnesses. Changing a block hash changes subsequent
puzzles but adds no hash-search cost; past slots are already eligible.
Better golf score cannot make a shorter or equal-height rewrite win.
A replacement must become strictly taller, for example when the incumbent
misses a slot or during a partition, and must match every reached checkpoint.
Only reviewed release upgrades advance that boundary: currently H1 on mainnet,
H0 on public testnet and regtest. The latter protect genesis, not later history.

**7. Equal-height forks are local, and template manipulation remains possible.**
Equal height preserves each node's durable active incumbent, so observers
can remain split. Neither score nor a lower hash resolves the tie. Zero nonce, fixed
coinbase metadata, and exact time remove obvious free cursors, not all template
freedom: valid producer sources, payout scripts, transaction selection/order,
commitments, and reveals still change a parent's hash and the next puzzle.
The reference producer builds once; consensus does not prove that nobody
sampled alternative valid parent templates.

**8. This is not settlement-grade security.**
The schedule, displayed golf quality, and longest-height rule organize a
low-value hobby competition. They do not provide Bitcoin's accumulated
expenditure or globally convergent equal-height choice. Checkpoints protect
only their pinned ancestry on nodes that install the same release. Reorgs
above that boundary, local forks, key sampling, censorship, and bodyless-header
flooding remain possible. Claimed savings cannot improve body-download
priority, but peer quotas are not Sybil resistance and flooding can still
delay body selection. Neither historical tests nor a one-day slot justify
exchange, bridge, payment-settlement, or valuable-balance reliance.
Long-running hostile load, resource growth, and replacement-network behavior
remain unmeasured here.

---

## 14. Network and implementation status (non-consensus)

The sole public rule surface is `(sigil coin consensus)`; node code consumes it
through `(sigil coin node)`. The replacement networks apply this proof-of-golf
contract from genesis, with no old/new dual validation mode.

Mainnet uses 86400-second slots, public testnet 3600-second slots, and regtest
1-second slots. All require exact parent-relative timestamps and zero future
drift. Fixed pow-limit `bits` are compatibility fields, not measured security
targets. Current network definitions and the all-network genesis generator are
the source of genesis timestamps, quotes, and display/internal hashes; old
launch identifiers must not be copied into replacement state.
The longest-height/checkpoint change preserves those replacement genesis
identities, timestamps, and block bytes. Mainnet/testnet/regtest transport magic
is `SGM3` / `SGT3` / `SGR3` (final byte `0x33`), isolating older score-ranked
peers. Existing proof-of-golf H0 state may be reused. Nodes must install
reviewed release updates to share newer checkpoints; the initial release pins
only each network's H0.

The 2026-09-12 nonce-PoW mainnet launch was retired before height 1: no
post-genesis blocks existed, and compute burn contradicted the hobby project's
intent. `LAUNCH.md` remains a superseded historical record, not instructions or
evidence for operating the replacement networks.

Archive retired nonce-PoW databases and histories; never reopen or migrate them
as the new chain. Replacing that state requires fresh `state/*-proof-of-golf`
directories matching each network's genesis. Software must not delete archived operator
state. Deploy a low-CPU scheduled producer that builds a complete candidate
once, rather than an always-busy hashing loop. The puzzle VM, co-op signatures
and commitments, ordinary transactions, payout arithmetic, and 80-byte headers
are unchanged; the network identity and consensus admission/fork contract are
not backward compatible.
