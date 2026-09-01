#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-local.sh [--mode testnet|mainnet] [--bin-dir DIR]

Build (or use) SigilCoin binaries, then keep a listener, bounded retrying sync
loop, and loopback explorer attached to this foreground terminal. State and
logs persist below deploy/ by default. Ctrl-C stops the complete stack.

Environment:
  MODE=testnet|mainnet       default: testnet
  BIN_DIR=/path/to/bin       skip the Nix build
  DATA_DIR, LOG_DIR, RUN_DIR override persistent paths
  PEER=HOST:PORT             optional outbound bootstrap peer
  P2P_BIND=127.0.0.1         loopback unless an exposure mode is acknowledged
  REMOTE_PEER_IP=IPv4        required only for peer-ip-allowlisted mode
  TESTNET_EXPOSURE_ACK=       empty, peer-ip-allowlisted, or public-testnet-approved
  P2P_PORT=19446|19444       selected by mode
  EXPLORER_PORT=8080         explorer remains on 127.0.0.1
  SYNC_INTERVAL=60           seconds between bounded sync passes

Mainnet additionally requires ALLOW_MAINNET=yes.
EOF
}

MODE=${MODE:-testnet}
BIN_DIR=${BIN_DIR:-}
while (($#)); do
  case $1 in
    --mode) (($# >= 2)) || { printf 'missing value for --mode\n' >&2; exit 64; }; MODE=$2; shift 2 ;;
    --bin-dir) (($# >= 2)) || { printf 'missing value for --bin-dir\n' >&2; exit 64; }; BIN_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

allow_mainnet=${ALLOW_MAINNET:-no}
[[ $allow_mainnet == yes || $allow_mainnet == no ]] || {
  printf 'ALLOW_MAINNET must be exactly yes or no\n' >&2
  exit 64
}
case $MODE in
  testnet)
    chain_args=(--testnet)
    default_port=19446
    ;;
  mainnet)
    if [[ $allow_mainnet != yes ]]; then
      printf 'refusing mainnet: set ALLOW_MAINNET=yes only after final genesis approval\n' >&2
      exit 64
    fi
    chain_args=()
    default_port=19444
    ;;
  *) printf 'MODE must be testnet or mainnet\n' >&2; exit 64 ;;
esac

is_ipv4() {
  local address=$1 octet
  [[ $address =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do ((10#$octet <= 255)) || return 1; done
}

is_remote_ipv4() {
  local address=$1 first_octet
  is_ipv4 "$address" || return 1
  first_octet=${address%%.*}
  ((10#$first_octet > 0 && 10#$first_octet != 127 && 10#$first_octet < 224))
}

P2P_BIND=${P2P_BIND:-127.0.0.1}
if [[ $MODE == testnet ]]; then
  exposure_ack=${TESTNET_EXPOSURE_ACK:-}
  case $exposure_ack in
    ''|peer-ip-allowlisted|public-testnet-approved) ;;
    *)
      printf 'invalid TESTNET_EXPOSURE_ACK (expected empty, peer-ip-allowlisted, or public-testnet-approved)\n' >&2
      exit 64
      ;;
  esac
  case $P2P_BIND in
    127.*) is_ipv4 "$P2P_BIND" || { printf 'invalid loopback P2P bind\n' >&2; exit 64; } ;;
    ::1) ;;
    *)
      is_ipv4 "$P2P_BIND" || { printf 'non-loopback P2P bind must be an IPv4 literal\n' >&2; exit 64; }
      case $exposure_ack in
        peer-ip-allowlisted)
          is_remote_ipv4 "${REMOTE_PEER_IP:-}" || {
            printf 'refusing allowlisted testnet bind: REMOTE_PEER_IP must be a unicast IPv4 literal\n' >&2
            exit 64
          }
          if [[ -n ${PEER:-} && ${PEER%%:*} != "$REMOTE_PEER_IP" ]]; then
            printf 'refusing allowlisted testnet exposure: PEER host must match REMOTE_PEER_IP\n' >&2
            exit 64
          fi
          ;;
        public-testnet-approved) ;;
        *)
          printf 'refusing non-loopback testnet bind: select an explicit TESTNET_EXPOSURE_ACK mode\n' >&2
          exit 64
          ;;
      esac
      ;;
  esac
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$script_dir/../.." && pwd)
workspace=$(cd -- "$root/.." && pwd)
script_path=$script_dir/run-local.sh

