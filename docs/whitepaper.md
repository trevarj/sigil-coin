# SigilCoin

A hobby blockchain for scheduled proof-of-golf, longest-height forks, and release checkpoints.

SigilCoin is a toy chain for the Sigil community. It is worth nothing, it is
intended to stay worth nothing, and there is no premine. Its validation rules
are precise, but precision is not economic security: this is not a
settlement-grade chain.

[`consensus.md`](consensus.md) is the sole normative protocol specification.
This paper explains motivation and design; where prose differs from that
specification, `consensus.md` governs.

The chain is built on the `sigil-bitcoin` libraries and keeps Bitcoin's
80-byte header, transaction format, UTXO set and script engine. It replaces
hash-search proof of work with scheduled proof-of-golf. Each block's puzzle
is a deterministically generated set of input/output pairs plus a syntactic
constraint. A valid producer program is no longer than par. A non-genesis
block scores one point plus one per byte saved, capped at eight saved bytes:
scores are 1..9, not exponential odds. Genesis scores zero. Golf score displays
competition quality; it does not select canonical branches or currently alter
subsidy.

The replacement networks use these rules from height 0. The old nonce-PoW
mainnet launch was retired before height 1 because compute burn contradicted
the project's intent; its state is archived, never reused. `LAUNCH.md` remains
an explicitly superseded historical record. Sigil was itself implemented by a
language model, and using models or synthesis scripts to improve programs is
part of the game, not an exploit to prohibit.

---

## 1. What the chain is for

SigilCoin is a daily program-golf game with a shared ledger, not an attempt to
reproduce Bitcoin's expended-work security without paying its cost. The
artifact is something a human or model can read: a small program.

**The result is legible.** A selected block carries a program no longer than
its generated par and never more than 512 bytes. "How short a valid program
can you write?" is the social point, not a claim to more fork-choice weight.

**Verification is bounded.** A node re-runs the program against published
examples under fixed resource caps. This establishes correctness on the
examples, not how much effort the author spent or who wrote it.

**Hash burning is unnecessary.** The public generator supplies a valid at-par
fallback. A low-CPU producer can build a complete score-1 candidate once and
wait for the exact scheduled slot; optimizing the program can raise its score
to at most 9. There is no nonce search or coinbase-lock-time search.

Nothing here makes programs scarce or alternative branches costly to build.
Cheap equal-height alternatives cannot displace a local incumbent, but missed
slots offer takeover opportunities and partitions can leave nodes split.
Reorgs remain possible above the latest release checkpoint: H1 on mainnet,
H0 on testnet and regtest.
Valid parent templates can still be manipulated to sample future puzzles.
SigilCoin is not money, not a fair-distribution claim, and not safe for valuable
settlement.

---

## 2. What is inherited and what is replaced

Inherited from `sigil-bitcoin`, unmodified:

- the 80-byte block header, its serialization and its double-SHA256 hash
- transaction format, the UTXO set, and value conservation
- the script engine, P2WPKH addresses and signature rules
- the peer-to-peer wire protocol, headers-first sync and block relay

Changed for SigilCoin:

- admission: a correct producer program with `L <= par`, at the exact scheduled
  timestamp, with no future drift and no hash-target check;
- header fields: `version` carries producer length and puzzle complexity,
  `bits` is fixed at the network pow limit for compatibility, and `nonce = 0`;
- non-genesis coinbase metadata: version 1, final input sequence `0xffffffff`,
  no witness, `nLockTime = 0`, and empty graffiti;
- fork choice: only a strictly taller valid branch wins; equal height retains
  the durable active incumbent, regardless of score, hash, or arrival metadata;
- release checkpoints: hardcoded `(height . internal-hash)` pairs prevent
  incompatible branches from crossing pinned history. Only reviewed software
  releases advance them, and nodes must upgrade to share a newer checkpoint.

The existing one-block coinbase maturity and ordinary transaction/payout rules
are unchanged by this cutover.

Bitcoin's soft forks are all active from height 0. A new chain has no legacy
to grandfather, so BIP34, BIP66, BIP65, CSV, segwit and taproot are on at
genesis.

---

## 3. The puzzle language

A solution is a program, so the chain needs a language to write it in. That
language is consensus: every node parses and evaluates every solution, and any
disagreement about what a program means is a silent chain split.

The language is a small Scheme subset with its own parser and its own
evaluator, both written from scratch inside the chain's source tree
(`packages/sigil-coin-puzzle/src/sigil/coin/puzzle.sgl`).

### 3.1 Why not the host's `eval`

Using Sigil's own reader and evaluator would have been one line, and it would
have been wrong for four reasons.

- **Totality.** Consensus needs every input to terminate with a value or a
  tagged error. A host evaluator can loop forever, and "the validator hangs"
  is not a rejection reason.
- **Determinism of cost.** Every validator must agree whether evaluation stays
  within the fixed steps, allocations, strings, and depth caps. Host evaluator
  costs are implementation details and could make nodes disagree.
- **Attack surface.** A host evaluator reaches the filesystem, the network,
  the clock and the process. A miner-supplied program must reach none of them.
- **Freezability.** The host language will keep improving. The puzzle language
  must not: a new builtin, a changed numeric tower or a different error
  ordering is a hard fork.

So the language is deliberately, permanently small.

### 3.2 The language

```
datum   = integer | boolean | string | symbol | list | "'" datum
list    = "(" datum* ")"
special = (quote d) | (if t c a) | (lambda (v ...) body)
        | (let ((v e) ...) body) | (letrec ((v e) ...) body)
        | (and e ...) | (or e ...)
```

Seven special forms, 41 builtins, and everything else is an application. Only
`#f` is false. There is no I/O, no crypto, no host `eval`, no floating point,
no mutation, no `call/cc`, no `define` and no macros. Integers are exact and
unbounded up to a magnitude cap; strings are byte strings; symbols are
compared by identity.

The evaluator is an explicit environment-passing interpreter over the parsed
AST. An environment is an association list of `(symbol . box)` holding local
bindings only; builtins live in a table consulted after locals miss, so a
local binding can shadow a builtin name but a special form name can never be
bound. Tail positions reuse the caller's depth, so tail recursion is bounded
by fuel rather than by the depth cap.

### 3.3 Caps, and honest charging

Every evaluation runs on a machine with five budgets:

