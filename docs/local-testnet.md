# Local regtest drill

This drill uses `sigilcoin-regtest` only. Mainnet genesis timestamp and derived
constants remain non-final; nothing here approves or launches mainnet.

## Prerequisites

- Nix workspace at `/home/trev/Workspace/sigil`, with existing `.sigil/deps`.
- Current `sigilcoin` and `sigilcoin-explorer` binaries. By default the script
  resolves `deploy#sigilcoin`; pass `--bin-dir` for a current source build.
- `bash`, `coreutils` (`timeout`), `curl`, `jq`, `awk`, and `grep` on `PATH`.
- Three free loopback ports. No non-loopback peer is configured or contacted.

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

`tools/local-testnet` has one narrow purpose: `solve-share` obtains a genuine
semantic under-par fixture because the CLI has no solver. It requires every
ordinary personalized example input to be non-string, replaces the exact tight
anchor predicate `(equal? x"@")` with `(string? x)`, runs
`coin-check-share-solution/spec`, and returns the candidate only when it is
strictly shorter than par. It never removes whitespace or fabricates a
contribution. Commit aggregation, reveal aggregation, mining, full share
validation, and payouts all use canonical CLI operations.

## What automated run approves

1. Creates distinct producer A and contributor B wallets.
2. Mines fallback producer work through H99 and captures the H16 retarget:
   `C(H15)=128`, `C(H16)=32`, `C(H17)=32`.
3. At tip 99, reruns `puzzle --height 15`, `16`, and `17` and requires those
   historical complexities to match the values captured at the retarget.
4. Syncs B to H99, obtains a fixture solution, and has B emit two commitments.
   A feeds B's `commits-push` to `mine --commit` at H100 and requires both
   commitments to be accepted.
5. Sends `0.50000000 SGL` from A to B with a `0.00001000 SGL` fee, syncs B to
   H100, and has B emit a reveal. A feeds B's `shares-push` to H101 and requires
   the verified contribution and authenticated aggregate `Q` to agree. At the
   100 SGL scheduled subsidy, it requires producer `85.00001000 SGL`, share
   `10.00000000 SGL`, carrier `5.00000000 SGL`, total coinbase
   `100.00001000 SGL`, and zero unminted subsidy.
6. Runs A listener, B sync, and explorer over loopback. Stops A, reopens its
   database, mines H102 on durable H101, restarts A, and re-syncs B.
7. Requires both nodes to agree on H102 tip hash, next C, block count, and 102
   validated bodies. B must have both the `0.50000000 SGL` transfer and the
   `10.00000000 SGL` share payout spendable under the one-block maturity rule.
8. Validates `/api/summary`, `/api/block/100`, `/api/block/101`,
   `/api/difficulty`, and `/api/address/<B>`, including authenticated `Q`,
   verified contribution, expected/actual 85%/10%/5% payout roles,
   branch-aware issued supply, the node's current scheduled cap, the explorer's
   scheduled lifetime maximum, and unminted reserve.

Approval is one final `PASS` line. Any mismatch, timeout, process death, HTTP
failure, missing payout, missing transaction, or state disagreement exits
non-zero.

## Short manual checklist

Create wallets and mine through H99:

```sh
cd /home/trev/Workspace/sigil/sigil-coin
out=$(nix --offline build ./deploy#sigilcoin --no-link --print-out-paths)
C=$out/bin/sigilcoin
E=$out/bin/sigilcoin-explorer
A=$(mktemp -d); B=$(mktemp -d)
A_ADDR=$($C address --regtest --data-dir "$A" | awk '/^address:/{print $2}')
B_ADDR=$($C address --regtest --data-dir "$B" | awk '/^address:/{print $2}')
$C puzzle --regtest --data-dir "$A"
for _ in $(seq 1 99); do
  timeout 120 "$C" mine --regtest --data-dir "$A" >/dev/null
done
$C puzzle --height 15 --regtest --data-dir "$A" | grep '^complexity: 128$'
$C puzzle --height 16 --regtest --data-dir "$A" | grep '^complexity: 32$'
$C puzzle --height 17 --regtest --data-dir "$A" | grep '^complexity: 32$'
```

Build the solver-only fixture, sync contributor B, then pass B's canonical
commit output to producer A:

```sh
(cd tools/local-testnet &&
  nix --offline develop /home/trev/Workspace/sigil -c \
    /home/trev/Workspace/sigil/sigil/build/dev/bin/sigil build \
    --redirects ./redirects.sgl)
H=$PWD/tools/local-testnet/build/dev/bin/sigil-coin-local-testnet

$C listen --regtest --data-dir "$A" --bind 127.0.0.1 --port 36000 \
  --max-connections 0 --max-steps 4096 --max-tx 256 &
listener=$!
timeout 180 "$C" sync --regtest --data-dir "$B" \
  --peer 127.0.0.1:36000 --max-steps 4096 --max-blocks 256
kill "$listener"; wait "$listener" 2>/dev/null || true

S=$($H solve-share "$B")
$C mine --share --solution "$S" --regtest --data-dir "$B"
COMMIT=$($C commit --solution "$S" --regtest --data-dir "$B" |
  awk '/^commits-push:/{print $2}')
$C mine --commit "$COMMIT" --regtest --data-dir "$A"
# Expected: height 100 and accepted-commitment.
```

Sync B to H100, pass its reveal to A's H101 mine, and verify output:

```sh
$C send --to "$B_ADDR" --amount 0.50000000 --fee 0.00001000 \
  --regtest --data-dir "$A"
$C listen --regtest --data-dir "$A" --bind 127.0.0.1 --port 36000 \
  --max-connections 0 --max-steps 4096 --max-tx 256 &
listener=$!
timeout 180 "$C" sync --regtest --data-dir "$B" \
  --peer 127.0.0.1:36000 --max-steps 4096 --max-blocks 256
kill "$listener"; wait "$listener" 2>/dev/null || true

REVEAL=$($C reveal --height 100 --regtest --data-dir "$B" |
  awk '/^shares-push:/{print $2}')
$C mine --reveal "$REVEAL" --regtest --data-dir "$A"
# Expected: height 101, accepted-share with contribution 1..4, aggregate-q
# equal to that contribution, producer/share/carrier payouts, minted and
# unminted totals, transactions: 1, submitted: yes.
```

Run sync and explorer checks, then stop everything and remove wallet state:

```sh
$C listen --regtest --data-dir "$A" --bind 127.0.0.1 --port 36000 \
  --max-connections 0 --max-steps 4096 --max-tx 256 &
listener=$!
timeout 180 "$C" sync --regtest --data-dir "$B" \
  --peer 127.0.0.1:36000 --max-steps 4096 --max-blocks 256
$E --regtest --data-dir "$A" --host 127.0.0.1 --port 36002 &
explorer=$!
$C status --regtest --data-dir "$A"
$C status --regtest --data-dir "$B"
$C balance --regtest --data-dir "$B"
curl -fsS http://127.0.0.1:36002/api/summary | jq \
  '{tip_height,supply,max_supply}'
curl -fsS http://127.0.0.1:36002/api/block/100 | jq .commitments
curl -fsS http://127.0.0.1:36002/api/block/101 | jq \
  '{height,reward,total_output,share_count,
    quality:.score.quality,shares,outputs}'
kill "$explorer" "$listener"; wait "$explorer" "$listener" 2>/dev/null || true
rm -rf "$A" "$B"
```

Approve only when statuses agree, H100 contains the contributor commitments,
and H101 reports one verified contribution with authenticated non-zero `Q`.
For the frozen one-share transaction, require producer `85.00001000 SGL`,
share `10.00000000 SGL`, carrier `5.00000000 SGL`, minted
`100.00001000 SGL`, and unminted `0.00000000 SGL`. B must hold the
`0.50000000 SGL` transfer plus its share payout, both spendable by H102, and
explorer endpoints must return HTTP 200 JSON. Node status must keep branch-aware
issued supply separate from the current scheduled cap; explorer summary must keep it
separate from the scheduled lifetime maximum.

## Current payout and supply expectations

The drill derives every amount from scheduled subsidy and verified
contributions:

```text
H101 scheduled subsidy: 100.00000000 SGL
H101 fees:               0.00001000 SGL
verified contribution:   1..4 (one share, so it receives the whole pool)
producer:                85.00001000 SGL
share:                   10.00000000 SGL
carrier:                  5.00000000 SGL
coinbase total:         100.00001000 SGL
unminted subsidy:         0.00000000 SGL
B balance:               10.50000000 SGL
                          (10.50000000 spendable, 0.00000000 immature)
```

The producer's nominal 85% is a target: fees and any proportional rounding
residual also go to output 0. A later solo block mints only
`floor(4*S/5)` plus fees, so final active-UTXO `issued-supply` may be lower than
the height-only `scheduled-supply-cap`.

The helper exits instead of inventing a share when a deterministic
personalized fixture has a string ordinary input or when the semantic
replacement is not valid and under par. A successful run prints one final
`PASS`; `--keep` preserves that run's transcript and JSON under its reported
temporary directory.

