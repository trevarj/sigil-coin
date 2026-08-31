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

Runs bounded two-node SigilCoin regtest drill. --keep preserves temporary state.
Preserved wallet keys are disposable test keys. An explicit --state-dir is
preserved and must be empty.
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

[[ $base_port =~ ^[0-9]+$ ]] && ((base_port > 1024 && base_port < 65533)) || {
  echo "local-testnet: --base-port must be in 1025..65532" >&2
  exit 2
}

for command in nix curl jq timeout awk grep date find; do
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
logs=$state/logs
http=$state/http
transcript=$state/transcript.log
mkdir -p "$node_a" "$node_b" "$logs" "$http"
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

if [[ -z $bin_dir ]]; then
  out=$(nix --offline build "$root/deploy#sigilcoin" --no-link --print-out-paths)
  bin_dir=$out/bin
fi
coin=$bin_dir/sigilcoin
explorer=$bin_dir/sigilcoin-explorer
[[ -x $coin && -x $explorer ]] || {
  echo "local-testnet: canonical binaries missing under $bin_dir" >&2
  exit 1
}

helper_dir=$root/tools/local-testnet
sigil=$workspace/sigil/build/dev/bin/sigil
[[ -x $sigil ]] || {
  echo "local-testnet: development Sigil binary missing: $sigil" >&2
  exit 1
}
helper=$helper_dir/build/dev/bin/sigil-coin-local-testnet
if [[ ! -x $helper || -n $(find "$helper_dir/src" "$helper_dir/package.sgl" -newer "$helper" -print -quit) ]]; then
  if [[ ! -d $helper_dir/.sigil/deps/sigil-crypto ]]; then
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
port_explorer=$((base_port + 2))
for port in "$port_a" "$port_b" "$port_explorer"; do
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

sync_b() {
  local expected=$1 output=$2
  show "$coin" sync --regtest --data-dir "$node_b" --peer "127.0.0.1:$port_a" \
    --max-steps 4096 --max-blocks 256 --iterations 1 \
    --resolve-timeout 1000 --connect-timeout 3000 --read-timeout 10000 \
    | tee "$output" >/dev/null
  require_line "$output" "^best-block-height: $expected$"
}

start_epoch=$(date +%s)
say "SigilCoin local testnet drill"
say "state: $state"
say "binaries: $bin_dir"
show "$coin" version
show "$explorer" --version

show "$coin" address --regtest --data-dir "$node_a" | tee "$logs/address-a.out" >/dev/null
show "$coin" address --regtest --data-dir "$node_b" | tee "$logs/address-b.out" >/dev/null
address_a=$(field "$logs/address-a.out" address)
address_b=$(field "$logs/address-b.out" address)
[[ $address_a == sgl1* && $address_b == sgl1* && $address_a != "$address_b" ]]
say "wallets: A=$address_a B=$address_b"

show "$coin" puzzle --regtest --data-dir "$node_a" | tee "$logs/puzzle-h1.out" >/dev/null
require_line "$logs/puzzle-h1.out" '^fallback: '
show "$coin" mine --regtest --data-dir "$node_a" --graffiti "local-testnet H1" \
  | tee "$logs/mine-h1.out" >/dev/null
require_line "$logs/mine-h1.out" '^submitted: yes$'

for height in $(seq 2 14); do
  timeout 120 "$coin" mine --regtest --data-dir "$node_a" >/dev/null
done
timeout 120 "$coin" puzzle --regtest --data-dir "$node_a" >"$logs/puzzle-h15.out"
c15=$(awk '/^complexity:/{print $2}' "$logs/puzzle-h15.out")
timeout 120 "$coin" mine --regtest --data-dir "$node_a" >/dev/null
show "$coin" puzzle --regtest --data-dir "$node_a" | tee "$logs/puzzle-h16.out" >/dev/null
c16=$(awk '/^complexity:/{print $2}' "$logs/puzzle-h16.out")
[[ $c16 != "$c15" ]] || { echo "local-testnet: height-16 retarget did not move C" >&2; exit 1; }
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

start_listener "$node_a" "$port_a" "$logs/listen-a-h99.log"
sync_b 99 "$logs/sync-b-h99.out"
stop_process "$listener_pid"
pids=("${pids[@]/$listener_pid}")
say "contributor B synced to producer A at H99"