| Cap | Value | What it bounds |
| --- | --- | --- |
| source | 512 bytes | the program text |
| fuel | 200000 steps | evaluation, including every example application |
| allocations | 400000 cells | host objects the program causes to exist |
| string bytes | 65536 | total string construction |
| eval depth | 128 | non-tail nesting |
| parse depth | 64 | datum nesting |
| integer magnitude | < 2^256 | every literal, intermediate and result |

The allocation counter is the interesting one because it makes the memory cap
enforceable rather than advisory. A *cell* is one
host object the evaluator allocates: a pair, a binding box, a closure. Every
allocating site is charged explicitly — binding a name costs 3 (box, entry,
spine), `map` costs 3n, `append` costs 2 per copied element, `fold` 2n,
`quote` and `equal?` 4 per node of the datum they walk. The count is a total,
not a high-water mark, so it charges transient conses too; since nothing can
be retained that was not charged, the total is also an upper bound on live
memory.

Fuel alone would not give that bound. Measured programs allocate up to about
3 cells per step, so the fuel cap alone would permit roughly 140 MB of churn.
A closure-retaining stress program reached about 124 MB resident set. The
allocation cap, not fuel, is what bounds memory.

The cap is a pure function of the program and its inputs. No host word size,
allocator, garbage collector or build flag enters it, so every node reaches
`allocation-exceeded` on exactly the same cell.

Failures are tagged, not thrown: `bad-syntax`, `unbound-variable`,
`uninitialized`, `arity-error`, `type-error`, `division-by-zero`,
`index-error`, `overflow`, `fuel-exhausted`, `allocation-exceeded`,
`string-limit`, `depth-exceeded`, `internal-error`. No host exception escapes
the evaluator, so a validator needs no handler on the hot path.

---

## 4. How a puzzle is generated

### 4.1 The seed

Every block's puzzle is a pure function of the chain up to its parent:

```
seed(H) = SHA256d( "SigilCoin/puzzle/1"      18 ASCII bytes
                 || prev_hash                  32 B, internal order
                 || u64le(H)
                 || u32le(C(H)) )

seed(0) = SHA256d( "SigilCoin/genesis/puzzle/1" )
```

`prev_hash` is the internal 32-byte header hash, never the reversed display
id. Every integer is fixed-width little-endian, making the preimage encoding
injective; hash collision resistance is assumed. `C(H)` is the puzzle-complexity
parameter of section 8, derived from the parent chain rather than chosen in
the candidate header. A false complexity claim fails validation. This binds
the puzzle to its branch, but does not prevent a producer from choosing among
valid parent templates whose different hashes yield different next puzzles.

Nothing about the puzzle is stored in a block. Every node regenerates it while
validating, which is why generation must be bit-for-bit deterministic: it is
consensus code that runs on every validator, and a generator that differed by
one draw between two nodes would split the chain silently, with no wire
message to surface the disagreement.

Determinism is achieved by construction: SplitMix64 over exact integers with
explicit 64-bit masking, FNV-1a absorption of `(seed, height, retry)` with
self-delimiting integer encoding, `let*`-sequenced draws because argument
evaluation order is not specified in Sigil, and the frozen interpreter for
every evaluation the generator performs. No clock, no filesystem, no host
randomness.

### 4.2 What complexity controls

A 12-bit parameter `C`, in `[16, 4095]`, drives three knobs:

```
k(C)    = clamp(3 + floor(C / 512), 3, 8)      example count
w(C)    = min(24, 6 + floor(C / 205))          enabled prefix of the
                                               frozen 24-production grammar
tier(C) = 0 if C < 256, 1 if C < 1024, else 2  which constraints may be drawn
```

`C` never touches an evaluator cap. This is the load-bearing rule of the whole
design: every node re-evaluates every solution, and only the miner is paid for
the work, so validation cost must be a constant of the protocol rather than a
function of difficulty. Difficulty is raised by widening what a solution must
*express*, never by making a program cost more to check.

### 4.3 One generation attempt

An attempt is keyed by `(seed, height, retry)` and runs under a shared budget
of 20000 evaluator steps covering every evaluation it performs:

1. Draw one production from the constraint-compatible prefix of the frozen
   24-entry grammar at width `w(C)`. Canonically render its one-argument lambda,
   apply any deterministic constraint wrapper, and lexically tighten the
   complete source.
2. Reject if the tightened hidden source does not parse, exceeds 512 bytes, or
   violates the height's constraint.
3. Draw `k(C)` pairwise-distinct inputs from the constraint's domain and apply
   the hidden function. Reject oversized literals, execution failures,
   procedures, non-values, constant outputs, or a puzzle solved by a one-arity
   builtin.
4. Build the table source from the final examples, apply the same wrapper and
   lexical tightening boundary, then parse, constraint-check, and execute it
   under the real consensus caps.
5. Set `par` to the shorter tightened source length, retaining the hidden
   source on a tie. Reject if either source falls below the 24-byte minimum par
   floor.

The tightener is lexical, not a textual golf pass. Outside strings it consumes
spaces, tabs, line feeds, and carriage returns, retaining one ASCII space only
between adjacent bare-token characters. Parentheses, double quotes, and quote
shorthand require no separator. Inside strings, bytes are copied unchanged;
backslash copies itself and the following byte, and only an unescaped double
quote ends the string. The language has no comments to preserve. The canonical
AST printer remains the canonical single-space renderer. Only complete
generated witnesses cross this tightening boundary, and they are re-parsed and
re-executed afterward.

The constraint is drawn from a dedicated stream keyed on a reserved retry
value, so re-rolls never move it: the constraint is a function of
`(seed, height, C)` alone, and a miner knows the day's rule before the
generator has settled on a puzzle.

After 64 rejections the ordinary generator uses its frozen, verified fallback.
Explicit-constraint and personalized generation instead use verified
constraint-preserving fallbacks, and the personalized fallback retains the
mandatory key anchor. Every fallback passes the same tightened-source checks.

`par` is an upper bound on the true optimum and never a lower one. It is also
the producer validity ceiling: a miner may submit a solution at par or find
something shorter, but may not exceed it. The generator exposes the shorter
verified witness (hidden on ties), so valid at-par producer work is always
available from public data.

### 4.4 The rotating constraint

Each height draws one of eight syntactic rules, checked over the raw source
bytes, the parsed AST, or both:

