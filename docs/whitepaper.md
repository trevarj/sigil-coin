# SigilCoin

A blockchain whose proof of work is program synthesis.

SigilCoin is a toy chain for the Sigil community. It is worth nothing, it is
intended to stay worth nothing, and there is no premine. What it is not is
careless: consensus rules are as tight as a real chain's, because a joke
currency that forks on a rounding error is not funny, it is just broken.

[`consensus.md`](consensus.md) is the sole normative protocol specification.
This paper explains motivation and design; where prose differs from that
specification, `consensus.md` governs.

The chain is built on the `sigil-bitcoin` libraries and keeps Bitcoin's
80-byte header, transaction format, UTXO set and script engine. It replaces
one thing: hash proof of work. In SigilCoin, each block publishes a
deterministically generated puzzle — a set of input/output pairs plus a
syntactic constraint — and a block is won by publishing the shortest program
that reproduces every pair. Sigil is itself a language whose implementation
was written by a language model, and the chain leans into that: mining by
model or by script is the intended mode of play, not an exploit to defend
against.

---

## 1. What the chain is for

Hash mining is a machine that converts electricity into a number nobody wants
to read. It works, it is fair, and it says nothing. SigilCoin asks the same
question a proof of work asks — "did you do the work?" — about an artifact a
human or a model can actually look at: a small program.

Three properties made this worth building rather than describing.

**The work is legible.** A winning block carries a program, at most 512 bytes
of it, that anyone can read and re-run. "Who won today, in how many bytes" is
a question with a satisfying answer, which is the entire social point of the
chain.

**The work is verifiable and cheap to check.** Verification is a bounded
evaluation, not a search. A node re-runs the winner's program against the
published examples under fixed resource caps and gets a yes or a no in
milliseconds. Finding a short program is hard; checking one is not. That
asymmetry is what a proof of work is.

**The work is not electricity.** A miner spends thought, or model tokens, or
CPU on a synthesizer. A laptop can win a block. That is a deliberate departure
from the security model of a chain protecting value, and it is the correct
trade for a chain protecting nothing.

What SigilCoin does not claim: that it is money, that it is secure against a
well-resourced adversary, or that program golf is a fairer distribution
mechanism than hashing. It is one community's toy, with the engineering done
properly.

---

## 2. What is inherited and what is replaced

Inherited from `sigil-bitcoin`, unmodified:

- the 80-byte block header, its serialization and its double-SHA256 hash
- transactions, the UTXO set, value conservation and coinbase maturity
- the script engine, P2WPKH addresses and signature rules
- the peer-to-peer wire protocol, headers-first sync and block relay

Replaced entirely:

- proof of work. No header is ever hashed against a target. Nothing in the
  chain calls a difficulty-retarget function derived from hashing.
- the meaning of three header fields. `version` is pinned to 5, `bits` carries the
  difficulty parameter, and `nonce` carries a composite score word.
- fork choice. Chain quality is program quality, not accumulated hashes.

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
- **Determinism of cost.** The score ranks solutions partly by the steps and
  the memory they use. Those numbers must be identical on every machine, on
  every build, forever. A host evaluator's cost is an implementation detail of
  the host.
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

The allocation counter is the interesting one, because it is what makes the
memory term of the score meaningful rather than decorative. A *cell* is one
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
id. Every integer is fixed-width little-endian, so the preimage is injective:
no two `(prev_hash, H, C)` triples share a seed. `C(H)` is the difficulty
parameter of section 8; folding it in means a retarget changes the puzzle, so
nobody can precompute solutions across a retarget boundary. `C(H)` is derived
from the parent chain, never read from the candidate header, so a block cannot
choose its own puzzle by lying about its difficulty.

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
5. Set `par` to the shorter tightened source length. Reject if either source
   falls below the 24-byte minimum par floor.

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

`par` is an upper bound on the true optimum and never a lower one. A miner may
find something shorter; no computable check can rule that out, and finding
those programs is the game.

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