if [[ -z $BIN_DIR ]]; then
  command -v nix >/dev/null || { printf 'nix is required unless BIN_DIR is set\n' >&2; exit 69; }
  for repo in sigil sigil-bitcoin; do
    [[ -d $workspace/$repo ]] || { printf 'missing sibling checkout: %s\n' "$workspace/$repo" >&2; exit 66; }
  done
  printf 'Building deploy#sigilcoin with local sibling inputs...\n'
  out=$(nix --extra-experimental-features 'nix-command flakes' build \
    "path:$root?dir=deploy#sigilcoin" \
    --override-input sigil "path:$workspace/sigil" \
    --override-input sigil-bitcoin "path:$workspace/sigil-bitcoin" \
    --no-link --print-out-paths)
  BIN_DIR=$out/bin
fi

BIN_DIR=$(cd -- "$BIN_DIR" && pwd)
coin=$BIN_DIR/sigilcoin
explorer=$BIN_DIR/sigilcoin-explorer
[[ -x $coin ]] || { printf 'missing executable: %s\n' "$coin" >&2; exit 66; }
[[ -x $explorer ]] || { printf 'missing executable: %s\n' "$explorer" >&2; exit 66; }
coin=$(readlink -f -- "$coin")
explorer=$(readlink -f -- "$explorer")

DATA_DIR=${DATA_DIR:-$root/deploy/state/local-$MODE}
LOG_DIR=${LOG_DIR:-$root/deploy/logs/local-$MODE}
RUN_DIR=${RUN_DIR:-$root/deploy/run/local-$MODE}
P2P_PORT=${P2P_PORT:-$default_port}
EXPLORER_PORT=${EXPLORER_PORT:-8080}
SYNC_INTERVAL=${SYNC_INTERVAL:-60}

umask 0027
install -d -m 0750 -- "$DATA_DIR"
install -d -m 0700 -- "$LOG_DIR" "$RUN_DIR"
if [[ -e $DATA_DIR/wallet ]]; then
  [[ -d $DATA_DIR/wallet && ! -L $DATA_DIR/wallet ]] || { printf 'unsafe wallet directory\n' >&2; exit 73; }
  chmod 0700 -- "$DATA_DIR/wallet"
fi
if [[ -e $DATA_DIR/wallet/wallet.key ]]; then
  [[ -f $DATA_DIR/wallet/wallet.key && ! -L $DATA_DIR/wallet/wallet.key ]] || { printf 'unsafe wallet key\n' >&2; exit 73; }
  chmod 0600 -- "$DATA_DIR/wallet/wallet.key"