| id | Name | Rule |
| --- | --- | --- |
| 0 | `none` | no restriction |
| 1 | `no-digits` | no source byte in `0x30..0x39` |
| 2 | `no-quote` | no `'` byte and no `quote` form |
| 3 | `letrec-required` | at least one `letrec` form |
| 4 | `builtin-cap` | at most `D` distinct free builtin names; `D = 6`, or 4 at tier 2 |
| 5 | `single-lambda` | exactly one `lambda` form |
| 6 | `small-literals` | every integer literal, including inside quoted data, has magnitude at most 9 |
| 7 | `fold-required` | `fold` appears as a free identifier |

Tier 0 draws from `(0)`, tier 1 from `(0 1 3 5)`, tier 2 from `(1 2 4 6 7)`.
Tier 0 being unconstrained means an early chain, or one that has retargeted
down to trivial puzzles, is never made harder by a rule.

Checking is one byte scan plus one AST walk, both bounded by 512 bytes of
source, with no evaluation anywhere. The walk carries the set of bound names,
which is what makes rule 4's "free" precise: a solution that writes
`(let ((map ...)) ...)` is using a local, not a builtin, and is charged
accordingly. Rule 2 checks both the byte and the AST on purpose — the lexical
check alone would miss a hand-written `(quote x)`, and the byte check is
`O(n)` and runs before parsing, which is the cheap rejection path.

The constraints do two jobs. They add difficulty that costs a validator
nothing, and they break the monoculture: without them, one good synthesizer
would emit the same shape of answer every day forever.

---

## 5. What a valid solution is

A producer candidate solution is a byte string `s` with
`1 <= |s| <= min(512, par)`. It is checked in this order, first failure
winning:

| # | Check | Rejection |
| --- | --- | --- |
| 1 | bytes or string | `solution-malformed` |
| 2 | `1 <= |s| <= 512` | `solution-oversize` / `solution-malformed` |
| 3 | `|s| <= par` | `solution-over-par` |
| 4 | the day's constraint, source half | `constraint-violated` |
| 5 | parses | `solution-parse-failed` |
| 6 | the day's constraint, AST half | `constraint-violated` |
| 7 | evaluates to a value | `solution-eval-failed` |
| 8 | the value is a 1-arity procedure | `solution-not-a-procedure` |
| 9 | every example reproduced, in draw order | `solution-mismatch` |
| — | anything raises | `internal-error` |

The order is cost, not taste: an `O(|s|)` byte scan precedes a parse, which
precedes the only step whose cost is interesting.

**One machine per solution.** Parsing, evaluation and all `k` applications
share a single machine with one 200000-step budget and one allocation counter.
Total validation cost for a solution is therefore bounded by one fuel budget
*regardless of `k`*, so raising the example count through the retarget cannot
raise node cost. The deterministic `steps` and `cells` reports remain useful
diagnostics, but neither affects block score or fork choice.

Bare builtins are legal solutions — `car` is three bytes — and the generator's
degeneracy probe guarantees no published puzzle is solved by one.

At-par and shorter producer solutions are valid; anything longer is
`solution-over-par`. Shares deliberately use the stricter
`L < personalized_par` rule, so an at-par personalized witness is not a share.
Par also supplies the retarget signal, but that is not its only consensus role.

---

## 6. The generated par candidate

A generated puzzle with no valid program would leave producers with nothing to
submit. The chain therefore provides, for every height, constraint, and
complexity, a public mechanically constructible producer candidate of length
exactly `par`.

A producer has the parent header, hence `prev_hash`, `H`, and `C(H)`, hence the
seed and whole puzzle. Running the same generator every validator runs yields
the examples, constraint, tightened hidden source, tightened table source, and
deterministic par witness: the shorter source, hidden on ties. Used in an
otherwise valid candidate at the scheduled timestamp, it earns score 1 without
hash search. It does not guarantee selection against a taller branch or an
equal-height incumbent; improving that program's score does not change this.

The table source is a lexically tight nested `if`; schematically:

```text
(lambda(x)(if(equal? x'i_0)'o_0(if(equal? x'i_1)'o_1 ...'o_{k-1})))
```

The last output is the default branch, so `k` pairs produce `k-1` tests. It
reproduces every pair by construction because `equal?` on the puzzle value
domain is exactly the comparison consensus uses to check an example.

Two constraints need semantics-preserving repair wrappers:
`letrec-required` wraps the body in
`(letrec((f(lambda(y)y)))(f BODY))`, adding 29 bytes over the bare wrapper;
`fold-required` wraps it in `(fold(lambda(a b)a)BODY'())`, adding 23. Every
other rule is satisfied by the body and example domain.

### 6.1 Executable candidate bound

After tightening, each added table branch costs `16 + |i| + |o|` bytes. Exact
generator bounds are:

| Case | Maximum bytes | Headroom below 512 |
| --- | ---: | ---: |
| global, `k=10`, widest `letrec` repair | 496 | 16 |
| global, `k=10`, `fold` repair | 491 | 21 |
| global, frozen `k=8` | 400 | 112 |
| personalized, frozen `k=8` | 443 | 69 |

Ten global examples now fit but leave too little room under the shared source
cap, especially once personalized witnesses are considered. The example count
therefore remains frozen at 8; difficulty above it comes from grammar width,
which does not lengthen the table.

The implementation never trusts the arithmetic alone. It constructs each
actual hidden and table source, tightens it, measures it, parses it,
constraint-checks it, and executes it against every example before the puzzle
may be published. Candidate availability is verified for every accepted puzzle.

### 6.2 What the witnesses mean for the game

The table is always mechanically available, while the hidden source can be the
shorter generated witness. `par` is the minimum of their verified lengths and
the generator deterministically returns the matching source, choosing hidden
on ties. Structural programs can beat par; producers may submit them or the
at-par witness, but never a longer source. Each byte saved adds one point up to
the eight-byte savings cap. Shares remain strictly under personalized par and
do not change producer block score.

Tests and tools do not manufacture useful shares by deleting whitespace from a
generated witness. A deterministic semantic fixture exists only when every
ordinary personalized example input is non-string: replace the exact tight
anchor predicate `(equal? x"@")` with `(string? x)`, run the production share
checker, and keep it only if it is strictly shorter than par. A specification
with an ordinary string input has no such candidate.

Genesis carries the generated par witness of the frozen genesis puzzle,
choosing the hidden source on a tie. Its header nonce is zero and `bits` has
the network's fixed value. Its reward and chain-score contribution are zero;
its single output is an unspendable `OP_RETURN`: no premine. The replacement
networks have fresh genesis identities. Retired databases are archives, not
state to migrate or reopen under these rules.

## 7. Scheduled proof-of-golf and fork choice

### 7.1 What the header commits

