# Private testnet operator runbook

This is a disposable, private, two-machine test of `sigilcoin-testnet`. It is
not a launch plan. Testnet coins and keys have no value.

## Fixed scope

- Chain: `sigilcoin-testnet`, selected with `--testnet`.
- P2P port: `19446`.
- Address prefix: `tsgl1` (`sgl1` remains mainnet/regtest only).
- Peers: the two manually configured IP addresses only. The chain has no seed
  peers.
- Cadence: one block per hour. Do not mine catch-up bursts.
- Consensus checkpoints under test: retarget every 16 blocks and coinbase
  maturity at 100 blocks.
- Duration: 30 days, with a mandatory checkpoint after day 7.

Do not publish DNS records, expose the explorer, add TLS, add seed peers, or run
an automated public deployment/push. Bind the explorer to loopback and reach it
through SSH. Restrict TCP/19446 at the network firewall so only the other
machine's fixed IP can connect.

Every key created here is a disposable testnet key. Never import a production
key, fund these addresses elsewhere, paste `wallet/wallet.key` into a ticket or
chat, or publish a backup. A backup contains the private key and unrevealed
commitment blinds even though the commands below never print either secret.

## Machine layout

Use current, identical source-built binaries on both machines. Substitute the
real private/VPN IPs once and keep them unchanged for the run.

Machine A:

```sh
export C=/home/operator/sigil-coin/build/dev/bin/sigilcoin
export E=/home/operator/sigil-coin/build/dev/bin/sigilcoin-explorer
export DATA=$HOME/.local/state/sigilcoin-private-testnet
export RUN=$HOME/.local/run/sigilcoin-private-testnet
export LOG=$HOME/.local/state/sigilcoin-private-testnet-logs
export BACKUPS=$HOME/.local/state/sigilcoin-private-testnet-backups
export LOCAL_IP=10.20.0.11
export PEER_IP=10.20.0.12
install -d -m 0700 "$DATA" "$RUN" "$LOG" "$BACKUPS"
```

Machine B uses the same paths and binaries, but:

```sh
export LOCAL_IP=10.20.0.12
export PEER_IP=10.20.0.11
```

The shell variables must be set again in every operator shell. Verify the
binary identity out of band, for example by comparing this output on both
machines:

```sh
sha256sum "$C" "$E"
"$C" version
"$E" --version
```

## Initialize and pair

Run on each machine. The first command creates that machine's disposable key;
record only the printed public `tsgl1...` address.

```sh
umask 077
"$C" address --testnet --data-dir "$DATA" | tee "$LOG/address.out"
grep '^address: tsgl1' "$LOG/address.out"
"$C" peers add "$PEER_IP:19446" --testnet --data-dir "$DATA"
"$C" peers list --testnet --data-dir "$DATA"
```

After both listeners are started, this probe must succeed on each machine:

```sh
"$C" peers test "$PEER_IP:19446" --testnet --data-dir "$DATA"
```

A `sgl1...` address on this chain is an error. Stop and correct the binary or
chain flag rather than continuing.

## Exact start commands

Start the P2P listener on each machine. `--max-connections 0` means unbounded
lifetime, not an unbounded number of simultaneous connections.

```sh
nohup "$C" listen --testnet --data-dir "$DATA" \
  --bind "$LOCAL_IP" --port 19446 --max-connections 0 \
  --accept-timeout 1000 --read-timeout 10000 --max-steps 4096 --max-tx 256 \
  >"$LOG/listen.log" 2>&1 &
printf '%s\n' "$!" >"$RUN/listen.pid"
kill -0 "$(cat "$RUN/listen.pid")"
```

Start the explorer on machine A only. It stays on loopback, with no DNS or TLS:

```sh
nohup "$E" --testnet --data-dir "$DATA" \
  --host 127.0.0.1 --port 8080 >"$LOG/explorer.log" 2>&1 &
printf '%s\n' "$!" >"$RUN/explorer.pid"
curl -fsS --max-time 5 http://127.0.0.1:8080/api/summary \
  | jq -e '.chain == "sigilcoin-testnet"'
```

View it from an operator workstation without exposing another port:

```sh
ssh -N -L 18080:127.0.0.1:8080 operator@10.20.0.11
# Browse http://127.0.0.1:18080/ on the workstation.
```

There is deliberately no daemon that discovers peers. Before and after each
hourly mine, sync explicitly with the configured IP:

```sh
timeout 180 "$C" sync --testnet --data-dir "$DATA" \
  --peer "$PEER_IP:19446" --iterations 1 --max-steps 4096 --max-blocks 256 \
  --resolve-timeout 1000 --connect-timeout 3000 --read-timeout 10000
```

## Exact normal stop commands

Stop mining/sync commands first if one is running, then stop long-lived
processes. Run the applicable lines on each machine:

```sh
if test -s "$RUN/explorer.pid"; then
  kill -TERM "$(cat "$RUN/explorer.pid")" 2>/dev/null || true
  while kill -0 "$(cat "$RUN/explorer.pid")" 2>/dev/null; do sleep 1; done
  rm -f "$RUN/explorer.pid"
fi
if test -s "$RUN/listen.pid"; then
  kill -TERM "$(cat "$RUN/listen.pid")" 2>/dev/null || true
  while kill -0 "$(cat "$RUN/listen.pid")" 2>/dev/null; do sleep 1; done
  rm -f "$RUN/listen.pid"
fi
"$C" status --testnet --data-dir "$DATA"
```

## Hourly operating cadence

Use UTC hour boundaries. Machine A produces even-numbered UTC hours and machine
B odd-numbered UTC hours. The scheduled producer does this once, not repeatedly:

```sh
date -u '+slot %Y-%m-%dT%H:00Z'
timeout 180 "$C" sync --testnet --data-dir "$DATA" \
  --peer "$PEER_IP:19446" --iterations 1 --max-steps 4096 --max-blocks 256
"$C" puzzle --testnet --data-dir "$DATA" | tee "$LOG/puzzle-$(date -u +%Y%m%dT%H).out"
timeout 180 "$C" mine --testnet --data-dir "$DATA" \
  --graffiti "private-testnet $(date -u +%Y-%m-%dT%H:00Z)" \
  | tee "$LOG/mine-$(date -u +%Y%m%dT%H).out"
timeout 180 "$C" sync --testnet --data-dir "$DATA" \
  --peer "$PEER_IP:19446" --iterations 1 --max-steps 4096 --max-blocks 256
"$C" status --testnet --data-dir "$DATA" | tee "$LOG/status-latest.out"
```

The non-producing machine runs the sync and status commands after the slot.
Compare `best-block-height`, `best-block-hash`, `validated-blocks`, and the next
puzzle complexity on both machines. Investigate a missed slot; do not compress
multiple blocks into the next hour.

### H16 retarget check

Capture each puzzle only when it is the next available height: the CLI
correctly refuses unknown future heights beyond `tip + 1`. H16 must be the
first retarget boundary and both nodes must report the same values:

```sh
# At tip H14:
"$C" puzzle --height 15 --testnet --data-dir "$DATA" | tee "$LOG/puzzle-h15.out"
# Mine/sync H15, then at tip H15:
"$C" puzzle --height 16 --testnet --data-dir "$DATA" | tee "$LOG/puzzle-h16.out"
# Mine/sync H16, then at tip H16:
"$C" puzzle --height 17 --testnet --data-dir "$DATA" | tee "$LOG/puzzle-h17.out"
# After H17, prove historical queries remain stable:
for h in 15 16 17; do
  "$C" puzzle --height "$h" --testnet --data-dir "$DATA" \
    | tee "$LOG/puzzle-h${h}-historical.out"
done
grep '^complexity:' "$LOG"/puzzle-h{15,16,17}.out \
  "$LOG"/puzzle-h{15,16,17}-historical.out
```

The test is not that complexity must move every window. The test is that the
H16 value follows the 16-block margin window, stays stable when queried later,
and agrees on both machines. Repeat this evidence capture at H32 and at least
once per day thereafter.

### H100 maturity and wallet check

The H1 coinbase must remain immature through tip H99 and become spendable at
tip H100. Capture balances immediately on both sides of the boundary:

