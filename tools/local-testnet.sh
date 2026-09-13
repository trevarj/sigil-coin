#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(cd "$root/.." && pwd)
keep=0
state=""
base_port=$((24000 + $$ % 12000))
bin_dir=${SIGILCOIN_BIN_DIR:-}

usage() {
  cat <<'EOF'
usage: tools/local-testnet.sh [--keep] [--state-dir DIR] [--base-port PORT] [--bin-dir DIR]

Runs a bounded four-role SigilCoin regtest drill. --keep preserves temporary
state. Preserved wallet keys are disposable test keys. An explicit
--state-dir is preserved and must be empty.
EOF
}

while (($#)); do
  case $1 in
    --keep) keep=1; shift ;;
    --state-dir) state=${2:?--state-dir needs a directory}; keep=1; shift 2 ;;
    --base-port) base_port=${2:?--base-port needs a port}; shift 2 ;;
    --bin-dir) bin_dir=${2:?--bin-dir needs a directory}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ $base_port =~ ^[0-9]+$ ]] && ((base_port > 1024 && base_port < 65531)) || {
  echo "local-testnet: --base-port must be in 1025..65530" >&2
  exit 2
}

for command in nix curl jq timeout awk grep date find python3 ps; do
  command -v "$command" >/dev/null || {
    echo "local-testnet: missing prerequisite: $command" >&2
    exit 1
  }
done

made_temp=0
if [[ -z $state ]]; then
  state=$(mktemp -d "${TMPDIR:-/tmp}/sigilcoin-local-testnet.XXXXXX")
  made_temp=1
else
  mkdir -p "$state"
  [[ -z $(find "$state" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
    echo "local-testnet: --state-dir must be empty: $state" >&2
    exit 1
  }
  state=$(cd "$state" && pwd)
fi

node_a=$state/node-a
node_b=$state/node-b
node_c=$state/node-c
wallet_d=$state/contributor-d
pool_state=$state/pool
logs=$state/logs
http=$state/http
transcript=$state/transcript.log
mkdir -p "$node_a" "$node_b" "$node_c" "$wallet_d" "$pool_state" "$logs" "$http"
: >"$transcript"

pids=()
cleanup_done=0
cleanup() {
  ((cleanup_done)) && return 0
  cleanup_done=1
  local pid
  for pid in "${pids[@]:-}"; do
    [[ -n $pid ]] || continue
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]:-}"; do
    [[ -n $pid ]] || continue
    wait "$pid" 2>/dev/null || true
  done
  if ((keep)); then
    printf 'state preserved: %s\n' "$state"
  elif ((made_temp)); then
    rm -rf "$state"
  fi
}
on_signal() {
  local status=$1
  cleanup
  exit "$status"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

say() { printf '%s\n' "$*" | tee -a "$transcript"; }
show() {
  printf '+ ' | tee -a "$transcript"
  printf '%q ' "$@" | tee -a "$transcript"
  printf '\n' | tee -a "$transcript"
  timeout 120 "$@" | tee -a "$transcript"
}
field() { awk -F': ' -v key="$2" '$1 == key { print $2; exit }' "$1"; }
require_line() {
  grep -Eq "$2" "$1" || {
    echo "local-testnet: expected $2 in $1" >&2
    exit 1
  }
}
payout_field() {
  awk -v wanted="$2" '
    $1 == "payout:" {
      role = $2
      sub(/^role=/, "", role)
      if (role == wanted) {
        for (i = 3; i <= NF; i++) {
          if ($i ~ /^value=/) {
            sub(/^value=/, "", $i)
            print $i " SGL"
            exit
          }
        }
      }
    }
  ' "$1"
}
sgl_to_daviwils() {
  local amount=$1
  [[ $amount =~ ^[0-9]+\.[0-9]{8}\ SGL$ ]] || {
    echo "local-testnet: malformed SGL amount: $amount" >&2
    return 1
  }
  awk -v amount="$amount" 'BEGIN {
    sub(/ SGL$/, "", amount)
    split(amount, parts, /\./)
    printf "%.0f\n", parts[1] * 100000000 + parts[2]
  }'
}


if [[ -z $bin_dir ]]; then
  out=$(nix --offline build "$root/deploy#sigilcoin" \
    --override-input sigil "path:$workspace/sigil" \
    --override-input sigil-bitcoin "path:$workspace/sigil-bitcoin" \
    --no-link --print-out-paths)
  bin_dir=$out/bin
fi
coin=$bin_dir/sigilcoin
explorer=$bin_dir/sigilcoin-explorer
[[ -x $coin && -x $explorer ]] || {
  echo "local-testnet: canonical binaries missing under $bin_dir" >&2
  exit 1
}