The header remains 80 bytes. `version` carries producer length and puzzle
complexity:

```text
version = 0x20600000 | ((L - 1) << 12) | C
version & 0xffe00000 = 0x20600000
```

Bits 20..12 encode `L - 1` for lengths 1..512; bits 11..0 encode `C` in
16..4095. A validator derives `C` and par from the parent, requires encoded
values to agree, and later requires the body program's UTF-8 byte length to
equal `L`.

Header `bits` is fixed at the network pow limit as a compatibility field, not
a measure of required hashing. The uint32 `nonce` MUST be zero. Header hashing
still supplies block identifiers and parent linkage, never an admission roll.

### 7.2 Exact slots, not a hash-difficulty retarget

| chain | exact slot spacing | fixed pow-limit `bits` |
|---|---:|---:|
| mainnet | 86400 s | `0x1c2bcf04` |
| public testnet | 3600 s | `0x1f00ffff` |
| regtest | 1 s | `0x2000ffff` |

Every non-genesis header timestamp equals `parent.time + network_spacing`.
It must not exceed the validator's current time: future drift is zero.
Genesis uses its configured timestamp. MTP and linkage checks remain.

`bits` stays at the fixed network value at every height. There is no hash
target validation, nonce search, or hash-difficulty retarget. The schedule
replaces the old attempt to obtain cadence through hash expenditure.

A slot is a constraint on chain timestamps, not a required day of computation.
When slots are already in the past, catch-up or replacement branches can be
built without waiting a real slot between blocks.

### 7.3 How shorter programs add score

With exact integer arithmetic:

```text
savings = min(8, max(0, par - L))
score   = 1 + savings
```

Validity separately requires a correct source with `1 <= L <= min(512, par)`.
The clamp does not admit over-par programs. An at-par program scores 1, one
byte saved scores 2, and eight or more bytes saved score 9. Further savings
still affect the relative-margin puzzle-complexity retarget, not block score.
Genesis is the exception: its score is exactly zero.

The public API is `coin-golf-max-savings = 8`,
`coin-golf-savings(par, length)`, and `coin-golf-score(par, length)`.
The two procedures take positive exact integers. These arithmetic helpers
do not replace source validation.

### 7.4 One complete candidate and body binding

The producer validates its chosen program and builds the complete candidate
once: transactions, payouts, commitments, reveals, full-transaction `wtxid`
Merkle root, encoded version, exact scheduled time, fixed `bits`, and zero
nonce. There is no grinding loop. Duplicate `wtxid` values are forbidden so
Bitcoin's odd-leaf Merkle duplication cannot admit two bodies under one header.
A non-genesis coinbase has version 1, a single input with sequence `0xffffffff`,
no witness, zero lock time, and empty graffiti. Ordinary transactions and their
lock times remain unchanged; their witness bytes are committed directly by the
header Merkle root.

Header-first validation checks those header fields, derived `C`, the par
ceiling, and reached release checkpoints. Download prioritization uses height,
not claimed or verified golf score. Body download rotates across less-tried
valid branches, and peer header batches must be contiguous. An in-hand body
must pass the size, full-witness commitment, and duplicate-`wtxid` checks.
Only full body validation can activate a branch: it checks the canonical
coinbase, reruns the program, and requires its actual length to equal encoded
`L`. A false claim invalidates the branch. Persisted golf scores and descendant
score rebasing are display-quality accounting, not selection inputs.

The public at-par witness removes any need to optimize merely to produce a
valid candidate. Other block rules still apply, and a valid candidate can lose
fork choice.

### 7.5 Strict longest-height fork choice

```text
height(genesis) = 0
height(block)   = height(parent) + 1
replace incumbent iff valid candidate.height > incumbent.height
```

Only a strictly taller fully validated, checkpoint-compatible branch replaces
the active chain. Equal height retains the durable active incumbent, including
across restarts. Golf score, share quality, raw block hash, nonce, and arrival
metadata supply no further tie-break; there is no global deterministic hash
ordering. Shortening a valid program improves displayed quality, not fork
position or the current subsidy.

Two observers can retain different equal-height branches, especially across a
partition. Building an alternative is cheap, but it must become strictly taller
to replace the incumbent. A caught-up incumbent cannot be overtaken before the
next slot is eligible; missed slots give a replacement a chance to extend
first. A child adds height, not finality above the latest checkpoint.

### 7.6 Hardcoded release checkpoints

Chain configs contain reviewed `(height . internal-hash)` checkpoints in
strictly ascending height order. Each hash is the internal 32-byte block hash,
not its reversed display identifier. A branch must match every checkpoint it
has reached and cannot cross an incompatible one. A reached checkpoint at
height `K` pins the block and its ancestry through `K`; reorgs remain possible
above it.

Checkpoints advance only when a reviewed software release hardcodes a later
pair. Nodes must upgrade to share the newer checkpoint. This is a release
coordination and trust boundary, not automatic finality, signed checkpoint
broadcasts, or a confirmation-count guarantee. Mainnet currently pins H0 and
H1 on the replacement slogan chain; public testnet and regtest remain
H0-only, fixing genesis but no post-genesis history.

The authorized mainnet reset restores the exact genesis quote
`Sigil - Practical Symbolic Power`, retaining timestamp `1789228800`
(`2026-09-12T16:00:00Z`). Mainnet H0 internal hash is
`d15ecce0c8a3e4dc07c8136eb68770c2e59683cbad4bd268c420ec24ae040d3a`
and its reversed display ID is
`3a0d04ae24ec20c468d24badcb8396e5c27087b66e13c807dce4a3c8e0cc5ed1`.

The replacement slogan-chain H1 is produced and pinned. H1 internal hash is
`ec3ef647e87a3b54e832b10f0788e2494ac7934096b7357576b263504281637d`
and its reversed display ID is
`7d6381425063b2767535b7964093c74a49e288070fb132e8543b7ae847f63eec`.

The mistaken marker-quote mainnet H0/H1 and its H1 checkpoint are abandoned,
not continued. Reorgs remain possible above H1 on mainnet and above H0 on
testnet and regtest.

## 8. Puzzle complexity

Puzzle complexity `C` is carried with producer length in `version`. It is
never miner-chosen: a validator derives it from parent history and requires an
exact match. `C` changes grammar width, example count and constraint tier;
it changes neither slot spacing nor the fixed header `bits`.

### 8.1 The signal

Per block, the relative margin between par and achieved length, in milli-units:

```text
m_i = clamp(floor(1000 * (par_i - L_i) / par_i), -1000, 1000)
```

