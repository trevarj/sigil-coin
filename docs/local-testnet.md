# Local regtest drill

This drill uses the replacement `sigilcoin-regtest` network from height 0 with
fresh disposable state. Nothing here approves or launches mainnet. Retired
nonce-PoW databases and relay receipts must be archived, never reopened by this
build; the historical mainnet launch was superseded before height 1.

Production is scheduled, not searched: each timestamp is exactly the parent
timestamp plus the configured regtest spacing and cannot be in the future.
Mainnet uses exact 86,400-second slots; this drill retains shorter regtest slots.
The puzzle VM and `L <= par` producer validity remain. A valid at-par program
scores 1; otherwise `savings = min(8, max(0, par - L))` and
`block_score = 1 + savings`, capped at 9. Genesis scores 0. These displayed
quality metrics do not select branches or currently alter subsidy. Only a
strictly taller valid branch replaces the durable active chain. Equal height
keeps its incumbent across restart regardless of score, hash, or arrival
metadata; nodes can retain different local incumbents.

Chain configs hardcode `(height . internal-hash)` checkpoints; incompatible
branches cannot cross them. Only reviewed releases advance checkpoints, and
nodes must upgrade to share a newer one. Public testnet and regtest still pin
H0 only, protecting genesis but no later history. Mainnet now pins H0 and H1
on the replacement slogan chain. Its authorized slogan reset abandons the
mistaken marker-quote H0/H1 and its H1 checkpoint; see
[the consensus specification](consensus.md#58-hardcoded-release-checkpoints).
Mainnet transport magic is `SGM4` and requires fresh chain and relay state.
Testnet and regtest retain their genesis identities, timestamps, and
`SGT3` / `SGR3` magic. Their existing proof-of-golf H0 state may be reused
outside this deliberately fresh-state drill; retired nonce-PoW state must
remain archived.

This is hobby-chain evidence, not settlement security. Equal-height alternatives
are cheap to build; missed slots offer takeover opportunities, partitions can
preserve local forks, and reorgs remain possible above the latest checkpoint.
Parent-template manipulation is still possible.

## Prerequisites

- Nix workspace at `/home/trev/Workspace/sigil`, with existing `.sigil/deps`.
- Current `sigilcoin` and `sigilcoin-explorer` binaries. By default the script
  resolves `deploy#sigilcoin`; pass `--bin-dir` for a current source build.
- `bash`, `coreutils` (`timeout`), `curl`, `jq`, `awk`, and `grep` on `PATH`.
- Free loopback ports from the selected `--base-port` range. No non-loopback
  peer or HTTP origin is contacted.

From repository root:

```sh
# Current Nix artifact, ephemeral state and automatic cleanup.
bash tools/local-testnet.sh

# Current source build.
nix develop /home/trev/Workspace/sigil -c \
  /home/trev/Workspace/sigil/sigil/build/dev/bin/sigil build \
  --redirects ./dev-redirects.sgl
bash tools/local-testnet.sh --bin-dir "$PWD/build/dev/bin"

# Preserve logs, HTTP bodies, transcript, and disposable test wallet keys.
bash tools/local-testnet.sh --keep --base-port 36000

# Named state directory must be empty and is preserved automatically.
state=$(mktemp -d /tmp/sigilcoin-proof-of-golf-drill.XXXXXX)
bash tools/local-testnet.sh --state-dir "$state" --base-port 36000
```

Never fund keys retained by `--keep`; they are disposable test keys. Every
CLI/helper command has a timeout. Listener and explorer processes have
900-second safety deadlines. `INT`/`TERM` stop them and exit; idempotent `EXIT`
cleanup runs once. `--keep` preserves data, never processes.

The deployment loopback stack, unlike this ephemeral drill, keeps state at
`deploy/state/local-testnet-proof-of-golf` by default. Neither workflow may reuse
retired `local-testnet` state. Compare the replacement genesis with the reviewed
all-network output from `deploy/genesis-constants.sgl`, not a historical hash.

`tools/local-testnet` has two narrow fixture jobs the public CLI intentionally
does not. `solve-relay-share` derives a genuine semantic solution for the
relay's pubkey-personalized puzzle without opening a node database, and accepts
it only when the production share checker proves `L < personalized_par`.
`relay-wallet-transaction` sends an ordinary node's canonical signed
transaction through a normal regtest P2P handshake and `tx` envelope. Neither
helper injects producer SQLite, fabricates contribution, or bypasses consensus
validation.

## What automated run approves

1. Creates producer/full node A, ordinary sender node B, ordinary recipient
   node C, node-free contributor wallet D, a separate relay store, and an
   explorer.
2. Produces through H99 with one complete candidate per attempt. The generated
   at-par witness is a valid score-1 fallback once its slot is due; no header
   nonce or coinbase search follows it. Headers remain 80 bytes, with nonce 0
   and fixed network pow-limit `bits` as a compatibility field, not a target.
   Non-genesis coinbase lock-time is 0, graffiti is empty, and its sequence and
   version are canonical.
3. Captures H15/H16/H17 puzzle complexity. The at-par H16
   puzzle-complexity retarget changes `C`, and historical queries must agree
   across nodes. Network `bits` stays fixed; there is no hash-difficulty
   retarget. H1 output must report `savings: 0` and `block-score: 1`.
4. Starts D's local watcher and loopback relay. Before H100, the relay has D's
   authenticated commitment but no private key, blind, solution source,
   consensus share signature, or encoded share; D has no node database. H100,
   produced by A with relay inputs, contains D's exact commitment.
5. Creates A's ordinary signed transfer to B. H101 includes that transaction
   and D's delayed signed reveal, with its verified contribution, direct share
   output, carrier output, producer fees/residual, full scheduled subsidy, and
   zero unminted reserve.
6. Syncs B through H101, creates B's signed transfer to C, and relays its
   canonical `tx` envelope over an ordinary loopback P2P session. A records it
   from a peer before producing H102; H102 contains the exact txid, C owns the
   expected output, and B paid the fee.
7. Closes and reopens A on durable H102, produces H103 as its child, and syncs all
   three full nodes. A, B, C, and explorer must agree through H103 on tip,
   validated bodies, transactions, balances, fees, payouts, issued supply, and
   scheduled caps. Their final `best-chain-score` is 103: every produced block
   in this drill is at par, and genesis contributes 0.
8. Confirms D's directory contains only private wallet/commitment state and no
   `sigilcoin-*.sqlite`.

Approval is one final `PASS` line. Any mismatch, timeout, process death, HTTP
failure, secret leak, missing payout/transaction, or state disagreement exits
non-zero.

## Inspecting a preserved run

The script is the reference procedure; a hand-expanded version can silently
bypass the relay watcher or the real P2P transaction path. Preserve one run:

```sh
bash tools/local-testnet.sh --keep --base-port 36000
```

Use the reported state directory to inspect the transcript, process logs, relay
responses, and explorer JSON. Required landmarks are:

```text
H100  D commitment
H101  D reveal + signed A -> B transaction
H102  signed B -> C transaction received by A over P2P
H103  child produced after closing and reopening durable H102
```

The transcript's `retarget:` line names `C(H15)`, `C(H16)`, and `C(H17)`. Its
final `agreement:` line records A/B/C at `height=103`, `chain-score=103`, and
`validated-bodies=103`, along with the next complexity and tip. It must also
show D has no node database and that relay phase one stored no secret or reveal
material.

Explorer block JSON exposes a `golf` object with `claimed_length`, `par`,
`savings`, `block_score`, and `chain_score`. H101 has savings 0, block score 1,
and chain score 101; the final summary's `chain_score` is 103. Compare these
with the programs and cumulative quality score on the same active branch, not
as evidence for fork choice or finality.

## Payout and supply expectations

For H101, let `S` be scheduled subsidy, `F` its ordinary transaction fees, and
`c` D's verified contribution. With one share, D receives the whole share
pool regardless of whether `c` is 1, 2, 3, or 4:

```text
share D       = floor(S/10)
carrier H100  = floor(S/20)
producer A    = S + F - share D - carrier H100
coinbase      = S + F
unminted      = 0
```

The producer receives fees and every integer residual. The direct share payout
is created in H101 and is spendable at H102 under SigilCoin's one-block
coinbase maturity. Later solo blocks mint only `floor(4*S/5)+F`, so active-UTXO
`issued-supply` may trail the height-only `scheduled-supply-cap`.

The fixture exits rather than inventing a share when its semantic transformation
does not pass the personalized puzzle and strict under-par rule. `--keep`
preserves disposable private keys and evidence; never fund them.

