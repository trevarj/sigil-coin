#!/bin/sh
set -eu

service_mode=${1:-cli}
if [ "$#" -gt 0 ]; then
  shift
fi

chain=${CHAIN:-testnet}
data_dir=${DATA_DIR:-/var/lib/sigilcoin}

case "$chain" in
  testnet)
    chain_flag=--testnet
    default_port=19446
    db_name=sigilcoin-testnet.sqlite
    ;;
  mainnet)
    if [ "${ALLOW_MAINNET:-no}" != yes ]; then
      echo "refusing mainnet: set ALLOW_MAINNET=yes only after final genesis approval" >&2
      exit 64
    fi
    chain_flag=
    default_port=19444
    db_name=sigilcoin-main.sqlite
    ;;
  *)
    echo "unsupported CHAIN '$chain' (expected testnet or mainnet)" >&2
    exit 64
    ;;
esac

coin=/opt/sigilcoin/bin/sigilcoin
explorer=/opt/sigilcoin/bin/sigilcoin-explorer
p2p_port=${P2P_PORT:-$default_port}

is_ipv4() {
  candidate=$1
  case "$candidate" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  old_ifs=$IFS
  IFS=.
  set -f
  # Deliberate dot-field splitting after the character allowlist above.
  # shellcheck disable=SC2086
  set -- $candidate
  set +f
  IFS=$old_ifs
  [ "$#" -eq 4 ] || return 1
  for octet do
    case "$octet" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#octet}" -le 3 ] && [ "$octet" -le 255 ] 2>/dev/null || return 1
  done
}

is_remote_ipv4() {
  is_ipv4 "$1" || return 1
  first_octet=${1%%.*}
  [ "$first_octet" -gt 0 ] && [ "$first_octet" -ne 127 ] && [ "$first_octet" -lt 224 ]
}

check_testnet_exposure() {
  [ "$chain" = testnet ] || return 0
  host_bind=${HOST_P2P_BIND:-127.0.0.1}
  exposure_ack=${TESTNET_EXPOSURE_ACK:-}
  case "$exposure_ack" in
    ''|peer-ip-allowlisted|public-testnet-approved) ;;
    *)
      echo "invalid TESTNET_EXPOSURE_ACK (expected empty, peer-ip-allowlisted, or public-testnet-approved)" >&2
      exit 64
      ;;
  esac
  case "$host_bind" in
    127.*) is_ipv4 "$host_bind" || { echo "invalid loopback P2P bind" >&2; exit 64; }; return 0 ;;
    ::1) return 0 ;;
  esac
  is_ipv4 "$host_bind" || { echo "non-loopback P2P bind must be an IPv4 literal" >&2; exit 64; }
  case "$exposure_ack" in
    peer-ip-allowlisted)
      if ! is_remote_ipv4 "${REMOTE_PEER_IP:-}"; then
        echo "refusing allowlisted testnet P2P bind: REMOTE_PEER_IP must be a unicast IPv4 literal" >&2
        exit 64
      fi
      if [ -n "${PEER:-}" ] && [ "${PEER%%:*}" != "$REMOTE_PEER_IP" ]; then
        echo "refusing allowlisted testnet exposure: PEER host must match REMOTE_PEER_IP" >&2
        exit 64
      fi
      ;;
    public-testnet-approved) ;;
    *)
      echo "refusing non-loopback testnet P2P bind: select an explicit TESTNET_EXPOSURE_ACK mode" >&2
      exit 64
      ;;
  esac
}