### 8.2 The adjustment

Every 16 blocks:

```text
m_med = upper median of the 16 margins
f     = clamp(1000 + m_med - 100, 250, 4000)
C'    = clamp(floor(C * f / 1000), 16, 4095)
```

The target margin is 100 milli-units: median improvement 10% under par. This
is the only difficulty retarget; it changes puzzle complexity, not hashing or
time. A median avoids outliers and floating point. `C(0) = 128`; the first
adjustment is height 16 over heights 0..15, and reorgs recompute it from their
own history. Savings beyond the eight-byte score cap still enter this signal.

### 8.3 What difficulty cannot do

It cannot make validation more expensive. It moves example count, grammar
width and constraint tier, and it stops at a ceiling: `C = 4095` gives `k = 8`
and the full 24-production grammar. Section 11 discusses why that ceiling
exists and what it costs.

---

## 9. Co-op blocks and commit–reveal

A block's selected producer is not the only person who may have solved a
useful program. Co-op blocks can carry up to 8 signed shares from other
contributors, each paid out of the block's reward. The existing commitment,
personalization, validation, and payout rules are unchanged.

### 9.1 The problem, and why the pipeline is two blocks

The producer's own solution is necessarily revealed in the block that claims
it, and it cannot be committed in advance, because the puzzle for height `H`
does not exist until block `H-1` does. So a sharer needs a way to prove they
solved a puzzle without handing their program to whoever wins the block.

Commit–reveal, staggered across two heights:

| Block | Carries | For puzzle |
| --- | --- | --- |
| `H` | commitments and the producer's own solution | `H` |
| `H+1` | signed reveals and share payouts | `H` |

Each commitment is `SHA256d("SigilCoin/commit/1" || share_preimage || blind)`.
The blind is 32 bytes of the contributor's own choosing. It prevents an
attacker from confirming guesses about a hidden solution. The reveal publishes
the blind so every validator can recompute the commitment; once the solution
is public, the blind no longer needs to hide it.

The two-block stagger proves that the reveal's commitment was included in
its parent, before that reveal was carried on this branch. The personalized
task and signature bind the source to its payout key. This is not settlement:
a taller checkpoint-compatible branch may reorganize the commitment and reveal
together above the latest checkpoint. An "already extended" block is not final
merely because it has a child.

### 9.2 Personalized share work

The producer solves the global puzzle for height `P`. A share solves a distinct
public puzzle personalized by its compressed payout pubkey:

```
global_seed = seed(P)
share_seed  = SHA256d( "SigilCoin/share-puzzle/1"
                     || global_seed
                     || pubkey )
```

It uses the global puzzle's height, complexity, example count and constraint.
Its first `k-1` examples come from `share_seed`; the last is the mandatory
anchor pair:

```
input  = "@"
output = encode_ap(pubkey)
```

`encode_ap` maps each nibble of the full 33-byte compressed pubkey to `a` through
`p`, yielding an injective 66-character string. Ordinary generation reserves
`"@"`. Since a deterministic function has one output for that input, one source
cannot solve personalized puzzles for two keys. A share is valid only when its
source is **strictly shorter** than that personalized puzzle's par; equality is
`share-not-under-par`, not useful work.

The signed share binds that work to its branch and payout:

```
share_preimage = SHA256d( "SigilCoin/share/1"
                        || parent_prev_hash    the prev_hash that derived puzzle P
                        || u64le(P)
                        || u32le(C(P))
                        || SHA256d(solution)
                        || pubkey )
```

Each field is there to close one substitution. The parent hash and height pin
the share to one puzzle on one branch, so it cannot be replayed elsewhere.
`C(P)` pins the retarget epoch, so a reorg that changes difficulty invalidates
stale shares rather than silently repricing them. The solution hash pins the
program, so a producer cannot swap in a different one under a valid signature.
The pubkey pins the payout, since the payout script is derived from it.

What it deliberately does not bind is the including block. A share is valid in
*any* block at the right height on the right branch, which is what makes it a
share rather than a block-specific artifact, and lets any producer include it.

Shares are carried in the coinbase in strictly ascending pubkey order, which
is canonical, forces distinct payout keys, and makes duplicate detection a
linear scan. Duplicate solutions are rejected at the block level rather than
silently dropped, because "reject" is total and "drop" would need a
re-ordering rule; the producer controls what he includes, so he simply
includes one of any identical pair. Deduplication is on raw bytes, not on a
normalized AST: AST canonicalization is a large new consensus surface, and the
family of trivially-varied programs it would catch is better *paid* than
arbitrated.

Canonical order is not miner preference order. The reference miner fully
verifies every distinct eligible reveal, ranks it by contribution descending
with pubkey ascending as the tie-break, keeps at most eight, then sorts the
selected shares by pubkey for serialization.

### 9.3 Contributions and payouts

Each fully verified share contributes 1 through 4 according to its under-par
margin:

```text
margin_milli = floor(1000 * (personalized_par - L) / personalized_par)
contribution = 1 + min(3, floor(margin_milli / 50))
```

The aligned contributions price the share pool and order reveal candidates.
They do not change producer block score or fork choice.

Let `S` be scheduled subsidy and `F` fees. With no shares, the coinbase has one
unconstrained producer output:

```text
producer = floor(4*S/5) + F
```

The rest of `S` is not minted.

With one through eight shares, let `C` be the sum of their verified
contributions:

```text
carrier    = floor(S/20)
share_pool = floor(S/10)
share_i    = floor(share_pool * c_i / C)       independently
producer   = S + F - carrier - sum(share_i)
```

The cooperative coinbase mints exactly `S+F`. Fees and every floor-division
residual go to the producer, so 85% producer, 10% shares, and 5% carrier are
targets rather than exact percentages.

Output 0 is the producer, outputs `1..R` are P2WPKH scripts for shares in
canonical pubkey order, and output `R+1` is output 0's script from the parent
coinbase. Every required share and carrier output remains present even when
its value is zero. Thus `S<10` produces zero-valued share outputs, `S<20`
produces a zero-valued carrier, `S=1` mints zero solo but one cooperatively,
and `S=0` routes all fees to the producer.

For `S=5,000,000,000`, `F=0`, and contributions `(1,2,4)`, shares receive
`71,428,571`, `142,857,142`, and `285,714,285`; carrier receives
`250,000,000`; producer receives `4,250,000,002`, including the two-unit
residual.