A candidate solution is a byte string `s` with `1 <= |s| <= 512`. It is
checked in this order, first failure winning:

| # | Check | Rejection |
| --- | --- | --- |
| 1 | bytes or string | `solution-malformed` |
| 2 | `1 <= |s| <= 512` | `solution-oversize` / `solution-malformed` |
| 3 | the day's constraint, source half | `constraint-violated` |
| 4 | parses | `solution-parse-failed` |
| 5 | the day's constraint, AST half | `constraint-violated` |
| 6 | evaluates to a value | `solution-eval-failed` |
| 7 | the value is a 1-arity procedure | `solution-not-a-procedure` |
| 8 | every example reproduced, in draw order | `solution-mismatch` |
| — | anything raises | `internal-error` |

The order is cost, not taste: an `O(|s|)` byte scan precedes a parse, which
precedes the only step whose cost is interesting.

**One machine per solution.** Parsing, evaluation and all `k` applications
share a single machine with one 200000-step budget and one allocation counter.
This is load-bearing twice. Total validation cost for a solution is bounded by
one fuel budget *regardless of `k`*, so raising the example count through the
retarget cannot raise node cost. And `steps` and `cells` become single
well-defined numbers, which is what the score packs.

Bare builtins are legal solutions — `car` is three bytes — and the generator's
degeneracy probe guarantees no published puzzle is solved by one.

`par` is not a bound on a solution. Shorter than par is legal, expected, and
the point. Par exists only to feed the retarget signal.

---

## 6. Liveness: the table solution

A generated puzzle that nobody can solve would stall the chain permanently.
The chain therefore guarantees, for every height, every constraint, and every
complexity, a solution that any miner can construct mechanically from public
data.

A miner has the parent header, hence `prev_hash`, `H`, and `C(H)`, hence the
seed and the whole puzzle. Running the same generator every validator runs
yields the examples, constraint, tightened hidden source, tightened table
source, and par.

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

### 6.1 Executable liveness bound

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
may be published. Liveness is verified on every accepted puzzle.

### 6.2 What the table means for the game

The table is always an available mechanical solution, but not necessarily the
shortest generated witness: `par` is the minimum of the verified hidden and
table lengths. Structural programs can beat par; overlong transcription remains
legal for a producer but ranks worse, and shares must be strictly under their
personalized par.

Tests and tools do not manufacture useful shares by deleting whitespace from a
generated witness. A deterministic semantic fixture exists only when every
ordinary personalized example input is non-string: replace the exact tight
anchor predicate `(equal? x"@")` with `(string? x)`, run the production share
checker, and keep it only if it is strictly shorter than par. A specification
with an ordinary string input has no such candidate.

Genesis is built rather than mined and carries the table solution of the
frozen genesis puzzle. It is a real, verifiable block whose program reproduces
its examples. Its reward is zero and its single output is an unspendable
`OP_RETURN`: no premine.

## 7. Scoring and fork choice

### 7.1 The authenticated score word

The header has no spare room, and none is asked for. Three fields are
repurposed: `version` is pinned to 5, `bits` carries the difficulty parameter
(section 8), and `nonce` carries a 32-bit score word `W`.

```text
bit  31              22 21     15 14      8 7    4 3    0
    +------------------+---------+---------+------+------+
    |      L - 1       |   MB    |   SB    |15-Q  | 0000 |
    +------------------+---------+---------+------+------+
       10 bits           7 bits    7 bits   4 bits 4 bits
```

- `L` is the producer source length,
- `MB` and `SB` bucket its verified memory cells and steps,
- `Q` is authenticated aggregate share quality in `0..15`,
- the low nibble is reserved zero.

The raw word remains:

```text
W = (L-1)<<22 | MB<<15 | SB<<8 | (15-Q)<<4
```

It commits the body and exposes `Q` for reporting, but fork choice never
compares it raw. Consensus projects the rank word:

```text
RW = W & 0xffffff0f
```

