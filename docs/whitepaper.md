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
- the meaning of three header fields. `version` is pinned, `bits` carries the
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
   24-entry grammar at width `w(C)` and wrap it in a one-argument lambda. This
   is the hidden function.
2. Print it, and reject if it does not parse, exceeds 512 bytes, or violates
   the height's constraint.
3. Draw `k(C)` pairwise-distinct inputs from the constraint's input domain.
   Reject if any input literal exceeds 8 bytes.
4. Apply the hidden function to each input. Reject if any application fails,
   exhausts the attempt budget, returns a procedure, returns a non-value, or
   returns a literal longer than 24 bytes.
5. Reject if all `k` outputs are equal. A constant function would win the
   height trivially.
6. Reject if any 1-arity builtin reproduces every pair. `car` is three bytes;
   a puzzle it solves is a race everyone wins at once.
7. Build the table solution (section 6), print it, parse it,
   constraint-check it, and run it against all `k` pairs under the real
   consensus caps. Reject if any of that fails.
8. `par = min(|hidden source|, |table|)`. Reject if `par < 24`.

The constraint is drawn from a dedicated stream keyed on a reserved retry
value, so re-rolls never move it: the constraint is a function of
`(seed, height, C)` alone, and a miner knows the day's rule before the
generator has settled on a puzzle.

After 64 rejections a frozen fallback puzzle is used, with its constraint
forced to the unconstrained rule and its examples fixed. The fallback re-runs
every acceptance check and raises if one fails, because a failure there is a
bug in the generator rather than a bad block.

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
The chain therefore guarantees, for every height, every constraint and every
complexity, a solution that any miner can construct mechanically from public
data.

A miner has the parent header, hence `prev_hash`, `H` and `C(H)`, hence the
seed, hence the whole puzzle. Running the same generator every validator runs
yields the `k` pairs and the constraint. From those, the **table solution**:

```
(lambda(x)(if(equal? x 'i_0)'o_0 (if(equal? x 'i_1)'o_1 ... 'o_{k-1})))
```

The last output is the default branch, so `k` pairs produce `k-1` tests. It
reproduces every pair by construction, because `equal?` on the puzzle value
domain is exactly the comparison consensus uses to check an example.

Two constraints need a repair wrapper, both mechanical and both
semantics-preserving: `letrec-required` wraps the body in
`(letrec((f(lambda(y)y)))(f BODY))`, costing 29 bytes, and `fold-required`
wraps it in `(fold(lambda(a b)a)BODY '())`, costing 24, since `fold` over the
empty list returns its init. Every other rule is satisfied by the choice of
body and example domain: the generator draws digit-free values under
`no-digits`, excludes symbols and prints quote-free literals under `no-quote`,
and restricts integers to single digits under `small-literals`.

### 6.1 Executable liveness bound

Per branch the table costs `18 + |i| + |o|` bytes, with the input literal
capped at 8 and the output at 24. Ten examples do not fit every repair:

```
letrec repair, k = 10 : 40 + 9 * (18 + 8 + 24) + 25 = 515   INFEASIBLE
fold repair,   k = 10 : 35 + 9 * 50 + 25            = 510   2 bytes spare
letrec repair, k =  8 : 40 + 7 * 50 + 25            = 415   97 bytes spare
```

The implementation caught it, because the generator does not evaluate the
arithmetic — it builds the actual string, measures it, parses it,
constraint-checks it, and runs it against all `k` pairs before the puzzle may
be published. Liveness is verified by construction on every accepted puzzle,
not argued from a formula that a later change could invalidate.

The example count is frozen at a maximum of 8 as a result: a proven worst case
of 415 bytes with 19% headroom, enough to absorb one further repair wrapper.
Difficulty above that point comes from grammar width, which does not lengthen
the table.

### 6.2 What the table means for the game

Overfitting is always available and always loses. The table is, by
construction, the longest thing anyone would submit: it is a transcription of
the answer key. Any program that captures the underlying structure is shorter,
and length is the primary ranking key. So the floor is a legal move that wins
nothing, and every byte below it is the competition.

Genesis is built rather than mined — there is no parent hash to derive a
puzzle from until a first block exists — and its coinbase carries the table
solution of the frozen genesis puzzle. Genesis is therefore a real, verifiable
block whose program reproduces its own published examples. Its reward is zero
and its single output is a bare `OP_RETURN`: no premine, provably unspendable
rather than merely unspent.

---

## 7. Scoring and fork choice

### 7.1 The score word