The carrier output pays the parent producer a fixed 5% target once a valid
reveal exists. Fabricated commitments earn nothing, and carrying more
commitments does not multiply the output.

### 9.4 Unrevealed commitments

Nothing happens. A commitment that is never revealed expires when the next
block is accepted. There is no penalty, no refund, and no state beyond one
block: validating a block requires only the parent's commitment set, at most
16 hashes, which is already in the node's store. Commitment spam is bounded to
513 bytes per block. A miner may commit to several candidates and reveal the
best one, which is a feature.

### 9.5 A node-free public-testnet relay

The reference implementation provides an optional public-testnet relay
interface at `https://pool.testnet.sigilcoin.lol`. A contributor can run:

```sh
sigilcoin contribute --relay https://pool.testnet.sigilcoin.lol --testnet
```

The local watcher derives the personalized puzzle itself. It sends a
commitment and context-bound admission signature first, while the wallet key,
blind, and source remain local. Only after the commitment appears in canonical
block `H` does it sign and send the reveal for possible inclusion in `H+1`.
The watcher must stay running through that block or be resumed from its saved
commitment.

This relay is coordination, not protocol. Its first 16 authenticated distinct
pubkeys per context get relay slots, while the producer independently
revalidates work and chooses at most eight reveals by contribution before
serialization. Authentication does not stop one actor creating many keys, so
Sybil slot filling remains possible. A relay or producer may delay, omit, or
censor work, and a receipt is never an inclusion promise.

An included share creates a direct coinbase output for the signed payout
pubkey and becomes spendable in the following block under SigilCoin's one-block
maturity. The relay has no payout balance or private key and cannot redirect
that valid signed output. These are non-normative public-testnet operations; no
mainnet pool is offered or defined.

Consensus validity and wallet caution are separate. Mainnet nodes accept a
coinbase spend in the following block, but the bundled mainnet wallet does not
select that reward until it has six confirmations. Testnet and regtest keep
one-block selection for deliberate reorg and transaction testing.

---

## 10. Scheduled subsidy and actual issuance

The scheduled subsidy is a pure function of height, in daviwils
(`1 SGL = 100000000` daviwils):

```text
height 0        0                       genesis pays nothing
heights 1..30   1 SGL                   warmup
heights >= 31   floor(100 SGL / 2^floor((height - 1) / 730))
```

At mainnet's one-day scheduled spacing, 730 blocks span about two years of
chain timestamps; overdue blocks need not take that long to construct. The
shift is exact integer division, so height 24820 is the last height with a nonzero scheduled
subsidy. Summing the schedule gives **14302999991970 daviwils**
(143029.99991970 SGL). That is the scheduled maximum and an upper cap, not a
claim that every unit will be issued.

Actual issuance follows coinbase outputs. A solo block mints
`floor(4*S/5)` of subsidy; its remaining reserve is unminted. A cooperative
block mints the full `S`. Fees are transferred from existing inputs back
through coinbase and create no new supply. Because ordinary transactions
conserve value, the sum of active-chain UTXOs is the branch-aware issued
supply. The node prints that as `issued-supply` beside the current-height
`scheduled-supply-cap`. The explorer overview reports the same active issued
supply beside the scheduled lifetime maximum.

There is no premine or founder's reward. Genesis pays zero to an unspendable
`OP_RETURN`. SigilCoin coinbase outputs first become spendable in the following
block; Bitcoin's block-rules default remains 100, and the chain config selects
SigilCoin's one-block override. The warmup limits scheduled subsidy at the first
30 heights; it is not a requirement to spend a month constructing them.

There is no fee market. Fees remain because Bitcoin transactions have them and
the wallet pays a token amount by default; every fee reaches the producer
under both payout modes.

---

## 11. Validation cost

Worst case per block, at the frozen caps:

| Work | Bound |
| --- | --- |
| header checks | O(1) after puzzle derivation; no target comparison |
| block size | one serialization |
| coinbase decode | O(6583) bytes, five pushes and one re-encode; non-genesis at most 6186 |
| global puzzle derivation | at most 65 attempts x 20000 steps = 1.30 M steps, cached per height |
| personalized puzzle derivation | 8 x 65 x 20000 steps = 10.40 M steps |
| producer solution | 200000 steps on one machine |
| share solutions | 8 x 200000 steps |
| signature verification | 8 ECDSA |
| transactions | Bitcoin's existing cost |

Historical measurements estimated about 5.5 microseconds per puzzle-language
step: roughly 74.3 seconds at the uncached ceiling, or 0.1% of a mainnet slot.
The historical sample's typical evaluator cost was around 1.65 ms, with
roughly 300 steps and 80 cells. These are not newly measured replacement-network
results or a bound on adversarial sibling traffic. The global puzzle is cached
across same-parent siblings; personalized specs are reused during validation.

Two rules keep that bound real.

**Derivation is cached by branch context.** Same-parent siblings with the same
derived complexity use the same puzzle. Its seed encodes the parent hash,
height, and complexity, relying on hash collision resistance. The cache is
correctness-neutral: a node that never hits it validates the same chain, slower.

**Validation is ordered cheapest-first, and that ordering is a requirement.**
After size, merkle, header, and canonical payload checks, the node performs
cheap share shape/order/commitment checks, derives fees, and checks the payout
shape before source preparation, signatures, or PBE. A solo payout must already
equal `floor(4*S/5)+F`; a cooperative payout must have `R+2` outputs, canonical
scripts, carrier `floor(S/20)`, and total `S+F`.

Only then are personalized sources prepared, signatures verified, the producer
executed, and each share executed exactly once. Verified contributions feed
the exact payout check. A malicious proportional allocation with correct cheap
shape and total is therefore rejected after
share verification; malformed shape or total runs no PBE. The transaction
connector remains last because it mutates the UTXO set it is handed.

One integration rule is worth stating in public, because getting it wrong
produces a node that rejects every valid block: **never call Bitcoin's block
connector directly on a SigilCoin block.** It enforces Bitcoin's 100-byte
coinbase scriptSig cap and Bitcoin's subsidy schedule, and a SigilCoin
coinbase payload codec allows up to 6583 bytes. SigilCoin's own rules record must be
passed into the connector.

---

## 12. Software

**Node.** `sigilcoin` opens a chain the same way a Bitcoin node does: the
SigilCoin rules record travels in the chain config's extensions, so nothing in
`sigil-bitcoin` needs to know what a puzzle is. Headers-first sync, block relay,
and peer management remain Bitcoin-shaped. State is SQLite in a data
directory. Three replacement networks retain separate configurations:
mainnet with 86400-second slots, public testnet with 3600-second slots, and
disposable regtest with 1-second slots. All require the exact parent-relative
timestamp and zero future drift.