Lower `RW` is lexicographic order `(L, MB, SB)`. Clearing bits 7..4 makes `Q`
rank-inert while retaining its authenticated body commitment and its role in
contribution reporting. The reserved low nibble leaves no free header entropy.

### 7.2 Bucketing

Cells (0..400000) and steps (0..200000) do not fit seven bits. They are
bucketed at six buckets per octave — about 12.2% resolution — with exact
integer arithmetic and no logarithm, because a floating-point log is a
divergence risk on a number every node must agree on to the bit:

```
T = (1000, 1122, 1260, 1414, 1587, 1782)      floor(1000 * 2^(i/6))

bucket7(x) = 0                                        if x = 0
           = min(127, 1 + 6*kk + j)                   otherwise
  where kk = floor(log2 x) and j = |{t in T : t*2^kk <= 1000x}| - 1
```

`bucket7(1) = 1`, `bucket7(2) = 7`, `bucket7(300) = 50`, `bucket7(340) = 51`,
`bucket7(400000) = 112`, `bucket7(200000) = 106`.

The bucketed values are consensus values. Fork choice compares projected rank
words, so two producer solutions in the same `(L, MB, SB)` buckets are exactly
tied regardless of authenticated `Q`. There is no finer body order that could
drift out of agreement with the header.

### 7.3 The header-to-body commitment

`W` is a claim. Body validation recomputes it from the validated body and
requires exact equality; a mismatch is `score-mismatch` and the node marks the
header and every descendant permanently invalid. The check bites in both
directions, because `W` is an equality and not a bound: understating a
solution's length claims a better block than the one carried, and overstating
it is equally a lie.

That equality makes header-first ranking safe: headers can be ordered
provisionally before bodies arrive, but a false claim becomes an invalid block
and poisons its descendants when the body is checked.

### 7.4 Fork choice and settlement

```text
b1 is a better tip than b2 iff height(b1) > height(b2)
                              or (equal height and RW(b1) < RW(b2))
```

At equal height and equal projected rank, neither sibling replaces the other.
The first valid arrival remains incumbent; neither raw `W`, `Q`, nor block hash
breaks the tie. A child must be at the next height and link to the selected
incumbent. Once that child is observed, the parent's height is settled and
later siblings cannot replace it.

The persisted chain key uses the same projection:

```text
saving(W) = 2^32 - (W & 0xffffff0f)
work      = accumulated * (2^32 + 1) + saving
```

The `Q`-neutral saving keeps database ranking identical to direct comparison.
Status may recover producer length from the projected rank, but cannot infer
quality because those bits were deliberately cleared.

There is no block-hash tie-break. Such a tie-break would be grindable through
coinbase graffiti, while an exact rank tie is deliberately local first-seen
arrival behavior until child settlement.

## 8. Difficulty

Difficulty is the complexity parameter `C`, carried in `bits` as
`0x207F0000 | C` with the middle nibble required to be zero. The prefix keeps
the value at or below `0x207fffff`, so any Bitcoin-derived reader that
misinterprets the field sees a maximum-target compact number, i.e. "no work
required" — which is true.

`C` is never miner-chosen. A validator derives it from the parent chain and
requires the header to match exactly; the field exists so that a node ranking
a flood of headers can check it in constant time and derive puzzles without
walking back.

### 8.1 The signal

Per block, the *relative* margin between par and what the miner achieved, in
milli-units:

```
m_i = clamp( floor(1000 * (par_i - L_i) / par_i), -1000, 1000 )
```

Relative, because par varies by puzzle: an absolute "beat par by N bytes"
threshold would reward the same proportional improvement differently at
different heights. Division floors toward negative infinity, so negative
margins are unambiguous.

### 8.2 The adjustment

Every 16 blocks, over the full window of the preceding 16 heights:

```
m_med = upper median of the 16 margins (sorted, index 8)
f     = clamp(1000 + m_med - 100, 250, 4000)
C'    = clamp(floor(C * f / 1000), 16, 4095)
```