fi
shopt -s nullglob
for db_file in "$DATA_DIR"/*.sqlite "$DATA_DIR"/*.sqlite-wal \
  "$DATA_DIR"/*.sqlite-shm "$DATA_DIR"/*.sqlite-journal
do
  [[ -f $db_file && ! -L $db_file ]] || { printf 'unsafe database path: %s\n' "$db_file" >&2; exit 73; }
  chmod 0640 -- "$db_file"
done
shopt -u nullglob

proc_starttime() {
  local pid=$1 stat_line rest
  local -a fields
  stat_line=$(<"/proc/$pid/stat") || return 1
  rest=${stat_line##*) }
  read -r -a fields <<< "$rest"
  ((${#fields[@]} >= 20)) || return 1
  printf '%s\n' "${fields[19]}"
}

write_pid_record() {
  local file=$1 role=$2 expected=$3 pid=$4 start exe
  start=$(proc_starttime "$pid")
  exe=$(readlink -f -- "/proc/$pid/exe")
  {
    printf '%s\n' "$pid" "$start" "$role" "$expected" "$exe"
  } > "$file.tmp"
  mv -f -- "$file.tmp" "$file"
}

for name in stack listener explorer; do
  pid_file=$RUN_DIR/$name.pid
  [[ -e $pid_file ]] || continue
  mapfile -t old_record < "$pid_file"
  if ((${#old_record[@]} < 1)) || [[ ! ${old_record[0]} =~ ^[0-9]+$ ]]; then
    printf 'refusing to replace malformed PID record: %s\n' "$pid_file" >&2
    exit 70
  fi
  if kill -0 "${old_record[0]}" 2>/dev/null; then
    printf 'refusing to start: %s PID %s is still running\n' "$name" "${old_record[0]}" >&2
    exit 70
  fi
  rm -f -- "$pid_file"
done

listener_pid=
listener_start=
explorer_pid=
explorer_start=
active_pid=
active_start=
stopping=0

same_process() {
  local pid=$1 expected_start=$2 current
  kill -0 "$pid" 2>/dev/null || return 1
  current=$(proc_starttime "$pid" 2>/dev/null) || return 1
  [[ $current == "$expected_start" ]]
}

terminate_owned() {
  local pid=$1 start=$2 count
  [[ -n $pid && -n $start ]] || return 0
  same_process "$pid" "$start" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for ((count=0; count<100; count++)); do
    same_process "$pid" "$start" || return 0
    sleep 0.05
  done
  same_process "$pid" "$start" && kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  terminate_owned "$active_pid" "$active_start"
  terminate_owned "$explorer_pid" "$explorer_start"
  terminate_owned "$listener_pid" "$listener_start"
  [[ -z $active_pid ]] || wait "$active_pid" 2>/dev/null || true
  [[ -z $explorer_pid ]] || wait "$explorer_pid" 2>/dev/null || true
  [[ -z $listener_pid ]] || wait "$listener_pid" 2>/dev/null || true
  rm -f -- "$RUN_DIR/stack.pid" "$RUN_DIR/listener.pid" "$RUN_DIR/explorer.pid"
  printf 'SigilCoin %s stack stopped. State remains at %s\n' "$MODE" "$DATA_DIR"
  exit "$rc"
}

on_signal() {
  stopping=1
  terminate_owned "$active_pid" "$active_start"
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM HUP
write_pid_record "$RUN_DIR/stack.pid" stack "$script_path" "$$"

"$coin" listen "${chain_args[@]}" --data-dir "$DATA_DIR" \
  --bind "$P2P_BIND" --port "$P2P_PORT" --backlog "${LISTEN_BACKLOG:-16}" \
  --max-connections 0 --accept-timeout "${ACCEPT_TIMEOUT_MS:-60000}" \
  --read-timeout "${READ_TIMEOUT_MS:-10000}" \
  --max-steps "${MAX_STEPS:-4096}" --max-tx "${MAX_TX:-256}" \
  > >(tee -a "$LOG_DIR/listener.log") 2>&1 &
listener_pid=$!
listener_start=$(proc_starttime "$listener_pid")
write_pid_record "$RUN_DIR/listener.pid" listener "$coin" "$listener_pid"

"$explorer" "${chain_args[@]}" --data-dir "$DATA_DIR" \
  --host 127.0.0.1 --port "$EXPLORER_PORT" \
  > >(tee -a "$LOG_DIR/explorer.log") 2>&1 &
explorer_pid=$!
explorer_start=$(proc_starttime "$explorer_pid")
write_pid_record "$RUN_DIR/explorer.pid" explorer "$explorer" "$explorer_pid"

sleep 2
same_process "$listener_pid" "$listener_start" || { printf 'listener exited during startup; see %s/listener.log\n' "$LOG_DIR" >&2; exit 1; }
same_process "$explorer_pid" "$explorer_start" || { printf 'explorer exited during startup; see %s/explorer.log\n' "$LOG_DIR" >&2; exit 1; }

printf 'SigilCoin %s running in foreground\n' "$MODE"
printf '  P2P:      %s:%s\n' "$P2P_BIND" "$P2P_PORT"
printf '  Explorer: http://127.0.0.1:%s/\n' "$EXPLORER_PORT"
printf '  State:    %s\n  Logs:     %s\n' "$DATA_DIR" "$LOG_DIR"
printf 'Press Ctrl-C to stop.\n'

while ((stopping == 0)); do
  same_process "$listener_pid" "$listener_start" || { printf 'listener stopped unexpectedly\n' >&2; exit 1; }
  same_process "$explorer_pid" "$explorer_start" || { printf 'explorer stopped unexpectedly\n' >&2; exit 1; }

  sync_args=(
    sync "${chain_args[@]}" --data-dir "$DATA_DIR"
    --iterations 1 --max-steps "${MAX_STEPS:-4096}"
    --max-blocks "${MAX_BLOCKS:-256}"
    --resolve-timeout "${RESOLVE_TIMEOUT_MS:-1000}"
    --connect-timeout "${CONNECT_TIMEOUT_MS:-3000}"
    --read-timeout "${READ_TIMEOUT_MS:-10000}"
  )
  if [[ -n ${PEER:-} ]]; then sync_args+=(--peer "$PEER"); fi

  "$coin" "${sync_args[@]}" > >(tee -a "$LOG_DIR/sync.log") 2>&1 &
  active_pid=$!
  active_start=$(proc_starttime "$active_pid")
  set +e
  wait "$active_pid"
  sync_rc=$?
  set -e
  active_pid=
  active_start=
  ((stopping == 0)) || break
  if ((sync_rc != 0)); then
    printf 'sync pass failed (exit %s); retrying in %ss\n' "$sync_rc" "$SYNC_INTERVAL" >&2
  fi

  sleep "$SYNC_INTERVAL" &
  active_pid=$!
  active_start=$(proc_starttime "$active_pid")
  set +e
  wait "$active_pid"
  sleep_rc=$?
  set -e
  active_pid=
  active_start=
  ((stopping == 0)) || break
  ((sleep_rc == 0)) || exit "$sleep_rc"
done