Each replacement network begins at its newly generated genesis. Old databases
and histories are archived, never reused; deploy into fresh
`state/*-proof-of-golf` directories. The software must not delete operator
archives. Current network definitions and the all-network generator supply
genesis identities, not the superseded launch record.

**Wallet.** Keys, bech32 addresses with HRP `sgl` (so addresses read `sgl1…`),
balance and spending, in the CLI. The key lives in the node's data directory
and is the operator's to back up.

**Explorer.** A read-only HTTP site over the node database: chain summary,
block list, block detail with puzzle, claimed length, par, savings, block score
and cumulative chain score, shares and payouts, address pages, puzzle-complexity
history, and JSON endpoints. The JSON `golf` object contains `claimed_length`,
`par`, `savings`, `block_score`, and `chain_score`. Scores report competition
quality, not fork weight or current subsidy. There are no hash-odds or
lottery-target claims.

Summary issued supply is the active-UTXO aggregate; scheduled maximum remains
a separate cap. List pages never execute share programs. A detail page may run
the public share checker to preview verified contributions and expected
payouts, but omits the comparison if any preview fails or inferred fees would
be negative. It never uses node validation caches, writes state, or trusts
producer text: displayed sources and genesis markers are sanitized and escaped.

**Deployment.** A NixOS module for the seed node, low-CPU scheduled producer,
and explorer, with the node holding its own port and the explorer bound to
loopback behind a reverse proxy. The producer builds once for the slot instead
of continuously hashing. Operational detail is in `deploy/RUNBOOK.md`;
`LAUNCH.md` is the explicitly superseded record of the retired nonce-PoW launch.

---

## 13. What measurement contributed

The following surveys and timing observations are historical input to the
puzzle design, not newly run evidence for scheduled proof-of-golf. They do
not establish security or production behavior of the replacement networks.

**The puzzle asks for a function because measurement required it.** A survey
of 480 one-output synthesis cases found **78.3%** of best known answers were
quoted literals: mining reduced to transcription. Requiring a one-argument
function over several examples removes that trivial answer and exposes
structure worth synthesizing. The same survey found execution metrics at
0.03% of the fuel cap and 0.08% of the allocation cap, supporting fixed,
bounded verification.

**The example count is 8 because executable bounds beat estimates.** Tightening
reduces each added table branch to 16 fixed bytes. Ten global examples fit at
496 bytes under the widest repair but leave only 16 bytes of source headroom.
The shared cap remains 8, with exact global and personalized bounds of 400 and
443 bytes.

**Candidate availability is verified, not argued.** The generator does not rely
on size arithmetic alone. Every accepted puzzle has both generated witnesses
wrapped, lexically tightened, measured, parsed, constraint-checked, and
executed against every published pair under the real consensus caps. This
guarantees an eligible at-par program without claiming any expended effort.

The same discipline runs through the rest: additive score, margins, and
payouts use exact integer arithmetic with explicit floors; the generator
budget is charged against real evaluator steps; the coinbase codec re-encodes
and compares to reject non-minimal pushes and trailing bytes. The old
simulation's measured outcomes remain historical, as explained in
[`simulation.md`](simulation.md); they are not a replacement-network run.

---

## 14. Limitations

These are design limitations, not promises to fix them with future hashing.

**Automation dominates, by design.** A puzzle that consensus can verify is a
puzzle a script can optimise. There is no way to keep the first property and
lose the second, and no attempt is made to. More pointedly: at this problem
scale a classical bottom-up synthesizer with observational-equivalence pruning
may well beat a language model, in which case the chain is a benchmark for
superoptimizers rather than for models. That would be a fine outcome and it is
not the advertised one. Retargeting responds to published producer programs:
the median margin moves `C`. It does not make the shortest program's branch
canonical or favor whatever is most interesting.

**Without identity, automation shapes the competition.** Permissionless
participation does not ensure parity between human and automated golfers.
One actor may control all eight payout keys; consensus proves eight
personalized solutions, not eight people. A person writing programs by hand
may lose the golf or contribution competition to automated search. Neither
better producer score nor more search effort grants extra fork-choice weight.

**Payout keys can be ground.** Personalized puzzles prevent one source from
being replayed under several keys, but keys are free to generate. A miner can
sample pubkeys, derive their public puzzles, and work only on unusually easy
ones. The full-key anchor binds every chosen source to that key but does not
make key selection scarce. Contribution-ranked reveal selection and payout
remain susceptible to key sampling; contribution does not affect producer
block score or fork choice.

**The complexity ceiling is finite.** `C` raises example count, grammar width,
and constraint tier, never a hash target. Every published puzzle has a verified
table witness within the 512-byte source cap and a par witness no longer than
that table. A score-1 fallback is always available for an otherwise valid
scheduled block. The example count is frozen at 8; at `C = 4095` there is
nothing left to widen. If solvers saturate the grammar, the current protocol
cannot raise complexity further; raising the cap changes consensus.

**The retarget signal is producer-influenced.** A producer chooses which valid
source to submit. Publishing a longer source can hold `C` down. The direct
score cost is linear only where it changes capped savings: each lost saved
byte costs one point until reaching score 1. Length changes that leave at least
eight saved bytes cost no score at all. That cost is displayed quality only,
not fork weight or subsidy. There is no in-protocol detection of withheld
optimization.

**A producer can silently omit others' commitments.** The producer chooses
what the block carries. A later carrier output rewards a commitment path, but
share quality cannot improve fork position. Omitting commitments may forgo a
future carrier output or current share participation; it is not forbidden.
Repeated production or a replacement branch can repeat censorship. No
commitment-count retarget or additional anti-censorship rule is implemented.

**The producer's own program can be copied.** It is public in the block that
claims it. A sibling with the same parent can reuse that source for the same
score without searching a new hash. Equal height preserves the receiving
node's incumbent, not the original author's rights. A shorter replacement
program improves displayed quality but cannot win on that basis. A branch
must become strictly taller and remain checkpoint-compatible to replace it.

**The payout policy is a guess.** Solo minting targets 80%. Cooperative blocks
target 85% for the producer, divide 10% by contributions, pay 5% to the parent
carrier, and route fees and integer residuals to the producer. Exact validation
binds payouts but does not establish incentives or independent ownership.
Changing those percentages changes consensus.