show "$coin" puzzle --share --regtest --data-dir "$node_b" \
  | tee "$logs/share-puzzle-h100.out" >/dev/null
share_solution=$(timeout 120 "$helper" solve-share "$node_b")
say "test fixture solution: ${#share_solution} bytes (solver only; aggregation and mining stay in canonical CLI)"
show "$coin" mine --share --solution "$share_solution" --regtest --data-dir "$node_b" \
  | tee "$logs/share-mine-h100.out" >/dev/null
require_line "$logs/share-mine-h100.out" '^share-eligible: yes$'
require_line "$logs/share-mine-h100.out" '^submitted: no$'

show "$coin" commit --solution "$share_solution" --regtest --data-dir "$node_b" \
  | tee "$logs/commit-1.out" >/dev/null
show "$coin" commit --solution "$share_solution" --regtest --data-dir "$node_b" \
  | tee "$logs/commit-2.out" >/dev/null
commit_1=$(field "$logs/commit-1.out" commitment)
commit_2=$(field "$logs/commit-2.out" commitment)
commits_push=$(field "$logs/commit-2.out" commits-push)
[[ -n $commits_push && $commit_1 != "$commit_2" ]]
show "$coin" mine --regtest --data-dir "$node_a" --commit "$commits_push" \
  --graffiti "H100 carries contributor commits" \
  | tee "$logs/mine-h100.out" >/dev/null
[[ $(field "$logs/mine-h100.out" height) == 100 ]]
require_line "$logs/mine-h100.out" "^accepted-commitment: $commit_1$"
require_line "$logs/mine-h100.out" "^accepted-commitment: $commit_2$"
[[ $(grep -c '^accepted-commitment:' "$logs/mine-h100.out") == 2 ]]

show "$coin" balance --regtest --data-dir "$node_a" | tee "$logs/balance-mature.out" >/dev/null
[[ $(field "$logs/balance-mature.out" spendable) != "0.00000000 SGL" ]] || {
  echo "local-testnet: H1 reward did not mature by tip 100" >&2
  exit 1
}
show "$coin" send --to "$address_b" --amount 0.50000000 --fee 0.00001000 \
  --regtest --data-dir "$node_a" | tee "$logs/send.out" >/dev/null
require_line "$logs/send.out" '^status: available \(unconfirmed\)$'
txid=$(field "$logs/send.out" txid)

start_listener "$node_a" "$port_a" "$logs/listen-a-h100.log"
sync_b 100 "$logs/sync-b-h100.out"
stop_process "$listener_pid"
pids=("${pids[@]/$listener_pid}")
show "$coin" reveal --height 100 --regtest --data-dir "$node_b" \
  | tee "$logs/reveal-h100.out" >/dev/null
shares_push=$(field "$logs/reveal-h100.out" shares-push)
share_pubkey=$(field "$logs/reveal-h100.out" pubkey)
reveal_q=$(field "$logs/reveal-h100.out" quality)
[[ -n $shares_push && -n $share_pubkey && $reveal_q =~ ^[1-9][0-9]*$ ]]
show "$coin" mine --regtest --data-dir "$node_a" --reveal "$shares_push" \
  --graffiti "H101 carries contributor reveal" \
  | tee "$logs/mine-h101.out" >/dev/null
require_line "$logs/mine-h101.out" '^height: 101$'
require_line "$logs/mine-h101.out" "^accepted-share: $share_pubkey quality=$reveal_q$"
q=$(field "$logs/mine-h101.out" aggregate-q)
[[ $q == "$reveal_q" ]]
require_line "$logs/mine-h101.out" "^payout: role=share id=$share_pubkey value=[1-9][0-9]*\\.[0-9]{8} SGL$"
require_line "$logs/mine-h101.out" '^payout: role=carrier value=[1-9][0-9]*\.[0-9]{8} SGL$'
require_line "$logs/mine-h101.out" '^transactions: 1$'
say "co-op CLI: B commit output -> A mine H100; B reveal output -> A mine H101; Q=$q, share/carrier payouts and tx $txid verified"