helper_dir=$root/tools/local-testnet
sigil=$(command -v sigil || true)
[[ -n $sigil && -x $sigil ]] || {
  echo "local-testnet: sigil is not available on PATH" >&2
  exit 1
}
helper=$helper_dir/build/dev/bin/sigil-coin-local-testnet
if [[ ! -x $helper || -n $(find "$helper_dir/src" "$helper_dir/package.sgl" "$root/packages/sigil-coin-cli/src" -newer "$helper" -print -quit) ]]; then
  if [[ ! -d $helper_dir/.sigil/deps/sigil-crypto ||
        ! -d $helper_dir/.sigil/deps/sigil-http ||
        ! -d $helper_dir/.sigil/deps/sigil-json ||
        ! -d $helper_dir/.sigil/deps/sigil-coin-explorer ]]; then
    (cd "$helper_dir" &&
      nix --offline develop "$workspace" -c "$sigil" deps install \
        --redirects ./redirects.sgl >/dev/null)
  fi
  (cd "$helper_dir" &&
    nix --offline develop "$workspace" -c "$sigil" build \
      --redirects ./redirects.sgl >/dev/null)
fi
[[ -x $helper ]] || { echo "local-testnet: helper build failed" >&2; exit 1; }

port_a=$base_port
port_b=$((base_port + 1))
port_c=$((base_port + 2))
port_explorer=$((base_port + 3))
port_relay=$((base_port + 4))
for port in "$port_a" "$port_b" "$port_c" "$port_explorer" "$port_relay"; do
  if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
    echo "local-testnet: loopback port already in use: $port" >&2
    exit 1
  fi
done

start_listener() {
  local data_dir=$1 port=$2 log=$3
  timeout 900 "$coin" listen --regtest --data-dir "$data_dir" \
    --bind 127.0.0.1 --port "$port" --max-connections 0 \
    --accept-timeout 250 --read-timeout 10000 --max-steps 4096 --max-tx 256 \
    >"$log" 2>&1 &
  listener_pid=$!
  pids+=("$listener_pid")
  local i
  for i in $(seq 1 50); do
    kill -0 "$listener_pid" 2>/dev/null || {
      cat "$log" >&2
      return 1
    }
    if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "local-testnet: listener readiness timed out on $port" >&2
  return 1
}