**The puzzle-complexity window is short.** `C` adjusts every 16 blocks using
median margin and a clamp. That is prompt feedback, not evidence of stable
economic behavior. There is no timestamp-driven hash retarget to stabilize or
measure, and no replacement-network equilibrium result is claimed here.

**Alternative histories are cheap to build.** Old puzzles and solutions are
public. Changing an old block changes subsequent puzzles, but descendants can
be rebuilt from available witnesses without hash search. Past slots are
already time-eligible. Extra golf score cannot make a shorter or equal-height
branch win; a replacement must become strictly taller, for example after a
missed slot or during a partition, and match all reached release checkpoints.
Reorgs remain possible above the latest checkpoint: H0 on all networks.
Advancing that boundary requires a reviewed software release and node upgrades.

**Equal-height forks remain local.** Equality retains each node's durable
active incumbent, regardless of score, hash, or arrival metadata. Nodes that
adopted different equal-height branches can stay split. A later height advantage
can resolve that comparison but does not finalize ancestors above the latest
checkpoint or guarantee convergence while partitions persist.

**Parent-template manipulation remains possible.** Fixed time, zero nonce,
empty non-genesis graffiti, and fixed coinbase metadata remove obvious
cursors. They do not remove valid choices of producer program, payout script,
transactions and their order, commitments, or reveals. Those choices change
the parent's hash and thus the next puzzle. The reference producer builds one
complete candidate; consensus cannot prove that a participant never sampled
alternatives.

**This is not settlement-grade security.** The nonce-PoW launch was retired
before any post-genesis block because its compute burn contradicted the
project's intent. The replacement deliberately forgoes a hash-expenditure
barrier; fixed pow-limit bits are not a measured security target. Historical
rehearsals and simulations do not validate the new networks. Do not depend on
this hobby chain for exchanges, bridges, payment settlement, or valuable
balances.

---

## 15. Protocol cutover

The replacement contract is scheduled proof-of-golf from height 0: generated
par witnesses; producer `L <= par` and share `L < personalized_par`; displayed
quality of one point plus at most eight points for saved bytes, genesis score
zero; strict longest-height fork choice with a durable active incumbent on
equal height; hardcoded release checkpoints; exact network slots with zero
future drift; zero nonce; canonical non-genesis coinbase metadata; and fixed
compatibility `bits`. Golf score does not select branches or currently alter
subsidy.

Puzzle VM caps, branch-derived complexity retargeting, co-op commitments and
signed payouts, ordinary transactions, and header serialization remain. Old
nonce-lottery APIs and validation are removed, not retained as aliases or a
second mode. Current generated genesis constants identify each replacement
network. No archived nonce-PoW database may be reused as that network's state.

The authorized mainnet slogan reset changes its genesis identity and transport
magic to `SGM4`, retaining timestamp `1789228800`. Archive the abandoned
marker-quote mainnet chain and relay state and start with fresh state; its H0
database may not be reused. Testnet and regtest retain their genesis identities,
timestamps, and `SGT3` / `SGR3` transport magic; their existing proof-of-golf H0
state may be reused. Mainnet now pins slogan-chain H0 and H1; public testnet
and regtest remain H0-only. Later checkpoints require reviewed releases and
node upgrades.

This document specifies the cutover; it does not claim a new validation run,
deployment soak, or security result.

## 16. Constants

| Constant | Value |
| --- | --- |
| solution source cap | 512 bytes |
| fuel per solution | 200000 steps |
| allocation cap | 400000 cells |
| string cap | 65536 bytes |
| eval / parse depth | 128 / 64 |
| integer magnitude | < 2^256 |
| builtins / special forms | 41 / 7 |
| example count `k` | 3..8 |
| grammar width `w` | 6..24 of 24 productions |
| ordinary input / output literal cap | 8 / 24 bytes |
| personalized anchor | `"@"` -> 66-character full-pubkey encoding |
| share contribution | 1..4 per verified share |
| minimum par | 24 bytes |
| producer validity | `L <= par` |
| share validity | `L < personalized_par` |
| generator retries | 64, then a frozen fallback |
| generator budget | 20000 steps per attempt |
| constraints | 8, tiers `(0)`, `(0 1 3 5)`, `(1 2 4 6 7)` |
| builtin cap `D` | 6, or 4 at tier 2 |
| complexity `C` | 16..4095, genesis 128 |
| complexity retarget | 16 blocks, target margin 100 milli-units |
| hash target validation / search / retarget | none |
| exact slot spacing main/test/reg | 86400 / 3600 / 1 seconds |
| fixed pow-limit bits main/test/reg | `0x1c2bcf04` / `0x1f00ffff` / `0x2000ffff` |
| `coin-golf-max-savings` | 8 bytes |
| non-genesis block score / genesis score | 1..9 / 0 |
| header version | prefix/mask `0x20600000` / `0xffe00000`; `L-1` in 20..12, `C` in 11..0 |
| `bits` | fixed per-network compatibility field |
| `nonce` | 0 |
| fork choice | strictly taller valid branch; equal height retains durable active incumbent |
| checkpoints | hardcoded reviewed release pairs; mainnet slogan-chain H0 + H1, public testnet/regtest H0 only |
| transport magic main/test/reg | `SGM4` / `SGT3` / `SGR3` |
| non-genesis coinbase version / sequence / lock time | 1 / `0xffffffff` / 0; no witness |
| max shares / commitments | 8 / 16 |
| payout | solo `floor(4*S/5)+F`; cooperative 10% weighted shares, 5% carrier, producer residual |
| coinbase scriptSig | codec 8..6583 bytes; non-genesis at most 6186 |
| graffiti | empty for non-genesis; codec cap 400 bytes for genesis marker |
| block size cap | 16384 bytes |
| non-genesis timestamp | exactly parent time + network slot spacing |
| future drift / median time span | 0 seconds / 11 blocks |
| coinbase maturity | 1 block |
| daviwils per SGL | 100000000 |
| warmup | heights 1..30 at 1 SGL |
| reward / halving | 100 SGL, halving every 730 blocks |
| last paying height | 24820 |
| scheduled maximum supply | 14302999991970 daviwils |
| address format | bech32, HRP `sgl` |
| replacement network identities | current network definitions and all-network genesis generator |
| protocol version / user agent | 70015 / `/sigilcoin-node:0.1.0/` |
| genesis hashes | regenerated together from each network's current header rules |

---

SigilCoin is a joke with a test suite. Both halves are meant.