start_explorer
start_listener "$node_a" "$port_a" "$logs/listen-a-1.log"
say "processes: node A listener + node B sync + explorer on loopback"
sync_b 101 "$logs/sync-b-h101.out"

stop_process "$listener_pid"
pids=("${pids[@]/$listener_pid}")
show "$coin" status --regtest --data-dir "$node_a" | tee "$logs/reopen-a.out" >/dev/null
require_line "$logs/reopen-a.out" '^best-block-height: 101$'
show "$coin" mine --regtest --data-dir "$node_a" --graffiti "durable restart parent" \
  | tee "$logs/mine-h102.out" >/dev/null
require_line "$logs/mine-h102.out" '^height: 102$'
say "restart: reopened durable H101 parent and mined H102"

start_listener "$node_a" "$port_a" "$logs/listen-a-2.log"
sync_b 102 "$logs/sync-b-final.out"
start_listener "$node_b" "$port_b" "$logs/listen-b.log"
say "live: node A 127.0.0.1:$port_a; node B 127.0.0.1:$port_b; explorer 127.0.0.1:$port_explorer"

show "$coin" status --regtest --data-dir "$node_a" >"$logs/status-a.out"
show "$coin" status --regtest --data-dir "$node_b" >"$logs/status-b.out"
timeout 120 "$coin" puzzle --regtest --data-dir "$node_a" >"$logs/puzzle-a-final.out"
timeout 120 "$coin" puzzle --regtest --data-dir "$node_b" >"$logs/puzzle-b-final.out"
for key in best-block-height best-block-hash validated-blocks blocks; do
  [[ $(field "$logs/status-a.out" "$key") == "$(field "$logs/status-b.out" "$key")" ]] || {
    echo "local-testnet: nodes disagree on $key" >&2
    exit 1
  }
done
ca=$(awk '/^complexity:/{print $2}' "$logs/puzzle-a-final.out")
cb=$(awk '/^complexity:/{print $2}' "$logs/puzzle-b-final.out")
[[ $ca == "$cb" ]]
require_line "$logs/status-a.out" '^best-block-height: 102$'
require_line "$logs/status-a.out" '^validated-blocks: 102$'
say "agreement: height=102 C(next)=$ca validated-bodies=102 tip=$(field "$logs/status-a.out" best-block-hash)"

show "$coin" balance --regtest --data-dir "$node_b" | tee "$logs/balance-b.out" >/dev/null
require_line "$logs/balance-b.out" '^outputs: 2$'
require_line "$logs/balance-b.out" '^spendable: 0\.50000000 SGL$'
require_line "$logs/balance-b.out" '^immature: [1-9][0-9]*\.[0-9]{8} SGL$'

base_url=http://127.0.0.1:$port_explorer
for endpoint in summary block/100 block/101 difficulty "address/$address_b"; do
  curl -fsS --max-time 10 "$base_url/api/$endpoint" >"$http/${endpoint//\//-}.json"
done
jq -e '.tip_height == 102 and .block_count == 102 and .chain == "sigilcoin-regtest"' \
  "$http/summary.json" >/dev/null
jq -e '.height == 100 and .commitments == 2' "$http/block-100.json" >/dev/null
jq -e --arg contributor "$address_b" --arg producer "$address_a" --argjson q "$q" \
  '.height == 101 and .share_count == 1 and .score.quality == $q and
   .transactions == 2 and
   any(.outputs[]; .role == "share" and .address == $contributor and .value > 0) and
   any(.outputs[]; .role == "carrier" and .address == $producer and .value > 0)' \
  "$http/block-101.json" >/dev/null
share_payout=$(jq -r --arg address "$address_b" \
  '.outputs[] | select(.role == "share" and .address == $address) | .value' \
  "$http/block-101.json")
[[ $share_payout =~ ^[1-9][0-9]*$ ]]
jq -e '.history | length > 0' "$http/difficulty.json" >/dev/null
jq -e --arg address "$address_b" --argjson expected "$((50000000 + share_payout))" \
  '.address == $address and .balance == $expected' \
  "$http/address-${address_b}.json" >/dev/null
say "explorer JSON: summary, block/100, block/101, difficulty, address all approved"

runtime=$(($(date +%s) - start_epoch))
say "PASS runtime=${runtime}s state=$state"