The header has no spare room, and none is asked for. Three fields are
repurposed: `version` is pinned to 5, `bits` carries the difficulty parameter
(section 8), and `nonce` carries a 32-bit composite score word `W`.

```
bit  31              22 21     15 14      8 7    4 3    0
    +------------------+---------+---------+------+------+
    |      L - 1       |   MB    |   SB    |15-Q  | 0000 |
    +------------------+---------+---------+------+------+
       10 bits           7 bits    7 bits   4 bits 4 bits
```

- `L` is the producer's solution length in bytes, 1..512, stored biased by one
- `MB` is a bucket of the cells the solution charged
- `SB` is a bucket of the steps it spent
- `Q` is aggregate verified share quality, 0..15, stored as `15-Q` so that
  more verified work gives a lower word
- the low nibble is reserved zero

Lower is better, and plain unsigned comparison *is* the composite order:
disjoint fixed-width fields laid out most-significant-first in ranking
priority form the base-2^width numeral of the tuple, and comparing numerals of
equal width is lexicographic comparison of their digits. Length dominates
memory dominates steps dominates aggregate verified share quality.

Quality is last for a reason. It breaks ties without outranking a better
producer program, so it occupies strictly lower-order bits than every producer
field. Raw reveal count remains separate and controls only the reward split.

Because every field is derived from the block body and the low nibble is
reserved, the header carries **zero free entropy**. There is no nonce to
grind.

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

The bucketed value is the consensus value. Fork choice compares header words
and never body integers, so two solutions in one bucket are exactly tied and
fall through to aggregate share quality. The precision loss is deliberate:
there is no
second, finer order that could drift out of agreement with the header.

### 7.3 The header-to-body commitment

`W` is a claim. Body validation recomputes it from the validated body and
requires exact equality; a mismatch is `score-mismatch` and the node marks the
header and every descendant permanently invalid. The check bites in both
directions, because `W` is an equality and not a bound: understating a
solution's length claims a better block than the one carried, and overstating
it is equally a lie.

That equality is what makes header-only fork choice safe. Headers can be
ranked before bodies arrive, and a liar does not outrank an honest chain — he
produces an invalid block.

### 7.4 The order

```
b1 is a better tip than b2  iff  height(b1) > height(b2)
                                 or (equal height and W(b1) < W(b2))
```

with a "live beats settled" rule ahead of both: once a taller header exists,
a height is settled and no sibling displaces it. At equal height and equal
`W`, blocks are incomparable and the incumbent tip is kept — first-seen,
exactly as Bitcoin resolves equal-work siblings. It is order-dependent between
nodes and converges the moment a child arrives, because height dominates.

Mapping onto the single accumulated integer the node store persists:

```
saving(b)  = 2^32 - W(b)        1 .. 2^32, with 0 reserved for an illegal W
work       = accumulated * (2^32 + 1) + saving
```

`saving <= 2^32 < 2^32 + 1`, so the digits never collide, and `accumulated` is
strictly increasing along any chain, so no chain ranks below its own ancestor.

**There is no block-hash tie-break.** Such a tie-break would be grindable
through 400 bytes of coinbase graffiti, and ties are common because an optimal
program is often unique. Equal `W` never displaces an incumbent. Hash
comparison exists only for stable display ordering in the explorer and CLI,
where it decides nothing.

---

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

Relative, because par varies by a factor of six across observed puzzles: an
absolute "beat par by N bytes" threshold would mean something different at
every height. Division floors toward negative infinity, specified explicitly,
so "missed par by a hair" and "missed par exactly" are different signals.

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

`C(0) = 128` and stays there through the first, partial window; the first
retarget is at height 16 over heights 0 through 15, genesis included, whose
par is well defined. A reorg recomputes `C` from the new branch's own 16
blocks.

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

### 9.2 What a share binds

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

### 9.3 The split

With `V = subsidy + fees` and `R` accepted shares:

```
weights : producer 2, each share 1, carrier 1 (when R >= 1)
u       = floor(V / (2 + R + carrier))
output 0     producer : V - R*u - carrier*u
output 1..R  share i  : u, paid to P2WPKH of the signed pubkey
output R+1   carrier  : u, paid to the script of block H-1's coinbase output 0
```

The outputs sum to `V` exactly, so Bitcoin's value conservation passes
unchanged and the remainder — at most 10 daviwils — goes to the producer
rather than burning or leaking into fees. At the maximum of 8 shares the
producer keeps 2/11 of the block plus the remainder.