```sh
"$C" balance --testnet --data-dir "$DATA" | tee "$LOG/balance-h99.out"
# Mine and sync H100 at its scheduled hour.
"$C" balance --testnet --data-dir "$DATA" | tee "$LOG/balance-h100.out"
grep '^spendable:' "$LOG/balance-h99.out" "$LOG/balance-h100.out"
```

After H100, send a small amount between the recorded `tsgl1...` addresses and
mine it in the next scheduled block:

```sh
export OTHER_ADDRESS=tsgl1REPLACE_WITH_THE_OTHER_MACHINE_ADDRESS
"$C" send --to "$OTHER_ADDRESS" --amount 0.50000000 --fee 0.00001000 \
  --testnet --data-dir "$DATA" | tee "$LOG/send-after-h100.out"
```

## Commit, reveal, co-op, and Q drill

Perform this at least once before day 7 and once more before day 30. B is the
contributor and A the producer. Start from both nodes on the same validated tip.
B obtains its personalized puzzle and writes an under-par solution locally:

```sh
"$C" puzzle --share --testnet --data-dir "$DATA" | tee "$LOG/share-puzzle.out"
export SOLUTION='REPLACE_WITH_BS_ONE_ARGUMENT_PUZZLE_PROGRAM'
"$C" mine --share --solution "$SOLUTION" --testnet --data-dir "$DATA"
"$C" commit --solution "$SOLUTION" --testnet --data-dir "$DATA" \
  | tee "$LOG/commit.out"
awk -F': ' '$1 == "commits-push" { print $2 }' "$LOG/commit.out"
```

Copy only the public `commits-push` value to A through the operator channel.
Do not copy B's key, blind, commitment file, or unrevealed source. On A, carry
it in scheduled block H:

```sh
export COMMITS_PUSH='REPLACE_WITH_BS_COMMITS_PUSH_HEX'
timeout 180 "$C" mine --testnet --data-dir "$DATA" \
  --commit "$COMMITS_PUSH" --graffiti 'private-testnet contributor commit' \
  | tee "$LOG/mine-commit.out"
grep '^accepted-commitment:' "$LOG/mine-commit.out"
```

Sync B to H, reveal there, and copy only `shares-push` back to A:

```sh
export COMMIT_HEIGHT=REPLACE_WITH_NUMERIC_COMMIT_HEIGHT
timeout 180 "$C" sync --testnet --data-dir "$DATA" \
  --peer "$PEER_IP:19446" --iterations 1 --max-steps 4096 --max-blocks 256
"$C" reveal --height "$COMMIT_HEIGHT" --testnet --data-dir "$DATA" \
  | tee "$LOG/reveal.out"
awk -F': ' '$1 == "shares-push" { print $2 }' "$LOG/reveal.out"
```

At the next scheduled hour, A carries the reveal in H+1:

```sh
export SHARES_PUSH='REPLACE_WITH_BS_SHARES_PUSH_HEX'
timeout 180 "$C" mine --testnet --data-dir "$DATA" \
  --reveal "$SHARES_PUSH" --graffiti 'private-testnet contributor reveal' \
  | tee "$LOG/mine-reveal.out"
grep '^accepted-share:' "$LOG/mine-reveal.out"
grep -E '^aggregate-q: [1-9][0-9]*$' "$LOG/mine-reveal.out"
grep '^payout: role=share ' "$LOG/mine-reveal.out"
grep '^payout: role=carrier ' "$LOG/mine-reveal.out"
```

A reveal without its prior commitment, a reveal later than H+1, zero Q, or a
missing share/carrier payout fails the drill.

## Explorer checks

Set the contributor address and the two heights from the drill on machine A:

```sh
export CONTRIBUTOR=tsgl1REPLACE_WITH_CONTRIBUTOR_ADDRESS
export COMMIT_HEIGHT=REPLACE_WITH_NUMERIC_COMMIT_HEIGHT
export REVEAL_HEIGHT=$((COMMIT_HEIGHT + 1))
base=http://127.0.0.1:8080
curl -fsS --max-time 10 "$base/api/summary" \
  | jq -e '.chain == "sigilcoin-testnet"'
curl -fsS --max-time 10 "$base/api/block/$COMMIT_HEIGHT" \
  | jq -e '.commitments > 0 and .complexity != null and .score.word != null'
curl -fsS --max-time 10 "$base/api/block/$REVEAL_HEIGHT" \
  | jq -e '.share_count > 0 and .score.quality > 0 and
      any(.outputs[]; .role == "share" and .value > 0) and
      any(.outputs[]; .role == "carrier" and .value > 0)'
curl -fsS --max-time 10 "$base/api/difficulty" \
  | jq -e '.history | length > 0'
curl -fsS --max-time 10 "$base/api/address/$CONTRIBUTOR" \
  | jq -e --arg a "$CONTRIBUTOR" '.address == $a'
curl -fsS --max-time 10 "$base/block/$REVEAL_HEIGHT" \
  | grep -E 'Puzzle|Producer score|aggregate Q|Co-op shares|Reward split'
```

Also open the HTML block page containing hostile-looking but harmless test
text such as `<b>test</b>` in graffiti. It must appear escaped, never as markup.
The explorer must not change the database; compare a stopped-node backup or
hash before and after a route sweep when performing the restore drill.

## Reorg drill

Run once in days 3-6 and once in days 21-27. First sync both nodes to the same
parent and record its hash. For two scheduled hours, do not run cross-machine
sync. In hour one, A and B each mine a different child (use distinct graffiti).
In hour two, only B mines a second block. Then A syncs from B:

```sh
"$C" status --testnet --data-dir "$DATA" | tee "$LOG/reorg-parent.out"
# Partition window: skip cross-machine sync.
timeout 180 "$C" mine --testnet --data-dir "$DATA" --graffiti 'reorg A branch'
# On B in the same slot: mine --graffiti 'reorg B branch'.
# On B in the following slot: mine --graffiti 'reorg B branch second'.
timeout 180 "$C" sync --testnet --data-dir "$DATA" \
  --peer "$PEER_IP:19446" --iterations 1 --max-steps 4096 --max-blocks 256
"$C" status --testnet --data-dir "$DATA" | tee "$LOG/reorg-after.out"
```

A must switch to the better complete branch, disconnect its old active child,
restore the correct UTXO view, and agree with B on tip hash and validated body
count. Confirm the explorer summary and address balances follow the new active
chain and do not show the stale sibling as canonical.

## Restart, hard-kill, backup, and restore

### Clean restart

Use the normal stop commands, then the exact start commands. Require unchanged
tip hash, validated count, wallet balance, configured peer, and explorer
summary before mining the next hourly block.

### Hard-kill

Do this once after day 2 and once after day 20, while the listener is idle:

```sh
kill -KILL "$(cat "$RUN/listen.pid")"
rm -f "$RUN/listen.pid"
"$C" status --testnet --data-dir "$DATA" | tee "$LOG/status-after-kill.out"
```

Restart the listener with the exact start command, sync, and require agreement
with the other machine. SQLite recovery must not lose the last validated tip or
wallet rows. Do not hard-kill both machines in the same window.

### Offline backup

A consistent backup is taken only while the listener and explorer are stopped
and no `mine`, `sync`, `send`, `commit`, or `reveal` command is running:

```sh
# Run the normal stop commands first.
stamp=$(date -u +%Y%m%dT%H%M%SZ)
tar -C "$(dirname "$DATA")" -czf "$BACKUPS/$stamp.tgz" "$(basename "$DATA")"
chmod 0600 "$BACKUPS/$stamp.tgz"
sha256sum "$BACKUPS/$stamp.tgz" >"$BACKUPS/$stamp.tgz.sha256"
```

The archive is secret because it contains `wallet/wallet.key` and possibly
unrevealed commitment blinds. Keep it local and delete it at the end.

### Restore drill

Stop processes, choose one backup, and preserve the failed state until the
restored node has been checked:

```sh
export ARCHIVE=$BACKUPS/REPLACE_WITH_BACKUP.tgz
sha256sum -c "$ARCHIVE.sha256"
mv "$DATA" "$DATA.failed.$(date -u +%Y%m%dT%H%M%SZ)"
tar -C "$(dirname "$DATA")" -xzf "$ARCHIVE"
chmod 0700 "$DATA/wallet"
chmod 0600 "$DATA/wallet/wallet.key"
"$C" status --testnet --data-dir "$DATA" | tee "$LOG/status-restored.out"
"$C" balance --testnet --data-dir "$DATA" | tee "$LOG/balance-restored.out"
```

