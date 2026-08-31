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

`tools/local-testnet` has one narrow purpose: `solve-share` obtains an under-par
test solution because the CLI has no solver. It does not construct or submit
blocks. Commit aggregation, reveal aggregation, mining, validation, and payouts
all use canonical CLI operations.

## What automated run approves

1. Creates distinct producer A and contributor B wallets.
2. Mines fallback producer work through H99 and captures the H16 retarget:
   `C(H15)=128`, `C(H16)=32`, `C(H17)=32`.
3. At tip 99, reruns `puzzle --height 15`, `16`, and `17` and requires those
   historical complexities to match the values captured at the retarget.
4. Syncs B to H99, obtains a fixture solution, and has B emit two commitments.
   A feeds B's `commits-push` to `mine --commit` at H100 and requires both
   commitments to be accepted.
5. Sends `0.50000000 SGL` from A to B, syncs B to H100, and has B emit a reveal.
   A feeds B's `shares-push` to `mine --reveal` at H101 and requires accepted
   share, non-zero aggregate Q, contributor share payout, producer carrier
   payout, and payment transaction.
6. Runs A listener, B sync, and explorer over loopback. Stops A, reopens its
   database, mines H102 on durable H101, restarts A, and re-syncs B.
7. Requires both nodes to agree on H102 tip hash, next C, block count, and 102
   validated bodies. B must have the `0.50000000 SGL` spendable transfer plus
   immature share payout.
8. Validates `/api/summary`, `/api/block/100`, `/api/block/101`,
   `/api/difficulty`, and `/api/address/<B>`, including exact Q and positive
   share/carrier outputs.

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
# Expected: height 101, accepted-share, aggregate-q > 0, share/carrier payouts,
# transactions: 1, submitted: yes.
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
curl -fsS http://127.0.0.1:36002/api/summary | jq .
curl -fsS http://127.0.0.1:36002/api/block/100 | jq .commitments
curl -fsS http://127.0.0.1:36002/api/block/101 | jq \
  '{height,share_count,quality:.score.quality,transactions,outputs}'
curl -fsS "http://127.0.0.1:36002/api/address/$B_ADDR" | jq .
kill "$explorer" "$listener"; wait "$explorer" "$listener" 2>/dev/null || true
rm -rf "$A" "$B"
```

Approve only when statuses agree, H100 contains contributor commitment, H101 has
non-zero Q plus positive `share` and `carrier` outputs, B has transfer and share
payout, and explorer endpoints return HTTP 200 JSON.

## Recorded local results

Two clean runs on 2026-08-31 used current source-built binaries from
`build/dev/bin`, built inside the workspace Nix development shell:

```text
run 1: PASS runtime=112s, H102 tip=d55faf2…eed1b29, C(next)=16
run 2: PASS runtime=42s,  H102 tip=b879e75…842f7b9, C(next)=16
both: historical C(H15/H16/H17)=128/32/32 at tip 99
both: B commits-push -> A mine --commit H100; 2 commitments accepted
both: B shares-push -> A mine --reveal H101; Q=1
both: share payout=25.00000250 SGL; carrier payout=25.00000250 SGL
both: payment selected; B balance=25.50000250 SGL (0.50000000 spendable)
both: 102 validated bodies/node; summary/block/difficulty/address JSON approved
```

Run 1 included fixture build time; run 2 reused built fixture. Full transcripts
and JSON remain under `/tmp/sigilcoin-local-testnet.KPVqUB` and
`/tmp/sigilcoin-local-testnet.Is9yrz`. Native `mine-coop` bridge is removed.
No blocker remains.