The target is 100 milli-units: the median accepted solution 10% under par,
which is roughly what a structural golfer achieved in the survey that
calibrated it. A median above that raises `C`; below, it lowers it. The clamp
is Bitcoin's symmetric 0.25x..4x per window. Only the lower bound can actually
fire — the margin domain puts the raw factor in `[-0.1, 1.9]` — and it is
load-bearing, not decorative: without it, a window of miners who all missed
par badly would drive the factor to zero and collapse `C` in one step.

A median, not a mean: the result is always one of the observed values, so no
rounding rule is needed and no single outlier moves it. Sixteen blocks is
about 13 days at mainnet spacing; Bitcoin's 2016 would be 4.6 years at
one block a day, which is not feedback.

`C(0) = 128`. The first retarget is at height 16 over the complete window
0 through 15, including genesis, whose par is well defined. A reorg recomputes
`C` from the new branch's own 16 blocks.

### 8.3 What difficulty cannot do

It cannot make validation more expensive. It moves example count, grammar
width and constraint tier, and it stops at a ceiling: `C = 4095` gives `k = 8`
and the full 24-production grammar. Section 11 discusses why that ceiling
exists and what it costs.

---

## 9. Co-op blocks and commit–reveal

A one-winner-per-day chain wastes almost all the work done on it. Nine people
can solve a puzzle and eight get nothing. Co-op blocks are the answer: a block
may carry up to 8 signed shares from other miners, each paid out of the
block's own reward.

### 9.1 The problem, and why the pipeline is two blocks

The producer's own solution is necessarily revealed in the block that claims
it, and it cannot be committed in advance, because the puzzle for height `H`
does not exist until block `H-1` does. So a sharer needs a way to prove they
solved a puzzle without handing their program to whoever wins the block.

Commit–reveal, staggered across two heights:

| Block | Carries | For puzzle |
| --- | --- | --- |
| `H` | commitments | `H` |
| `H` | the producer's own solution | `H` |
| `H+1` | reveals and share payouts | `H` |

A commitment is `SHA256d(tag || share_preimage || blind)` where the blind is
32 bytes of the miner's own choosing. The reveal carries the blind so every
validator can recompute the commitment. It remains secret while hiding matters,
then becomes public with the solution. Without it, a guessable solution could
be confirmed before reveal.