Restart, sync from the other machine, compare tip and balance, then check every
explorer endpoint above. Remove the preserved failed directory only after the
comparison passes.

## Evidence schedule

- Daily: tip/hash/body agreement, peer test, next puzzle/C, balances, listener
  and explorer liveness, and blocks produced versus 24 planned UTC slots.
- Every 16 blocks: record old/new C and the difficulty JSON window.
- Before day 7: H16 retarget, H100 maturity, transfer, commit/reveal/co-op/Q,
  one reorg, one clean restart, one hard-kill, one backup/restore, and the full
  explorer route check.
- Days 8-20: steady one-hour operation, at least one contributor rotation, and
  daily restart of one process without simultaneous downtime.
- Days 21-27: repeat reorg, hard-kill, and restore drills using a newer backup.
- Days 28-30: no new fault injection; observe stability and assemble evidence.

## Day-7 checkpoint

Continue only if all of these are true:

1. Both nodes have the same active tip and all advertised bodies validate.
2. At least 90% of the planned hourly slots produced exactly one block, with no
   catch-up burst.
3. H16 retarget evidence agrees on both nodes and historical C queries are
   stable.
4. H1 is immature at H99 and spendable at H100; a `tsgl1` transfer confirms.
5. A commitment at H and reveal at H+1 produce non-zero Q and positive
   contributor and carrier payouts.
6. The reorg, clean restart, hard-kill, offline backup, and restore checks pass.
7. Summary, block/PBE, score/Q, co-op split, difficulty, and `tsgl` address
   routes return correct HTML/JSON, remain read-only, and escape hostile text.
8. No seed, unknown peer, public listener, public explorer, secret disclosure,
   unrecovered database error, or unexplained balance/tip disagreement occurred.

Stop the run and preserve logs if any item fails. Do not waive it as a transient
failure without reproducing and explaining it.

## Day-30 exit criteria

The private testnet is successful only if:

- it ran for 30 consecutive days with at least 90% of 720 planned hourly slots
  and no duplicate catch-up mining;
- both nodes finish on the same active tip, with the same validated body count,
  next complexity, UTXO-derived balances, and no validation backlog;
- every observed 16-block retarget and the H100 maturity boundary was correct;
- at least two commit/reveal/co-op cycles from distinct periods paid a share and
  carrier with non-zero Q;
- both reorg drills, both hard-kills, clean restarts, and both restore drills
  recovered without manual database editing or lost wallet state;
- explorer summary, canonical block/PBE/Q/co-op, difficulty, and `tsgl` address
  HTML/JSON stayed correct, read-only, and XSS-safe;
- only the two approved IP peers appeared, TCP/19446 remained restricted, and
  no public DNS, TLS endpoint, seed, explorer exposure, automated push, key, or
  backup escaped the test boundary.

Archive sanitized logs only. The testnet database, wallet keys, commitment
blinds, and backups are disposable and are not launch artifacts.

## Final cleanup

On each machine, run the normal stop commands, verify no process remains, then
destroy all private-testnet state and secret backups:

```sh
if pgrep -af 'sigilcoin(-explorer)?.*--testnet'; then
  printf 'refusing cleanup: private-testnet processes are still running\n' >&2
  exit 1
fi
printf 'deleting disposable private-testnet state: %s\n' "$DATA"
rm -rf -- "${DATA:?}" "${RUN:?}" "${LOG:?}" "${BACKUPS:?}"
```

Never delete the state directory while a node or explorer still has its
SQLite database open.

For a quick pre-run integration check that never leaves loopback and cleans its
keys automatically:

```sh
bash tools/private-testnet-smoke.sh --bin-dir "$PWD/build/dev/bin"
```

Use `--keep` only for debugging; it preserves disposable wallet keys and prints
a warning. The smoke check proves chain selection, manual peer sync, `tsgl`
address routing, and explorer summary. It does not replace the 30-day run.