The carrier output is the answer to "why would a producer carry anyone else's
commitments?" He is paid, one block later, by the *next* producer, for having
carried commitments that were revealed. He cannot fake it: fabricated
commitments earn nothing, because nobody can reveal them.

Including shares costs the producer real reward. What pays for it is aggregate
verified quality `Q`: under-par personalized shares improve the score after
producer length, memory, and steps tie. Raw share count affects only the reward
split.

### 9.4 Unrevealed commitments

Nothing happens. A commitment that is never revealed expires when the next
block is accepted. There is no penalty, no refund, and no state beyond one
block: validating a block requires only the parent's commitment set, at most
16 hashes, which is already in the node's store. Commitment spam is bounded to
513 bytes per block. A miner may commit to several candidates and reveal the
best one, which is a feature.

---

## 10. Emission and supply

Emission is a pure function of height, in daviwils (1 SGL = 100000000
daviwils):

```
height 0        0                       genesis pays nothing
heights 1..30   1 SGL                   warmup
heights >= 31   floor(100 SGL / 2^floor((height - 1) / 730))
```

At roughly one block a day, a halving interval of 730 blocks is about two
years. The shift is exact integer division, so the tail decays to zero rather
than to a fraction: height 24820 is the last block that pays anything, and the
total ever emitted is **14302999991970 daviwils** (143029.99991970 SGL). That
is a hard cap, not an asymptote.

There is no premine and no founder's reward. The genesis coinbase pays zero to
an unspendable `OP_RETURN`. Coinbase outputs mature after 100 blocks.

The warmup exists so that the first month of a chain nobody has debugged in
public does not mint 100 SGL a block while the first bugs are found.

There is no fee market. Fees exist because Bitcoin's transaction format has
them, and the wallet pays a token amount by default; a chain that mines one
block a day by writing programs has nothing to auction.

---

## 11. Validation cost

Worst case per block, at the frozen caps:

| Work | Bound |
| --- | --- |
| header checks | O(1) |
| block size | one serialization |
| coinbase decode | O(6588) bytes, five pushes and one re-encode |
| global puzzle derivation | 64 attempts x 20000 steps = 1.28 M steps, cached per height |
| personalized puzzle derivation | 8 x 64 x 20000 steps = 10.24 M steps |
| producer solution | 200000 steps on one machine |
| share solutions | 8 x 200000 steps |
| signature verification | 8 ECDSA |
| transactions | Bitcoin's existing cost |

At about 5.5 microseconds per puzzle-language step, the uncached ceiling is
roughly 73 seconds, about 0.1% of the 72000-second spacing floor. Global and
personalized puzzle specs are cached across siblings. Typical cost is
microseconds: measured puzzles used around 300 steps and 80 cells.

Two rules keep that bound real.

**Derivation is cached per `(prev_hash, height)`.** Every sibling at a height
is judged against the same puzzle, so the expensive step is paid once. The
cache is keyed on the seed, which is injective over the triple, and it is
correctness-neutral by construction: a node that never hits it validates the
same chain, slower.

**Validation is ordered cheapest-first, and that ordering is a requirement.**
Nothing evaluates a solution before the block has passed size, payload decode
and header-field checks. Size first, because it bounds everything after;
constraint byte scans before parses; parses before evaluation; commitment
membership before signature verification before evaluation. Solution
evaluation stays ahead of the transaction connector, because the connector
mutates the UTXO set it is handed and a later rejection would leave a caller's
in-memory set carrying a rejected block's outputs.

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
`sigil-bitcoin` needs to know what a puzzle is. Headers-first sync, block
relay and peer management are Bitcoin's, unchanged. State is SQLite in a data
directory. Two chains ship: `sigilcoin-main`, magic `8f d1 c0 a5`, port 19444,
one block a day; and `sigilcoin-regtest`, byte-reversed magic, port 19445, and
a one-second spacing floor so tests can mine consecutively. The magic bytes
collide with no known Bitcoin-family network, all have the high bit set so the
frame prefix is not valid UTF-8, and are pairwise distinct so a misaligned
read cannot match.

**Wallet.** Keys, bech32 addresses with HRP `sgl` (so addresses read `sgl1…`),
balance and spending, in the CLI. The key lives in the node's data directory
and is the operator's to back up.

**Explorer.** A read-only HTTP site over the node's database: chain summary,
block list, block detail with the puzzle, the score decomposition and the
share table, address pages, a difficulty history, and a JSON endpoint for each.
It never writes, and it never trusts a block: graffiti and solution text are
miner-chosen bytes and are sanitized and escaped on every path. It does not
re-verify share signatures — consensus already settled that — so a share table
reports what a block claims, which is the honest thing for a reader of a
validated chain.

