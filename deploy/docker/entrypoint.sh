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

check_mainnet_exposure() {
  [ "$chain" = mainnet ] || return 0
  host_bind=${HOST_P2P_BIND:-127.0.0.1}
  exposure_ack=${MAINNET_EXPOSURE_ACK:-}
  case "$host_bind" in
    127.*)
      is_ipv4 "$host_bind" || { echo "invalid loopback mainnet P2P bind" >&2; exit 64; }
      [ -z "$exposure_ack" ] || {
        echo "refusing loopback mainnet P2P bind: MAINNET_EXPOSURE_ACK must be empty" >&2
        exit 64
      }
      ;;
    ::1)
      [ -z "$exposure_ack" ] || {
        echo "refusing loopback mainnet P2P bind: MAINNET_EXPOSURE_ACK must be empty" >&2
        exit 64
      }
      ;;
    *)
      is_ipv4 "$host_bind" || {
        echo "non-loopback mainnet P2P bind must be an IPv4 literal" >&2
        exit 64
      }
      [ "$exposure_ack" = public-mainnet-approved ] || {
        echo "refusing non-loopback mainnet P2P bind: set MAINNET_EXPOSURE_ACK=public-mainnet-approved exactly" >&2
        exit 64
      }
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
    check_mainnet_exposure
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

  producer-loop)
    required_address=sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud
    launch_time=1789228800
    [ "$chain" = mainnet ] || {
      echo "producer-loop is mainnet-only" >&2
      exit 64
    }
    [ "${MINER_ADDRESS:-}" = "$required_address" ] || {
      echo "producer-loop requires the configured mainnet payout address" >&2
      exit 64
    }
    interval=${MINE_INTERVAL:-60}
    case "$interval" in
      ''|*[!0-9]*)
        echo "MINE_INTERVAL must be a positive integer" >&2
        exit 64
        ;;
    esac
    [ "$interval" -gt 0 ] 2>/dev/null || {
      echo "MINE_INTERVAL must be a positive integer" >&2
      exit 64
    }
    now=$(/usr/local/bin/date -u +%s) || {
      echo "producer-loop could not read the UTC clock" >&2
      exit 64
    }
    case "$now" in
      ''|*[!0-9]*)
        echo "producer-loop received an invalid UTC clock" >&2
        exit 64
        ;;
    esac
    [ "$now" -ge "$launch_time" ] 2>/dev/null || {
      echo "refusing producer before 2026-09-12T16:00:00Z" >&2
      exit 64
    }
    secure_node_state

    producer_status() {
      status=$("$coin" status --data-dir "$data_dir") || return 1
      current_tip=
      next_slot=
      while IFS= read -r line; do
        case "$line" in
          "best-block-hash: "*) current_tip=${line#best-block-hash: } ;;
          "next-slot-time: "*) next_slot=${line#next-slot-time: } ;;
        esac
      done <<EOF
$status
EOF
      case "$next_slot" in
        ''|*[!0-9]*) return 1 ;;
      esac
      [ -n "$current_tip" ]
    }

    stop=0
    producer_child=
    sleep_child=
    submitted_tip=
    on_signal() {
      stop=1
      if [ -n "$producer_child" ]; then
        kill -TERM "$producer_child" 2>/dev/null || true
      fi
      if [ -n "$sleep_child" ]; then
        kill -TERM "$sleep_child" 2>/dev/null || true
      fi
    }
    trap on_signal INT TERM HUP

    while [ "$stop" -eq 0 ]; do
      if ! producer_status; then
        echo "production skipped: could not read the validated tip and next slot" >&2
      elif [ "$current_tip" != "$submitted_tip" ] &&
           now=$(/usr/local/bin/date -u +%s) &&
           [ "$now" -ge "$next_slot" ] 2>/dev/null; then
        start_tip=$current_tip
        "$coin" mine \
          --address "$required_address" \
          --data-dir "$data_dir" &
        producer_child=$!
        if [ "$stop" -ne 0 ]; then
          kill -TERM "$producer_child" 2>/dev/null || true
        fi
        stale=0
        while kill -0 "$producer_child" 2>/dev/null; do
          sleep 10 &
          sleep_child=$!
          if [ "$stop" -ne 0 ]; then
            kill -TERM "$sleep_child" 2>/dev/null || true
          fi
          wait "$sleep_child" 2>/dev/null || true
          sleep_child=
          [ "$stop" -eq 0 ] || break
          kill -0 "$producer_child" 2>/dev/null || break
          if producer_status && [ "$current_tip" != "$start_tip" ]; then
            stale=1
            kill -TERM "$producer_child" 2>/dev/null || true
            break
          fi
        done
        if wait "$producer_child"; then rc=0; else rc=$?; fi
        producer_child=
        [ "$stop" -eq 0 ] || break
        if [ "$stale" -eq 1 ]; then
          echo "production canceled: validated tip changed; rebuilding in ${interval}s" >&2
        elif [ "$rc" -ne 0 ]; then
          echo "production failed (exit $rc); retrying in ${interval}s" >&2
        else
          submitted_tip=$start_tip
        fi
      fi
      # Idle slots and retained candidates only require a sleeping tip watch.
      sleep "$interval" &
      sleep_child=$!
      if [ "$stop" -ne 0 ]; then
        kill -TERM "$sleep_child" 2>/dev/null || true
      fi
      wait "$sleep_child" 2>/dev/null || true
      sleep_child=
    done
    ;;

  explorer)
    set -- "$explorer" \
      --host "${EXPLORER_HOST:-0.0.0.0}" \
      --port "${EXPLORER_PORT:-8080}"
    if [ -n "$chain_flag" ]; then set -- "$@" "$chain_flag"; fi
    exec "$@" --data-dir "$data_dir"
    ;;

  relay)
    [ "$chain" = testnet ] || {
      echo "relay is testnet-only" >&2
      exit 64
    }
    umask 0027
    exec "$coin" relay serve \
      --testnet \
      --data-dir /var/lib/sigilcoin \
      --state-dir /var/lib/sigilcoin-pool \
      --host 0.0.0.0 \
      --port 8082
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

  health-relay)
    [ "$chain" = testnet ] || exit 64
    exec "$coin" relay health \
      --relay http://127.0.0.1:8082 \
      --testnet
    ;;

  cli)
    case "${1:-}" in
      listen|relay)
        echo "refusing server command through cli mode; use its guarded service mode" >&2
        exit 64
        ;;
    esac
    for argument do
      case "$argument" in
        --|--chain|--chain=*|--testnet|--regtest)
          echo "refusing chain override through cli mode; set CHAIN on the container" >&2
          exit 64
          ;;
      esac
    done
    secure_node_state
    set -- "$coin" "$@"
    if [ -n "$chain_flag" ]; then set -- "$@" "$chain_flag"; fi
    exec "$@" --data-dir "$data_dir"
    ;;

  site-path)
    printf '%s\n' /opt/sigilcoin/share/sigilcoin-site
    ;;

  *)
    echo "unknown mode '$service_mode' (listener, sync-loop, producer-loop, explorer, relay, health-node, health-explorer, health-relay, cli, site-path)" >&2
    exit 64
    ;;
esac