secure_node_state() {
  umask 0027
  if [ -h "$data_dir" ]; then
    echo "refusing symlink DATA_DIR: $data_dir" >&2
    exit 73
  fi
  mkdir -p -- "$data_dir"
  chmod 0750 -- "$data_dir"

  if [ -e "$data_dir/wallet" ]; then
    if [ -h "$data_dir/wallet" ] || [ ! -d "$data_dir/wallet" ]; then
      echo "refusing unsafe wallet path: $data_dir/wallet" >&2
      exit 73
    fi
    chmod 0700 -- "$data_dir/wallet"
  fi
  if [ -e "$data_dir/wallet/wallet.key" ]; then
    if [ -h "$data_dir/wallet/wallet.key" ] || [ ! -f "$data_dir/wallet/wallet.key" ]; then
      echo "refusing unsafe wallet key path" >&2
      exit 73
    fi
    chmod 0600 -- "$data_dir/wallet/wallet.key"
  fi

  for db_file in \
    "$data_dir"/*.sqlite "$data_dir"/*.sqlite-wal \
    "$data_dir"/*.sqlite-shm "$data_dir"/*.sqlite-journal
  do
    [ -e "$db_file" ] || continue
    if [ -h "$db_file" ] || [ ! -f "$db_file" ]; then
      echo "refusing unsafe database path: $db_file" >&2
      exit 73
    fi
    chmod 0640 -- "$db_file"
  done
}

case "$service_mode" in
  listener)
    check_testnet_exposure
    secure_node_state
    set -- "$coin" listen \
      --bind "${LISTEN_BIND:-0.0.0.0}" \
      --port "$p2p_port" \
      --backlog "${LISTEN_BACKLOG:-16}" \
      --max-connections 0 \
      --accept-timeout "${ACCEPT_TIMEOUT_MS:-60000}" \
      --read-timeout "${READ_TIMEOUT_MS:-10000}" \
      --max-steps "${MAX_STEPS:-4096}" \
      --max-tx "${MAX_TX:-256}"
    if [ -n "$chain_flag" ]; then set -- "$@" "$chain_flag"; fi
    exec "$@" --data-dir "$data_dir"
    ;;

  sync-loop)
    secure_node_state
    stop=0
    child=
    on_signal() {
      stop=1
      if [ -n "$child" ]; then
        kill -TERM "$child" 2>/dev/null || true
      fi
    }
    trap on_signal INT TERM HUP

    interval=${SYNC_INTERVAL:-60}
    while [ "$stop" -eq 0 ]; do
      set -- "$coin" sync \
        --iterations 1 \
        --max-steps "${MAX_STEPS:-4096}" \
        --max-blocks "${MAX_BLOCKS:-256}" \
        --resolve-timeout "${RESOLVE_TIMEOUT_MS:-1000}" \
        --connect-timeout "${CONNECT_TIMEOUT_MS:-3000}" \
        --read-timeout "${READ_TIMEOUT_MS:-10000}"
      if [ -n "${PEER:-}" ]; then set -- "$@" --peer "$PEER"; fi
      if [ -n "$chain_flag" ]; then set -- "$@" "$chain_flag"; fi
      set -- "$@" --data-dir "$data_dir"

      "$@" &
      child=$!
      if wait "$child"; then rc=0; else rc=$?; fi
      child=
      [ "$stop" -eq 0 ] || break
      if [ "$rc" -ne 0 ]; then
        echo "sync pass failed (exit $rc); retrying in ${interval}s" >&2
      fi
      sleep "$interval" &
      child=$!
      wait "$child" 2>/dev/null || true
      child=
    done
    ;;

  explorer)
    set -- "$explorer" \
      --host "${EXPLORER_HOST:-0.0.0.0}" \
      --port "${EXPLORER_PORT:-8080}"
    if [ -n "$chain_flag" ]; then set -- "$@" "$chain_flag"; fi
    exec "$@" --data-dir "$data_dir"
    ;;

  health-node)
    secure_node_state
    set -- "$coin" status
    if [ -n "$chain_flag" ]; then set -- "$@" "$chain_flag"; fi
    exec "$@" --data-dir "$data_dir" >/dev/null
    ;;

  health-explorer)
    db_path=$data_dir/$db_name
    [ -f "$db_path" ] && [ ! -h "$db_path" ] && [ -r "$db_path" ]
    ;;

  cli)
    secure_node_state
    set -- "$coin" "$@"
    if [ -n "$chain_flag" ]; then set -- "$@" "$chain_flag"; fi
    exec "$@" --data-dir "$data_dir"
    ;;

  site-path)
    printf '%s\n' /opt/sigilcoin/share/sigilcoin-site
    ;;

  *)
    echo "unknown mode '$service_mode' (listener, sync-loop, explorer, health-node, health-explorer, cli, site-path)" >&2
    exit 64
    ;;
esac