stop_process() {
  local pid=$1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

start_explorer() {
  timeout 900 "$explorer" --regtest --data-dir "$node_a" \
    --host 127.0.0.1 --port "$port_explorer" >"$logs/explorer.log" 2>&1 &
  explorer_pid=$!
  pids+=("$explorer_pid")
  local i
  for i in $(seq 1 50); do
    kill -0 "$explorer_pid" 2>/dev/null || {
      cat "$logs/explorer.log" >&2
      return 1
    }
    if curl -fsS --max-time 1 "http://127.0.0.1:$port_explorer/api/summary" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "local-testnet: explorer readiness timed out" >&2
  return 1
}

sync_node() {
  local data_dir=$1 expected=$2 output=$3
  show "$coin" sync --regtest --data-dir "$data_dir" --peer "127.0.0.1:$port_a" \
    --max-steps 4096 --max-blocks 256 --iterations 1 \
    --resolve-timeout 1000 --connect-timeout 3000 --read-timeout 10000 \
    | tee "$output" >/dev/null
  require_line "$output" "^best-block-height: $expected$"
}

wait_json() {
  local url=$1 filter=$2 output=$3 label=$4
  local tmp="${output}.tmp" i
  for i in $(seq 1 60); do
    if curl --disable -fsS --connect-timeout 1 --max-time 2 --max-filesize 65536 \
         "$url" >"$tmp" 2>/dev/null &&
       jq -e "$filter" "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$output"
      return 0
    fi
    sleep 1
  done
  echo "local-testnet: timed out waiting for $label" >&2
  [[ -f $tmp ]] && cat "$tmp" >&2
  [[ -f $logs/relay.log ]] && cat "$logs/relay.log" >&2
  [[ -f $logs/contribute-d.log ]] && cat "$logs/contribute-d.log" >&2
  return 1
}

wait_log() {
  local file=$1 pattern=$2 label=$3 i
  for i in $(seq 1 60); do
    if [[ -f $file ]] && grep -Eq "$pattern" "$file"; then
      return 0
    fi
    sleep 1
  done
  echo "local-testnet: timed out waiting for $label" >&2
  [[ -f $file ]] && cat "$file" >&2
  return 1
}

wait_for_exit() {
  local pid=$1 log=$2 label=$3 i
  for i in $(seq 1 60); do
    if ! kill -0 "$pid" 2>/dev/null; then
      if wait "$pid"; then
        return 0
      fi
      echo "local-testnet: $label failed" >&2
      cat "$log" >&2
      return 1
    fi
    sleep 1
  done
  echo "local-testnet: timed out waiting for $label" >&2
  cat "$log" >&2
  return 1
}

forget_pid() {
  local target=$1 pid
  local remaining=()
  for pid in "${pids[@]:-}"; do
    [[ -n $pid && $pid != "$target" ]] && remaining+=("$pid")
  done
  pids=("${remaining[@]}")
}

require_secret_absent() {
  local value=$1 file=$2 label=$3
  [[ -z $value || ! -f $file ]] && return 0
  if grep -Fqa -- "$value" "$file"; then
    echo "local-testnet: private $label leaked into $file" >&2
    return 1
  fi
}

start_epoch=$(date +%s)
say "SigilCoin local testnet drill"
say "state: $state"
say "binaries: $bin_dir"
show "$coin" version
show "$explorer" --version

show "$coin" address --regtest --data-dir "$node_a" | tee "$logs/address-a.out" >/dev/null
show "$coin" address --regtest --data-dir "$node_b" | tee "$logs/address-b.out" >/dev/null
show "$coin" address --regtest --data-dir "$node_c" | tee "$logs/address-c.out" >/dev/null
address_a=$(field "$logs/address-a.out" address)
address_b=$(field "$logs/address-b.out" address)
address_c=$(field "$logs/address-c.out" address)
[[ $address_a == sgl1* && $address_b == sgl1* && $address_c == sgl1* ]]
[[ $address_a != "$address_b" && $address_a != "$address_c" && $address_b != "$address_c" ]]
say "full-node wallets: producer A=$address_a sender B=$address_b recipient C=$address_c"

show "$coin" puzzle --regtest --data-dir "$node_a" | tee "$logs/puzzle-h1.out" >/dev/null
require_line "$logs/puzzle-h1.out" '^par-witness: '
show "$coin" mine --regtest --data-dir "$node_a" \
  | tee "$logs/mine-h1.out" >/dev/null
require_line "$logs/mine-h1.out" '^submitted: yes$'
require_line "$logs/mine-h1.out" '^savings: 0$'
require_line "$logs/mine-h1.out" '^block-score: 1$'
show "$coin" balance --regtest --data-dir "$node_a" \
  | tee "$logs/balance-a-h1.out" >/dev/null
require_line "$logs/balance-a-h1.out" '^balance: 0\.80000000 SGL$'
require_line "$logs/balance-a-h1.out" '^spendable: 0\.80000000 SGL$'
require_line "$logs/balance-a-h1.out" '^immature: 0\.00000000 SGL$'
say "maturity: H1 reward is spendable in candidate H2"

for height in $(seq 2 14); do
  timeout 120 "$coin" mine --regtest --data-dir "$node_a" >/dev/null
done
timeout 120 "$coin" puzzle --regtest --data-dir "$node_a" >"$logs/puzzle-h15.out"
c15=$(awk '/^complexity:/{print $2}' "$logs/puzzle-h15.out")
timeout 120 "$coin" mine --regtest --data-dir "$node_a" >/dev/null
show "$coin" puzzle --regtest --data-dir "$node_a" | tee "$logs/puzzle-h16.out" >/dev/null
c16=$(awk '/^complexity:/{print $2}' "$logs/puzzle-h16.out")
[[ $c16 != "$c15" ]] || {
  echo "local-testnet: height-16 retarget did not move C" >&2
  exit 1
}
show "$coin" mine --regtest --data-dir "$node_a" | tee "$logs/mine-h16.out" >/dev/null
[[ $(field "$logs/mine-h16.out" height) == 16 ]]
timeout 120 "$coin" puzzle --regtest --data-dir "$node_a" >"$logs/puzzle-h17.out"
c17=$(awk '/^complexity:/{print $2}' "$logs/puzzle-h17.out")
say "retarget: C(H15)=$c15 C(H16)=$c16 C(H17)=$c17"

for height in $(seq 17 99); do
  timeout 120 "$coin" mine --regtest --data-dir "$node_a" >/dev/null
  if ((height % 20 == 0)); then say "producer-only progress: height $height"; fi
done

show "$coin" puzzle --height 15 --regtest --data-dir "$node_a" \
  | tee "$logs/puzzle-h15-historical.out" >/dev/null
show "$coin" puzzle --height 16 --regtest --data-dir "$node_a" \
  | tee "$logs/puzzle-h16-historical.out" >/dev/null
show "$coin" puzzle --height 17 --regtest --data-dir "$node_a" \
  | tee "$logs/puzzle-h17-historical.out" >/dev/null
[[ $(awk '/^complexity:/{print $2}' "$logs/puzzle-h15-historical.out") == "$c15" ]]
[[ $(awk '/^complexity:/{print $2}' "$logs/puzzle-h16-historical.out") == "$c16" ]]
[[ $(awk '/^complexity:/{print $2}' "$logs/puzzle-h17-historical.out") == "$c17" ]]
say "historical retarget: tip=99 still reports C(H15)=$c15 C(H16)=$c16 C(H17)=$c17"

relay_url=http://127.0.0.1:$port_relay
timeout 900 "$coin" relay serve --regtest --data-dir "$node_a" \
  --state-dir "$pool_state" --host 127.0.0.1 --port "$port_relay" \
  >"$logs/relay.log" 2>&1 &
relay_pid=$!
pids+=("$relay_pid")
wait_json "$relay_url/healthz" 'type == "object"' "$http/relay-health.json" "relay health"
wait_json "$relay_url/v1/context" \
  '.version == 1 and .chain == "sigilcoin-regtest" and .height == 100 and
   .capacity == 16 and .accepted == 0 and
   (.parent_id | type == "string" and test("^[0-9a-f]{64}$")) and
   (.complexity | type == "number")' \
  "$http/context-h100.json" "relay H100 context"
parent_h100=$(jq -r '.parent_id' "$http/context-h100.json")
complexity_h100=$(jq -r '.complexity' "$http/context-h100.json")
say "relay: $relay_url serves validated H100 context from A"

share_solution=$(timeout 120 "$helper" solve-relay-share "$relay_url" "$wallet_d")
[[ -n $share_solution && ${#share_solution} -le 512 ]]
show "$coin" address --regtest --data-dir "$wallet_d" \
  | tee "$logs/address-d.out" >/dev/null
address_d=$(field "$logs/address-d.out" address)
[[ $address_d == sgl1* && $address_d != "$address_a" &&
   $address_d != "$address_b" && $address_d != "$address_c" ]]
say "light wallet D=$address_d has no node and solved ${#share_solution} bytes locally"

say "+ $coin contribute --relay $relay_url --data-dir $wallet_d --regtest (solution on stdin)"
printf '%s\n' "$share_solution" |
  timeout 300 "$coin" contribute --relay "$relay_url" \
    --data-dir "$wallet_d" --regtest >"$logs/contribute-d.log" 2>&1 &
contributor_pid=$!
pids+=("$contributor_pid")

wait_json "$relay_url/v1/producer" \
  '.version == 1 and .chain == "sigilcoin-regtest" and .height == 100 and
   (.commitments | length) == 1 and (.reveals | length) == 0' \
  "$http/producer-h100.json" "D commitment at producer"
commitment=$(jq -r '.commitments[0]' "$http/producer-h100.json")
[[ $commitment =~ ^[0-9a-f]{64}$ ]]
wait_json "$relay_url/v1/contributions/$commitment" \
  '.version == 1 and .status == "queued" and .height == 100 and
   .tip_height == 99 and .commit_block_id == null and .reveal_block_id == null' \
  "$http/status-d-queued.json" "D queued receipt"

commit_file=$wallet_d/wallet/commitments
wait_log "$commit_file" '^[0-9]+ ' "D private commitment record"
[[ $(awk 'NF { count++ } END { print count + 0 }' "$commit_file") == 1 ]]
read -r record_height record_complexity record_parent share_pubkey \
  record_blind record_commitment record_solution_hex record_extra <"$commit_file"
[[ -z ${record_extra:-} && $record_height == 100 &&
   $record_complexity == "$complexity_h100" &&
   $record_commitment == "$commitment" &&
   $record_parent =~ ^[0-9a-f]{64}$ &&
   $share_pubkey =~ ^0[23][0-9a-f]{64}$ &&
   $record_blind =~ ^[0-9a-f]{64}$ &&
   $record_solution_hex =~ ^[0-9a-f]+$ ]]

ps -ww -eo args= |
  awk -v needle="$wallet_d" 'index($0, needle) > 0' >"$logs/contribute-d.argv"
require_line "$logs/contribute-d.argv" 'sigilcoin contribute'
if grep -Fq -- '--solution' "$logs/contribute-d.argv"; then
  echo "local-testnet: contributor source was passed on argv" >&2
  exit 1
fi

pool_db=$pool_state/sigilcoin-pool.sqlite
python3 - "$pool_db" "$wallet_d/wallet/wallet.key" "$commit_file" \
  "$logs/relay.log" "$logs/contribute-d.log" "$logs/contribute-d.argv" \
  >"$logs/pool-phase-one.out" <<'PY'
import sqlite3
import sys
from pathlib import Path
from urllib.parse import quote

db_path, key_path, record_path, *logs = sys.argv[1:]
uri = "file:" + quote(str(Path(db_path).resolve()), safe="/") + "?mode=ro"
db = sqlite3.connect(uri, uri=True)
metadata = db.execute(
    "SELECT value FROM metadata WHERE key = 'schema-version'"
).fetchone()
assert metadata == ("1",)
expected = [
    "sequence", "commitment", "height", "parent_hash", "complexity",
    "pubkey", "authorization", "source_ip", "received_at", "share_hex",
    "contribution", "revealed_at", "reveal_attempt_hash",
    "reveal_attempt_error", "reveal_attempts",
]
columns = [row[1] for row in db.execute("PRAGMA table_info(contributions)")]
assert columns == expected, columns
rows = db.execute(
    "SELECT sequence, commitment, height, parent_hash, complexity, pubkey, "
    "authorization, source_ip, share_hex, contribution, revealed_at, "
    "reveal_attempt_hash, reveal_attempt_error, reveal_attempts "
    "FROM contributions"
).fetchall()
assert len(rows) == 1
row = rows[0]
assert row[0] == 1 and len(row[1]) == 64 and row[2] == 100
assert len(row[3]) == 64 and isinstance(row[4], int)
assert len(row[5]) == 66 and len(row[6]) == 128 and row[7] == "127.0.0.1"
assert row[8:13] == (None, None, None, None, None) and row[13] == 0
db.close()

key_hex = Path(key_path).read_text().strip()
fields = Path(record_path).read_text().strip().split()
assert len(fields) == 7
secret_bytes = [
    bytes.fromhex(key_hex),
    key_hex.encode(),
    bytes.fromhex(fields[4]),
    fields[4].encode(),
    bytes.fromhex(fields[6]),
    fields[6].encode(),
]
targets = [Path(db_path), Path(db_path + "-wal"), Path(db_path + "-shm")]
targets.extend(Path(path) for path in logs)
for target in targets:
    if not target.exists():
        continue
    data = target.read_bytes()
    assert all(secret not in data for secret in secret_bytes), target

print("rows: 1")
print("schema-version: 1")
print("phase-one-share: null")
print("private-material-found: no")
PY
require_line "$logs/pool-phase-one.out" '^rows: 1$'
require_line "$logs/pool-phase-one.out" '^schema-version: 1$'
require_line "$logs/pool-phase-one.out" '^phase-one-share: null$'
require_line "$logs/pool-phase-one.out" '^private-material-found: no$'
say "pool phase one: one public receipt; no key, blind, source, consensus share, or reveal signature stored/logged/argv"

show "$coin" mine --relay "$relay_url" --regtest --data-dir "$node_a" \
  | tee "$logs/mine-h100.out" >/dev/null
require_line "$logs/mine-h100.out" '^height: 100$'
require_line "$logs/mine-h100.out" "^accepted-commitment: $commitment$"
[[ $(grep -c '^accepted-commitment:' "$logs/mine-h100.out") == 1 ]]
block_h100=$(field "$logs/mine-h100.out" block-id)
[[ $block_h100 =~ ^[0-9a-f]{64}$ ]]

show "$coin" send --to "$address_b" --amount 0.50000000 --fee 0.00001000 \
  --regtest --data-dir "$node_a" | tee "$logs/send-a-b.out" >/dev/null
require_line "$logs/send-a-b.out" '^status: available \(unconfirmed\)$'
require_line "$logs/send-a-b.out" '^fee: 0\.00001000 SGL$'
txid_a_b=$(field "$logs/send-a-b.out" txid)

wait_json "$relay_url/v1/producer" \
  '.version == 1 and .chain == "sigilcoin-regtest" and .height == 101 and
   (.commitments | length) == 0 and (.reveals | length) == 1' \
  "$http/producer-h101.json" "D reveal at producer"
wait_json "$relay_url/v1/contributions/$commitment" \
  '.status == "reveal-queued" and .tip_height == 100 and
   (.commit_block_id | type == "string") and .reveal_block_id == null' \
  "$http/status-d-reveal-queued.json" "D reveal queue"
jq -e --arg block "$block_h100" \
  '.commit_block_id == $block' "$http/status-d-reveal-queued.json" >/dev/null

timeout 120 "$coin" puzzle --regtest --data-dir "$node_a" \
  >"$logs/puzzle-h101.out"
scheduled_h101=$(sgl_to_daviwils "$(field "$logs/puzzle-h101.out" reward)")
show "$coin" mine --relay "$relay_url" --regtest --data-dir "$node_a" \
  | tee "$logs/mine-h101.out" >/dev/null
require_line "$logs/mine-h101.out" '^height: 101$'
reveal_contribution=$(awk -v pubkey="$share_pubkey" '
  $1 == "accepted-share:" && $2 == pubkey {
    sub(/^contribution=/, "", $3)
    print $3
    exit
  }
' "$logs/mine-h101.out")
[[ $reveal_contribution =~ ^[1-4]$ ]]
require_line "$logs/mine-h101.out" \
  "^accepted-share: $share_pubkey contribution=$reveal_contribution$"
q=$(field "$logs/mine-h101.out" aggregate-q)
[[ $q == "$reveal_contribution" ]]
require_line "$logs/mine-h101.out" \
  "^payout: role=share id=$share_pubkey contribution=$q value=[1-9][0-9]*\\.[0-9]{8} SGL$"
require_line "$logs/mine-h101.out" \
  '^payout: role=carrier value=[1-9][0-9]*\.[0-9]{8} SGL$'
require_line "$logs/mine-h101.out" '^transactions: 1$'
block_h101=$(field "$logs/mine-h101.out" block-id)
show "$helper" assert-block-transaction "$node_a" 101 "$txid_a_b" \
  | tee "$logs/block-h101-tx.out" >/dev/null

fee_a_b=1000
share_pool=$((scheduled_h101 / 10))
carrier_target=$((scheduled_h101 / 20))
share_target=$share_pool
share_residual=$((share_pool - share_target))
producer_target=$((scheduled_h101 - carrier_target - share_pool))
producer_expected=$((producer_target + fee_a_b + share_residual))
minted_expected=$((scheduled_h101 + fee_a_b))
producer_paid=$(sgl_to_daviwils "$(payout_field "$logs/mine-h101.out" producer)")
share_paid=$(sgl_to_daviwils "$(payout_field "$logs/mine-h101.out" share)")
carrier_paid=$(sgl_to_daviwils "$(payout_field "$logs/mine-h101.out" carrier)")
minted=$(sgl_to_daviwils "$(field "$logs/mine-h101.out" minted)")
unminted=$(sgl_to_daviwils "$(field "$logs/mine-h101.out" unminted)")
[[ $producer_paid -eq $producer_expected ]]
[[ $share_paid -eq $share_target ]]
[[ $carrier_paid -eq $carrier_target ]]
[[ $minted -eq $minted_expected && $unminted -eq 0 ]]

wait_json "$relay_url/v1/contributions/$commitment" \
  '.status == "included" and .tip_height == 101 and
   (.commit_block_id | type == "string") and
   (.reveal_block_id | type == "string") and
   (.contribution | type == "number") and
   (.payout_daviwils | type == "number") and .matures_at_height == 102' \
  "$http/status-d-included.json" "D included receipt"
jq -e --arg commit_block "$block_h100" --arg reveal_block "$block_h101" \
  --arg pubkey "$share_pubkey" --argjson q "$q" --argjson payout "$share_paid" \
  '.commit_block_id == $commit_block and .reveal_block_id == $reveal_block and
   .pubkey == $pubkey and .contribution == $q and
   .payout_daviwils == $payout' \
  "$http/status-d-included.json" >/dev/null
wait_for_exit "$contributor_pid" "$logs/contribute-d.log" "D contributor watcher"
forget_pid "$contributor_pid"
require_line "$logs/contribute-d.log" '^status: queued$'
require_line "$logs/contribute-d.log" '^status: revealable$'
require_line "$logs/contribute-d.log" '^status: reveal-queued$'
require_line "$logs/contribute-d.log" '^status: included$'
require_line "$logs/contribute-d.log" "^height: 100$"
require_line "$logs/contribute-d.log" "^parent: $parent_h100$"
require_line "$logs/contribute-d.log" "^pubkey: $share_pubkey$"
require_line "$logs/contribute-d.log" '^personalized-par: [1-9][0-9]*$'
require_line "$logs/contribute-d.log" "^solution-length: ${#share_solution}$"
require_line "$logs/contribute-d.log" "^contribution: $q$"
require_line "$logs/contribute-d.log" "^commitment: $commitment$"
require_line "$logs/contribute-d.log" '^receipt: '
require_line "$logs/contribute-d.log" "^commit-block: $block_h100$"
require_line "$logs/contribute-d.log" "^reveal-block: $block_h101$"
require_line "$logs/contribute-d.log" '^payout: '
require_line "$logs/contribute-d.log" '^matures-at-height: 102$'
wallet_key=$(<"$wallet_d/wallet/wallet.key")
for private_file in "$logs/contribute-d.log" "$logs/contribute-d.argv"; do
  require_secret_absent "$share_solution" "$private_file" source
  require_secret_absent "$record_solution_hex" "$private_file" encoded-source
  require_secret_absent "$record_blind" "$private_file" blind
  require_secret_absent "$wallet_key" "$private_file" key
done
say "co-op: H100 committed D; H101 included D+A-to-B with Q=$q, direct weighted payout, carrier, fees/residual, and zero unminted"

start_listener "$node_a" "$port_a" "$logs/listen-a-for-b-h101.log"
sync_listener_pid=$listener_pid
sync_node "$node_b" 101 "$logs/sync-b-h101.out"
stop_process "$sync_listener_pid"
forget_pid "$sync_listener_pid"
show "$coin" balance --regtest --data-dir "$node_b" \
  | tee "$logs/balance-b-h101.out" >/dev/null
require_line "$logs/balance-b-h101.out" '^spendable: 0\.50000000 SGL$'

show "$coin" send --to "$address_c" --amount 0.25000000 --fee 0.00002000 \
  --regtest --data-dir "$node_b" | tee "$logs/send-b-c.out" >/dev/null
require_line "$logs/send-b-c.out" '^status: available \(unconfirmed\)$'
require_line "$logs/send-b-c.out" '^fee: 0\.00002000 SGL$'
txid_b_c=$(field "$logs/send-b-c.out" txid)
show "$coin" status --regtest --data-dir "$node_a" \
  | tee "$logs/status-a-before-relay.out" >/dev/null
show "$coin" status --regtest --data-dir "$node_b" \
  | tee "$logs/status-b-before-relay.out" >/dev/null
require_line "$logs/status-a-before-relay.out" '^mempool: 0$'
require_line "$logs/status-b-before-relay.out" '^mempool: 1$'

start_listener "$node_a" "$port_a" "$logs/listen-a-tx-relay.log"
tx_listener_pid=$listener_pid
show "$helper" relay-wallet-transaction "$node_b" 127.0.0.1 "$port_a" \
  | tee "$logs/relay-b-c.out" >/dev/null
[[ $(field "$logs/relay-b-c.out" txid) == "$txid_b_c" ]]
wait_log "$logs/listen-a-tx-relay.log" '^peer-served: ' "A serving B's tx envelope"
show "$coin" status --regtest --data-dir "$node_a" \
  | tee "$logs/status-a-after-relay.out" >/dev/null
require_line "$logs/status-a-after-relay.out" '^mempool: 1$'

python3 - "$node_a/sigilcoin-regtest.sqlite" "$txid_b_c" "$port_a" \
  >"$logs/a-peer-mempool.out" <<'PY'
import sqlite3
import sys

path, display_txid, port = sys.argv[1:]
internal_txid = bytes.fromhex(display_txid)[::-1].hex()
db = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
row = db.execute(
    "SELECT status, announced_by, tx_hex FROM mempool WHERE txid = ?",
    (internal_txid,),
).fetchone()
db.close()
assert row is not None
assert row[0] == "available" and row[1] == "inbound:" + port and row[2]
print("txid: " + display_txid)
print("source: peer")
print("status: available")
PY
require_line "$logs/a-peer-mempool.out" "^txid: $txid_b_c$"
require_line "$logs/a-peer-mempool.out" '^source: peer$'
stop_process "$tx_listener_pid"
forget_pid "$tx_listener_pid"
say "ordinary relay: B signed $txid_b_c; P2P handshake+tx envelope put it in A's peer-sourced mempool"

timeout 120 "$coin" puzzle --regtest --data-dir "$node_a" \
  >"$logs/puzzle-h102.out"
scheduled_h102=$(sgl_to_daviwils "$(field "$logs/puzzle-h102.out" reward)")
show "$coin" mine --regtest --data-dir "$node_a" \
  | tee "$logs/mine-h102.out" >/dev/null
require_line "$logs/mine-h102.out" '^height: 102$'
require_line "$logs/mine-h102.out" '^transactions: 1$'
block_h102=$(field "$logs/mine-h102.out" block-id)
show "$helper" assert-block-transaction "$node_a" 102 "$txid_b_c" \
  | tee "$logs/block-h102-tx.out" >/dev/null
fee_b_c=2000
producer_h102=$(sgl_to_daviwils "$(payout_field "$logs/mine-h102.out" producer)")
minted_h102=$(sgl_to_daviwils "$(field "$logs/mine-h102.out" minted)")
unminted_h102=$(sgl_to_daviwils "$(field "$logs/mine-h102.out" unminted)")
solo_h102=$((scheduled_h102 * 4 / 5))
[[ $producer_h102 -eq $((solo_h102 + fee_b_c)) ]]
[[ $minted_h102 -eq $((solo_h102 + fee_b_c)) ]]
[[ $unminted_h102 -eq $((scheduled_h102 - solo_h102)) ]]

start_listener "$node_a" "$port_a" "$logs/listen-a-sync-h102.log"
sync_listener_pid=$listener_pid
sync_node "$node_b" 102 "$logs/sync-b-h102.out"
sync_node "$node_c" 102 "$logs/sync-c-h102.out"
stop_process "$sync_listener_pid"
forget_pid "$sync_listener_pid"

show "$coin" status --regtest --data-dir "$node_a" \
  | tee "$logs/reopen-a-h102.out" >/dev/null
require_line "$logs/reopen-a-h102.out" '^best-block-height: 102$'
show "$coin" mine --regtest --data-dir "$node_a" \
  | tee "$logs/mine-h103.out" >/dev/null
require_line "$logs/mine-h103.out" '^height: 103$'
require_line "$logs/mine-h103.out" '^transactions: 0$'
block_h103=$(field "$logs/mine-h103.out" block-id)
say "restart: reopened durable H102 parent and mined H103"

start_listener "$node_a" "$port_a" "$logs/listen-a-final.log"
final_listener_pid=$listener_pid
sync_node "$node_b" 103 "$logs/sync-b-final.out"
sync_node "$node_c" 103 "$logs/sync-c-final.out"
stop_process "$final_listener_pid"
forget_pid "$final_listener_pid"

start_listener "$node_a" "$port_a" "$logs/listen-a-live.log"
live_a_pid=$listener_pid
start_listener "$node_b" "$port_b" "$logs/listen-b-live.log"
live_b_pid=$listener_pid
start_listener "$node_c" "$port_c" "$logs/listen-c-live.log"
live_c_pid=$listener_pid
say "live roles: A 127.0.0.1:$port_a B 127.0.0.1:$port_b C 127.0.0.1:$port_c D watcher complete relay 127.0.0.1:$port_relay"

for role in a b c; do
  data_var=node_$role
  data_dir=${!data_var}
  show "$coin" status --regtest --data-dir "$data_dir" \
    >"$logs/status-$role.out"
  timeout 120 "$coin" puzzle --regtest --data-dir "$data_dir" \
    >"$logs/puzzle-$role-final.out"
done
for role in b c; do
  for key in best-block-height best-block-hash best-chain-score validated-blocks blocks; do
    [[ $(field "$logs/status-a.out" "$key") == \
       "$(field "$logs/status-$role.out" "$key")" ]] || {
      echo "local-testnet: nodes A and ${role^^} disagree on $key" >&2
      exit 1
    }
  done
done
ca=$(awk '/^complexity:/{print $2}' "$logs/puzzle-a-final.out")
cb=$(awk '/^complexity:/{print $2}' "$logs/puzzle-b-final.out")
cc=$(awk '/^complexity:/{print $2}' "$logs/puzzle-c-final.out")
[[ $ca == "$cb" && $ca == "$cc" ]]
require_line "$logs/status-a.out" '^best-block-height: 103$'
require_line "$logs/status-a.out" '^best-chain-score: 103$'
require_line "$logs/status-a.out" '^validated-blocks: 103$'
say "agreement: A/B/C height=103 chain-score=103 C(next)=$ca validated-bodies=103 tip=$(field "$logs/status-a.out" best-block-hash)"

show "$coin" balance --regtest --data-dir "$node_a" \
  | tee "$logs/balance-a.out" >/dev/null
show "$coin" balance --regtest --data-dir "$node_b" \
  | tee "$logs/balance-b.out" >/dev/null
show "$coin" balance --regtest --data-dir "$node_c" \
  | tee "$logs/balance-c.out" >/dev/null
require_line "$logs/balance-b.out" '^outputs: 1$'
require_line "$logs/balance-b.out" '^balance: 0\.24998000 SGL$'
require_line "$logs/balance-b.out" '^spendable: 0\.24998000 SGL$'
require_line "$logs/balance-b.out" '^immature: 0\.00000000 SGL$'
require_line "$logs/balance-c.out" '^outputs: 1$'
require_line "$logs/balance-c.out" '^balance: 0\.25000000 SGL$'
require_line "$logs/balance-c.out" '^spendable: 0\.25000000 SGL$'
require_line "$logs/balance-c.out" '^immature: 0\.00000000 SGL$'

[[ -f $wallet_d/wallet/wallet.key ]]
[[ ! -e $wallet_d/wallet/commitments || ! -s $wallet_d/wallet/commitments ]]
[[ -z $(find "$wallet_d" -type f \
  ! -path "$wallet_d/wallet/wallet.key" \
  ! -path "$wallet_d/wallet/commitments" -print -quit) ]]
[[ -z $(find "$wallet_d" -name 'sigilcoin-*.sqlite*' -print -quit) ]]
say "node-free D: only private wallet/empty commitment state; no chain SQLite"

start_explorer
base_url=http://127.0.0.1:$port_explorer
for endpoint in summary block/100 block/101 block/102 block/103 difficulty \
  "address/$address_a" "address/$address_b" "address/$address_c" \
  "address/$address_d"; do
  curl --disable -fsS --connect-timeout 2 --max-time 10 --max-filesize 65536 \
    "$base_url/api/$endpoint" >"$http/${endpoint//\//-}.json"
done
jq -e '.tip_height == 103 and .block_count == 103 and
       .chain == "sigilcoin-regtest" and .chain_score == 103' \
  "$http/summary.json" >/dev/null
jq -e --arg id "$block_h100" \
  '.id == $id and .height == 100 and .commitments == 1' \
  "$http/block-100.json" >/dev/null
jq -e --arg id "$block_h101" --arg contributor "$address_d" \
  --arg producer "$address_a" --argjson q "$q" \
  '.id == $id and .height == 101 and .share_count == 1 and
   .share_quality == $q and .transactions == 2 and
   .golf.claimed_length == .golf.par and
   (.golf.claimed_length >= 1 and .golf.claimed_length <= 512) and
   .golf.savings == 0 and .golf.block_score == 1 and
   .golf.chain_score == 101 and
   any(.outputs[]; .role == "share" and .address == $contributor and .value > 0) and
   any(.outputs[]; .role == "carrier" and .address == $producer and .value > 0)' \
  "$http/block-101.json" >/dev/null
jq -e --arg id "$block_h102" \
  '.id == $id and .height == 102 and .transactions == 2' \
  "$http/block-102.json" >/dev/null
jq -e --arg id "$block_h103" \
  '.id == $id and .height == 103 and .transactions == 1' \
  "$http/block-103.json" >/dev/null
explorer_share_paid=$(jq -r --arg address "$address_d" \
  '.outputs[] | select(.role == "share" and .address == $address) | .value' \
  "$http/block-101.json")
[[ $explorer_share_paid == "$share_paid" ]]
jq -e '.history | length > 0' "$http/difficulty.json" >/dev/null

balance_a=$(sgl_to_daviwils "$(field "$logs/balance-a.out" balance)")
balance_b=$(sgl_to_daviwils "$(field "$logs/balance-b.out" balance)")
balance_c=$(sgl_to_daviwils "$(field "$logs/balance-c.out" balance)")
jq -e --arg address "$address_a" --argjson expected "$balance_a" \
  '.address == $address and .balance == $expected' \
  "$http/address-${address_a}.json" >/dev/null
jq -e --arg address "$address_b" --argjson expected "$balance_b" \
  '.address == $address and .balance == $expected' \
  "$http/address-${address_b}.json" >/dev/null
jq -e --arg address "$address_c" --argjson expected "$balance_c" \
  '.address == $address and .balance == $expected' \
  "$http/address-${address_c}.json" >/dev/null
jq -e --arg address "$address_d" --argjson expected "$share_paid" \
  '.address == $address and .balance == $expected' \
  "$http/address-${address_d}.json" >/dev/null

wait_json "$relay_url/v1/contributions/$commitment" \
  '.status == "included" and .tip_height == 103 and .matures_at_height == 102' \
  "$http/status-d-final.json" "D final canonical receipt"
say "explorer/accounting: exact H101 A-to-B and H102 B-to-C txids, fees, direct D payout, carrier, balances, and H103 restart approved"

runtime=$(($(date +%s) - start_epoch))
say "PASS four-role runtime=${runtime}s state=$state"
