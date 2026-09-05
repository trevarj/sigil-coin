# Local regtest drill

This drill uses `sigilcoin-regtest` only. Mainnet genesis timestamp and derived
constants remain non-final; nothing here approves or launches mainnet.

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
state=$(mktemp -d /tmp/sigilcoin-drill.XXXXXX)
bash tools/local-testnet.sh --state-dir "$state" --base-port 36000
```

Never fund keys retained by `--keep`; they are disposable test keys. Every
CLI/helper command has a timeout. Listener and explorer processes have
900-second safety deadlines. `INT`/`TERM` stop them and exit; idempotent `EXIT`
cleanup runs once. `--keep` preserves data, never processes.

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
2. Mines through H99 with automatic uint32 nonce search. The generated par
   witness is an eligible `L <= par` producer program, not a block by itself;
   each finalized header must still produce a qualifying full-header `HASH256`
   roll.
3. Captures H15/H16/H17 complexity and the corresponding `C`-dependent lottery
   base targets. The H16 retarget and historical queries must agree across
   nodes.
4. Starts D's local watcher and loopback relay. Before H100, the relay has D's
   authenticated commitment but no private key, blind, solution source,
   consensus share signature, or encoded share; D has no node database. H100,
   mined by A with relay inputs, contains D's exact commitment.
5. Creates A's ordinary signed transfer to B. H101 includes that transaction
   and D's delayed signed reveal, with its verified contribution, direct share
   output, carrier output, producer fees/residual, full scheduled subsidy, and
   zero unminted reserve.
6. Syncs B through H101, creates B's signed transfer to C, and relays its
   canonical `tx` envelope over an ordinary loopback P2P session. A records it
   from a peer before mining H102; H102 contains the exact txid, C owns the
   expected output, and B paid the fee.
7. Closes and reopens A on durable H102, mines H103 as its child, and syncs all
   three full nodes. A, B, C, and explorer must agree through H103 on tip,
   validated bodies, transactions, balances, fees, payouts, issued supply, and
   scheduled caps.
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
H103  child mined after closing and reopening durable H102
```

The transcript must also name the H15/H16/H17 complexities and lottery base
targets, show D has no node database, and show that relay phase one stored no
secret or reveal material.

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