**Deployment.** A NixOS module for the seed node and the explorer, with the
node holding its own port and the explorer bound to loopback behind a reverse
proxy. Operational detail is in `deploy/RUNBOOK.md`; the launch gate is in
`LAUNCH.md`.

---

## 13. What measurement contributed

Three design decisions came from measuring rather than reasoning, and it is
worth saying which.

**The puzzle asks for a function because pre-freeze measurement required
it.** Before protocol rules were frozen, a survey model tested target-value
puzzles by asking for a program that produced one value. This model was never
an implemented SigilCoin ruleset. Across 480 generated cases, **78.3%** of best
known answers were quoted target literals: mining reduced to transcription.
The survey also found the minimal answer unique 96.7% of the time, unbounded
same-length variants that made hash tie-breaking grindable, and execution
metrics at 0.03% of the fuel cap and 0.08% of the allocation cap. PBE replaced
that measurement model before freeze: a function cannot be quoted, and its
examples expose structure worth synthesizing.

**The example count is 8 because executable bounds beat estimates.** Ten
examples need 515 bytes under one repair wrapper and leave only two bytes under
another. The count was frozen at 8, where the global worst case is 415 bytes
and the personalized worst case is 458 bytes.

**Liveness is verified, not argued.** The generator does not rely on size
arithmetic alone. Every accepted puzzle has had its
fallback solution constructed, printed, parsed, constraint-checked and run
against every published pair, under the real consensus caps, before it can be
published. The documented size bound is documentation; the check is the
guarantee.

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
is gone. A person writing programs by hand will lose to someone who leaves a
search running, exactly as a CPU miner loses to an ASIC. The difference is
only that here the winning machine is a program someone wrote, and the losing
human can read it.

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
his block carries. The carrier output pays him to include them and the
share-count tie-break rewards him for carrying reveals, but a miner who
expects to win most heights is better off excluding everyone, and there is no
in-protocol defence. The mitigations are that he controls only one height and
forfeits both the carrier payout and the tie-break. If censorship shows up in
practice, the cheapest fix is to make commitment count a soft input to
retargeting — a chain carrying no commitments is treated as easier — which
costs the censor difficulty rather than requiring a new mechanism. That is not
built, and should not be until the behaviour is observed.

**The producer's own program can be copied.** It is revealed in the block that
claims it and cannot be committed in advance. No hash tie-break, aggregate
verified quality, and the settled-height rule make copying unprofitable in
most cases. A thief who copies the program and matches `Q` produces an
incomparable sibling: nodes keep the first one seen, and the next block settles
the height. That is the honest limit of same-block reveal protection.

**The producer/share weight split is a guess.** Producer 2, each share 1,
carrier 1. There is no data behind it, because nothing with shares has ever
run. If it is wrong in one direction producers carry fewer shares than the
tie-break rewards; in the other, sharing is not worth a sharer's effort.

**The retarget window of 16 is short.** The margin distribution is
heavy-tailed — most blocks do not beat par at all — so a 16-sample median can
jump, and `C` could oscillate inside the 4x clamp. Sixteen was chosen because
a young chain needs feedback more than it needs stability. A 32-block window
is the fix if it oscillates.

**Fork choice is first-seen at equal score.** Ties are common, so the tip at
equal height and equal score depends on message arrival order. It converges as
soon as a child arrives, but a node syncing from scratch may briefly land on a
different sibling than its peers.

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

Source tree implements canonical design end to end: puzzle generation and
constraints; seed derivation and bounded cache; solution scoring and retarget;
co-op shares, blind-bearing reveal, commitments and reward split; durable-parent
node validation and block building; CLI puzzle/mine/commit/reveal; read-only,
escaped explorer pages and JSON.

Mainnet genesis quote is configured, but timestamp and derived constants remain
explicitly non-final until operator chooses launch day. Regtest genesis is fixed
and used by integration tests.

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
| input / output literal cap | 8 / 24 bytes |
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
| max shares / commitments | 8 / 16 |
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
| total supply | 14302999991970 daviwils |
| address format | bech32, HRP `sgl` |
| mainnet magic / port | `8f d1 c0 a5` / 19444 |
| regtest magic / port | `a5 c0 d1 8f` / 19445 |
| protocol version / user agent | 70015 / `/sigilcoin-node:0.1.0/` |
| genesis quote | `Sigil - Practical Symbolic Power` |

---

SigilCoin is a joke with a test suite. Both halves are meant.
