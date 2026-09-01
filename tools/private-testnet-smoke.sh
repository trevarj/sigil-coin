#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bin_dir=${SIGILCOIN_BIN_DIR:-$root/build/dev/bin}
state=""
keep=0
base_port=$((29446 + $$ % 1000))

usage() {
  cat <<'EOF'
usage: tools/private-testnet-smoke.sh [--bin-dir DIR] [--state-dir DIR] [--base-port PORT] [--keep]

Runs a bounded, loopback-only two-node private-testnet smoke check. It creates
disposable testnet wallet keys. Never fund or reuse them outside this test.
EOF
}

while (($#)); do
  case $1 in
    --bin-dir) bin_dir=${2:?--bin-dir needs a directory}; shift 2 ;;
    --state-dir) state=${2:?--state-dir needs a directory}; keep=1; shift 2 ;;
    --base-port) base_port=${2:?--base-port needs a port}; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ ! $base_port =~ ^[0-9]+$ ]] ||
   ((base_port <= 1024 || base_port >= 65534)); then
  echo "private-testnet-smoke: --base-port must be in 1025..65533" >&2
  exit 2
fi

for command in curl jq timeout awk grep find; do
  command -v "$command" >/dev/null || {
    echo "private-testnet-smoke: missing prerequisite: $command" >&2
    exit 1
  }
done

coin=$bin_dir/sigilcoin
explorer=$bin_dir/sigilcoin-explorer
[[ -x $coin && -x $explorer ]] || {
  echo "private-testnet-smoke: expected sigilcoin and sigilcoin-explorer under $bin_dir" >&2
  exit 1
}

made_temp=0
if [[ -z $state ]]; then
  state=$(mktemp -d "${TMPDIR:-/tmp}/sigilcoin-private-testnet.XXXXXX")
  made_temp=1
else
  mkdir -p "$state"
  [[ -z $(find "$state" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
    echo "private-testnet-smoke: --state-dir must be empty: $state" >&2
    exit 1
  }
  state=$(cd "$state" && pwd)
fi

node_a=$state/node-a
node_b=$state/node-b
logs=$state/logs
mkdir -p "$node_a" "$node_b" "$logs"
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
    echo "state preserved at $state" >&2
    echo "WARNING: it contains disposable private-testnet wallet keys; never reuse or fund them." >&2
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

node_port=$base_port
explorer_port=$((base_port + 1))
for port in "$node_port" "$explorer_port"; do
  if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
    echo "private-testnet-smoke: loopback port already in use: $port" >&2
    exit 1
  fi
done

timeout 30 "$coin" address --testnet --data-dir "$node_a" >"$logs/address-a.out"
timeout 30 "$coin" address --testnet --data-dir "$node_b" >"$logs/address-b.out"
address_a=$(awk -F': ' '$1 == "address" { print $2; exit }' "$logs/address-a.out")
address_b=$(awk -F': ' '$1 == "address" { print $2; exit }' "$logs/address-b.out")
[[ $address_a == tsgl1* && $address_b == tsgl1* && $address_a != "$address_b" ]]

timeout 120 "$coin" listen --testnet --data-dir "$node_a" \
  --bind 127.0.0.1 --port "$node_port" --max-connections 0 \
  --accept-timeout 250 --read-timeout 5000 --max-steps 256 --max-tx 64 \
  >"$logs/listen-a.log" 2>&1 &
listener_pid=$!
pids+=("$listener_pid")

ready=0
for _ in $(seq 1 50); do
  kill -0 "$listener_pid" 2>/dev/null || break
  if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$node_port" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.1
done
((ready)) || { cat "$logs/listen-a.log" >&2; exit 1; }

timeout 30 "$coin" sync --testnet --data-dir "$node_b" \
  --peer "127.0.0.1:$node_port" --iterations 1 --max-steps 256 \
  --max-blocks 16 --resolve-timeout 1000 --connect-timeout 3000 \
  --read-timeout 5000 >"$logs/sync-b.out"
grep -q '^best-block-height: 0$' "$logs/sync-b.out"

timeout 120 "$explorer" --testnet --data-dir "$node_a" \
  --host 127.0.0.1 --port "$explorer_port" >"$logs/explorer.log" 2>&1 &
explorer_pid=$!
pids+=("$explorer_pid")

base_url=http://127.0.0.1:$explorer_port
ready=0
for _ in $(seq 1 50); do
  kill -0 "$explorer_pid" 2>/dev/null || break
  if curl -fsS --max-time 1 "$base_url/api/summary" >"$logs/summary.json" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.1
done
((ready)) || { cat "$logs/explorer.log" >&2; exit 1; }

jq -e '.chain == "sigilcoin-testnet" and .tip_height == 0' \
  "$logs/summary.json" >/dev/null
curl -fsS --max-time 5 "$base_url/api/address/$address_a" \
  | jq -e --arg address "$address_a" '.address == $address and .balance == 0' \
  >/dev/null

timeout 30 "$coin" status --testnet --data-dir "$node_a" >"$logs/status-a.out"
timeout 30 "$coin" status --testnet --data-dir "$node_b" >"$logs/status-b.out"
grep -q '^best-block-height: 0$' "$logs/status-a.out"
grep -q '^best-block-height: 0$' "$logs/status-b.out"

echo "PASS private-testnet loopback smoke: two tsgl wallets, manual peer sync, explorer chain/address"