The two-block stagger is what protects a revealed share. A reveal for puzzle
`P` is published in a block at height `P+1`. To steal it, a thief would have
to mine a sibling of block `P` — but height `P` is already extended by the
very block that carried the reveal, so the "live beats settled" rule refuses
to displace it. **The reveal is safe precisely because publishing it requires
a block that settles its height.**

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
Q            = min(15, sum(contribution))
```

The aligned contributions price the share pool. Capped `Q` remains committed
in the raw header word for authentication and reporting, but never changes
fork-choice rank.

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

---

## 10. Scheduled subsidy and actual issuance

The scheduled subsidy is a pure function of height, in daviwils
(`1 SGL = 100000000` daviwils):

```text
height 0        0                       genesis pays nothing
heights 1..30   1 SGL                   warmup
heights >= 31   floor(100 SGL / 2^floor((height - 1) / 730))
```

At roughly one block a day, 730 blocks is about two years. The shift is exact
integer division, so height 24820 is the last height with a nonzero scheduled
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
`OP_RETURN`, and coinbase outputs mature after 100 blocks. The warmup limits
the scheduled subsidy while the first month of a new chain is debugged.

There is no fee market. Fees remain because Bitcoin transactions have them and
the wallet pays a token amount by default; every fee reaches the producer
under both payout modes.

---

## 11. Validation cost

Worst case per block, at the frozen caps:

| Work | Bound |
| --- | --- |
| header checks | O(1) |
| block size | one serialization |
| coinbase decode | O(6588) bytes, five pushes and one re-encode |
| global puzzle derivation | at most 65 attempts x 20000 steps = 1.30 M steps, cached per height |
| personalized puzzle derivation | 8 x 65 x 20000 steps = 10.40 M steps |
| producer solution | 200000 steps on one machine |
| share solutions | 8 x 200000 steps |
| signature verification | 8 ECDSA |
| transactions | Bitcoin's existing cost |

At about 5.5 microseconds per puzzle-language step, the uncached ceiling is
roughly 74.3 seconds, about 0.1% of the 72000-second spacing floor. The global
puzzle is cached across sibling blocks at one height; personalized share specs
are derived once and reused within each block validation. Typical evaluator
cost is around 1.65 ms: measured puzzles used roughly 300 steps and 80 cells.

Two rules keep that bound real.

**Derivation is cached per `(prev_hash, height)`.** Every sibling at a height
is judged against the same puzzle, so the expensive step is paid once. The
cache is keyed on the seed, which is injective over the triple, and it is
correctness-neutral by construction: a node that never hits it validates the
same chain, slower.

**Validation is ordered cheapest-first, and that ordering is a requirement.**
After size, merkle, header, and canonical payload checks, the node performs
cheap share shape/order/commitment checks, derives fees, and checks the payout
shape before source preparation, signatures, or PBE. A solo payout must already
equal `floor(4*S/5)+F`; a cooperative payout must have `R+2` outputs, canonical
scripts, carrier `floor(S/20)`, and total `S+F`.

Only then are personalized sources prepared, signatures verified, the producer
executed, and each share executed exactly once. Verified contributions feed
both authenticated `Q` and the exact payout check. A malicious proportional
allocation with correct cheap shape and total is therefore rejected after
share verification; malformed shape or total runs no PBE. The transaction
connector remains last because it mutates the UTXO set it is handed.

One integration rule is worth stating in public, because getting it wrong
produces a node that rejects every valid block: **never call Bitcoin's block
connector directly on a SigilCoin block.** It enforces Bitcoin's 100-byte
coinbase scriptSig cap and Bitcoin's subsidy schedule, and a SigilCoin
coinbase scriptSig runs to 6588 bytes. SigilCoin's own rules record must be
passed into the connector.

---

## 12. Software

**Node.** `sigilcoin` opens a chain the same way a Bitcoin node does: the
SigilCoin rules record travels in the chain config's extensions, so nothing in
`sigil-bitcoin` needs to know what a puzzle is. Headers-first sync, block relay,
and peer management remain Bitcoin-shaped. State is SQLite in a data
directory. Three chains ship: mainnet on port 19444; reset public testnet on
19446 with one-hour minimum spacing and five-minute future drift; and
disposable regtest on 19445 with one-second spacing.

The reset public testnet begins at a new genesis marked
`SigilCoin public testnet reset - 2026-09-02` at timestamp `1788307200`.
Previous public-testnet databases and history are incompatible. Operators must
archive or move an old directory and start with an empty one; the software
never deletes operator state automatically.

**Wallet.** Keys, bech32 addresses with HRP `sgl` (so addresses read `sgl1…`),
balance and spending, in the CLI. The key lives in the node's data directory
and is the operator's to back up.

**Explorer.** A read-only HTTP site over the node database: chain summary,
block list, block detail with puzzle, score decomposition, shares, and payouts,
address pages, difficulty history, and JSON endpoints. Summary issued supply is
the active-UTXO aggregate; scheduled maximum remains a separate cap. List pages
never execute share programs. A detail page may run the public share checker to
preview verified contributions and expected payouts, but omits the comparison
if any preview fails or inferred fees would be negative. It never uses node
validation caches, writes state, or trusts miner text: graffiti and source are
sanitized and escaped.

**Deployment.** A NixOS module for the seed node and the explorer, with the
node holding its own port and the explorer bound to loopback behind a reverse
proxy. Operational detail is in `deploy/RUNBOOK.md`; the launch gate is in
`LAUNCH.md`.

---

## 13. What measurement contributed

Three design decisions came from measuring rather than reasoning, and it is
worth saying which.

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

**Liveness is verified, not argued.** The generator does not rely on size
arithmetic alone. Every accepted puzzle has both generated witnesses wrapped,
lexically tightened, measured, parsed, constraint-checked, and executed against
every published pair under the real consensus caps. The documented bound is
explanation; the executable check is the guarantee.

The same discipline runs through the rest: buckets and margins are exact
integer arithmetic with explicit floors because a float would diverge; the
generator's own budget is charged against real evaluator steps rather than
estimated; the coinbase codec closes with a re-encode-and-compare that rejects
non-minimal pushes and trailing bytes in one line.

---

## 14. Limitations

This section is the honest part. None of it is hypothetical.

**Automation dominates, by design.** A puzzle that consensus can verify is a
puzzle a script can optimise. There is no way to keep the first property and
lose the second, and no attempt is made to. More pointedly: at this problem
scale a classical bottom-up synthesizer with observational-equivalence pruning
may well beat a language model, in which case the chain is a benchmark for
superoptimizers rather than for models. That would be a fine outcome and it is
not the advertised one. Retargeting self-balances either way — whoever is
winning, the median margin rises and `C` follows — but it balances toward
whatever is strongest, not toward whatever is most interesting.

**Without identity, effort decides.** Permissionless participation,
identity-free mining, and rough parity between a human and an automated miner
cannot all hold at once. This chain chose the first two, which means the third
is gone. One actor may control all eight payout keys; consensus proves eight
personalized solutions, not eight people. A person writing programs by hand
will lose to someone who leaves a search running, exactly as a CPU miner loses
to an ASIC.

**Payout keys can be ground.** Personalized puzzles prevent one source from
being replayed under several keys, but keys are free to generate. A miner can
sample pubkeys, derive their public puzzles, and work only on unusually easy
ones. The full-key anchor binds every chosen source to that key but does not
make key selection scarce. `Q <= 15` caps the authenticated report, not
fork-choice benefit; contribution-ranked reveal selection and payout remain
susceptible to key sampling.

**The difficulty ceiling is finite.** `C` raises example count and grammar
width, but every published puzzle must carry a fallback table that fits the
512-byte source cap, and the table grows with the example count. That is why
the count is frozen at 8, and it is a hard bound on how far difficulty can
climb: past `C = 4095` there is nothing left to widen. If a solver saturates
the grammar, the chain has no answer inside the current parameters. Raising
the cap is a chain split.

**The retarget signal is miner-influenced.** The margin is computed from the
accepted solution's length, and the miner chooses what to submit. A miner who
finds a 40-byte program can publish a 60-byte one to hold difficulty down.
What it costs him is the block: a worse program is a worse score and loses to
any competitor who submits their best. The manipulation is real, it is
self-financed, and there is no in-protocol detection of it.

**A block producer can silently omit others' commitments.** He chooses what
his block carries. A later carrier output pays the parent producer to make
commitment paths available, but authenticated quality cannot break a rank tie.
The censor controls one height and may forgo a future carrier output or current
share participation; there is no further in-protocol defence. If censorship
shows up, making commitment count a soft retarget input may be the cheapest
response. That is not built and should not be until behavior is observed.

**The producer's own program can be copied.** It is revealed in the block that
claims it and cannot be committed in advance. A copy retains the same
`(L, MB, SB)` projected rank even if attacker shares increase authenticated
`Q`, so a later copy cannot replace the first-seen incumbent. A child linking
that incumbent then settles the height against all later siblings. Before the
child, different observers can still receive equal-rank siblings in different
orders.

**The payout policy is a guess.** Solo minting targets 80%. Cooperative blocks
target 85% for the producer, divide 10% by contributions, pay 5% to the parent
carrier, and route fees and integer residuals to the producer. Tests prove
shape, conservation, and binding, but no public co-op network has tested these
incentives. Changing them after launch is a hard fork.

**The retarget window of 16 is short.** The margin distribution is
heavy-tailed — most blocks do not beat par at all — so a 16-sample median can
jump, and `C` could oscillate inside the 4x clamp. Sixteen was chosen because
a young chain needs feedback more than it needs stability. A 32-block window
is the fix if it oscillates.

**Fork choice is first-seen at equal projected rank.** Ties are common, so the
incumbent at equal `(height, L, MB, SB)` depends on arrival order. It converges
when a child arrives, but a node syncing from scratch may briefly retain a
different equal-rank sibling.

**The chain has never run on a public network.** Two nodes on one machine over
loopback is the extent of what has been exercised. Every claim in this
document about behaviour under real network conditions — reorg frequency,
sync under load, node health over weeks — is untested. A 14-day two-host soak
on mainnet rules is a launch precondition, not a nice-to-have.

**The security model is "nobody is trying".** There is no economic weight
behind the chain and no defence that assumes there is. A participant who
wanted to disrupt it could mine every block, or spend real money on nothing at
all. The chain's protection is that it is worth nothing, which is exactly as
robust as it sounds.

---

## 15. Implementation status

The source tree implements the canonical design end to end: tight generated
witnesses; seed derivation and bounded cache; projected score ranking and
retargeting; contribution-aware co-op payouts; durable-parent node validation;
CLI puzzle/mine/commit/reveal; branch-aware issued supply; and read-only,
escaped explorer pages and JSON.

Mainnet's timestamp and derived constants remain explicitly non-final until
the operator chooses launch day. Tightening regenerated the current coherent
mainnet placeholder and fixed regtest constants. The public testnet is an
explicit genesis reset; old testnet state is not migrated.

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
| aggregate `Q` | 0..15, authenticated/reporting only |
| minimum par | 24 bytes |
| generator retries | 64, then a frozen fallback |
| generator budget | 20000 steps per attempt |
| constraints | 8, tiers `(0)`, `(0 1 3 5)`, `(1 2 4 6 7)` |
| builtin cap `D` | 6, or 4 at tier 2 |
| complexity `C` | 16..4095, genesis 128 |
| retarget window | 16 blocks, target margin 100 milli-units |
| retarget clamp | 0.25x .. 4x per window |
| header version | 5 |
| `bits` | `0x207F0000 \| C` |
| `nonce` | the score word `W` |
| fork-choice rank | `(L, MB, SB)` via `W & 0xffffff0f` |
| max shares / commitments | 8 / 16 |
| payout | solo `floor(4*S/5)+F`; cooperative 10% weighted shares, 5% carrier, producer residual |
| coinbase scriptSig | 8 .. 6588 bytes |
| graffiti cap | 400 bytes |
| block size cap | 16384 bytes |
| block spacing floor | 72000 seconds; target 86400 |
| future drift / median time span | 7200 seconds / 11 blocks |
| coinbase maturity | 100 blocks |
| daviwils per SGL | 100000000 |
| warmup | heights 1..30 at 1 SGL |
| reward / halving | 100 SGL, halving every 730 blocks |
| last paying height | 24820 |
| scheduled maximum supply | 14302999991970 daviwils |
| address format | bech32, HRP `sgl` |
| mainnet magic / port | `8f d1 c0 a5` / 19444 |
| public-testnet magic / port | `d3 7a 91 c5` / 19446 |
| regtest magic / port | `a5 c0 d1 8f` / 19445 |
| protocol version / user agent | 70015 / `/sigilcoin-node:0.1.0/` |
| mainnet genesis quote / current display id | `Sigil - Practical Symbolic Power` / `1615333197455a3ebace8f1acdc66ae8d79a4f1a0ab3b7dc2f0078f051aef1ed` |
| reset-testnet quote / timestamp | `SigilCoin public testnet reset - 2026-09-02` / `1788307200` |
| reset-testnet display id | `15447f3226699f537969cbea4b493bbbe25a4d856832bf28bce3e7df579e6ddc` |
| regtest display id | `3d68493eed6f4adcb4073dc34b8a5b360fb73083f0cdbd6430c6b579ad3b69ba` |

---

SigilCoin is a joke with a test suite. Both halves are meant.
