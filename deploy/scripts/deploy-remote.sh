#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-remote.sh [options]

Synchronize the sigil, sigil-bitcoin, and sigil-coin sibling checkouts over
rsync/SSH, then build and start the selected Docker Compose stack remotely.
This never commits or pushes Git repositories.

Options:
  --host HOST       SSH host or alias (env: REMOTE_HOST; required)
  --remote-dir DIR  Remote workspace directory (env: REMOTE_DIR; default: /srv/sigilcoin)
  --mode MODE       testnet or mainnet (env: MODE; default: testnet)
  --env-file FILE   Upload FILE as sigil-coin/deploy/docker/.env (env: ENV_FILE)
  -h, --help        Show this help

Environment:
  SSH_IDENTITIES_ONLY=yes|no  Override OpenSSH identity selection. Unset keeps
                              the caller's SSH configuration unchanged.

Mainnet additionally requires ALLOW_MAINNET=yes. Its P2P listener stays
loopback-only unless MAINNET_EXPOSURE_ACK is exactly public-mainnet-approved.
Before the mainnet explorer starts, the repository Caddyfile must be installed
at /etc/caddy/Caddyfile; deployment validates and reloads it fail-closed.
Non-loopback testnet P2P requires either peer-ip-allowlisted with
REMOTE_PEER_IP, or the exact public-testnet-approved acknowledgement.
EOF
}

REMOTE_HOST=${REMOTE_HOST:-}
REMOTE_DIR=${REMOTE_DIR:-/srv/sigilcoin}
MODE=${MODE:-testnet}
ENV_FILE=${ENV_FILE:-}
ssh_identities_only=${SSH_IDENTITIES_ONLY-}

require_option_value() {
  if (($# < 2)); then
    printf 'missing value for %s\n' "$1" >&2
    exit 64
  fi
}

while (($#)); do
  case $1 in
    --host) require_option_value "$@"; REMOTE_HOST=$2; shift 2 ;;
    --remote-dir) require_option_value "$@"; REMOTE_DIR=$2; shift 2 ;;
    --mode) require_option_value "$@"; MODE=$2; shift 2 ;;
    --env-file) require_option_value "$@"; ENV_FILE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

allow_mainnet=${ALLOW_MAINNET:-no}
[[ $allow_mainnet == yes || $allow_mainnet == no ]] || {
  printf 'ALLOW_MAINNET must be exactly yes or no\n' >&2
  exit 64
}
if [[ -v SSH_IDENTITIES_ONLY ]]; then
  case $ssh_identities_only in
    yes|no) ;;
    *) printf 'SSH_IDENTITIES_ONLY must be exactly yes or no\n' >&2; exit 64 ;;
  esac
fi

case $MODE in
  testnet) ;;
  mainnet)
    if [[ $allow_mainnet != yes ]]; then
      printf 'refusing mainnet: set ALLOW_MAINNET=yes only after final genesis approval\n' >&2
      exit 64
    fi
    ;;
  *) printf 'MODE must be testnet or mainnet\n' >&2; exit 64 ;;
esac

[[ -n $REMOTE_HOST ]] || { printf 'REMOTE_HOST is required\n' >&2; exit 64; }
[[ $REMOTE_HOST != -* ]] || { printf 'REMOTE_HOST must not begin with -\n' >&2; exit 64; }
[[ $REMOTE_HOST =~ ^([A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || {
  printf 'REMOTE_HOST must be a safe SSH hostname or user@hostname\n' >&2
  exit 64
}

[[ $REMOTE_DIR == /* && $REMOTE_DIR =~ ^/[A-Za-z0-9_./-]+$ ]] || {
  printf 'REMOTE_DIR must be an absolute path containing only letters, digits, _, ., /, or -\n' >&2
  exit 64
}
[[ $REMOTE_DIR != / && $REMOTE_DIR != *//* ]] || {
  printf 'REMOTE_DIR must not be / or contain //\n' >&2
  exit 64
}
[[ ! $REMOTE_DIR =~ (^|/)\.\.?(/|$) ]] || {
  printf 'REMOTE_DIR must not contain . or .. path components\n' >&2
  exit 64
}
while [[ $REMOTE_DIR == */ ]]; do REMOTE_DIR=${REMOTE_DIR%/}; done
[[ $REMOTE_DIR != / ]] || { printf 'REMOTE_DIR must not resolve to /\n' >&2; exit 64; }

for variable_name in SIGIL_UID SIGIL_GID EXPLORER_UID POOL_UID; do
  variable_value=${!variable_name:-}
  if [[ -n $variable_value && ! $variable_value =~ ^[0-9]+$ ]]; then
    printf '%s must be numeric\n' "$variable_name" >&2
    exit 64
  fi
done
if [[ -n ${SIGIL_UID:-} && -n ${EXPLORER_UID:-} && $SIGIL_UID == "$EXPLORER_UID" ]]; then
  printf 'EXPLORER_UID must differ from SIGIL_UID\n' >&2
  exit 64
fi
if [[ -n ${POOL_UID:-} && -n ${SIGIL_UID:-} && $POOL_UID == "$SIGIL_UID" ]]; then
  printf 'POOL_UID must differ from SIGIL_UID\n' >&2
  exit 64
fi
if [[ -n ${POOL_UID:-} && -n ${EXPLORER_UID:-} && $POOL_UID == "$EXPLORER_UID" ]]; then
  printf 'POOL_UID must differ from EXPLORER_UID\n' >&2
  exit 64
fi
if [[ -n $ENV_FILE && ! -f $ENV_FILE ]]; then
  printf 'ENV_FILE does not exist: %s\n' "$ENV_FILE" >&2
  exit 66
fi

for command_name in rsync ssh; do
  command -v "$command_name" >/dev/null || {
    printf 'required command not found: %s\n' "$command_name" >&2
    exit 69
  }
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
coin_root=$(cd -- "$script_dir/../.." && pwd)
workspace=$(cd -- "$coin_root/.." && pwd)
for repo in sigil sigil-bitcoin sigil-coin; do
  [[ -d $workspace/$repo ]] || { printf 'missing sibling checkout: %s\n' "$workspace/$repo" >&2; exit 66; }
done

ssh_options=()
rsync_transport=()
if [[ -n $ssh_identities_only ]]; then
  ssh_options=(-o "IdentitiesOnly=$ssh_identities_only")
  rsync_transport=(-e "ssh -o IdentitiesOnly=$ssh_identities_only")
fi

# REMOTE_HOST and REMOTE_DIR are restricted above, so neither can become an
# SSH option or remote-shell expression on clients without `ssh --` support.
printf 'Preparing remote workspace %s:%s\n' "$REMOTE_HOST" "$REMOTE_DIR"
ssh "${ssh_options[@]}" "$REMOTE_HOST" bash -s -- "$REMOTE_DIR" <<'PREPARE_REMOTE'
set -euo pipefail
remote_dir=$1
mkdir -p -- "$remote_dir/sigil" "$remote_dir/sigil-bitcoin" "$remote_dir/sigil-coin"
PREPARE_REMOTE

rsync_args=(
  --archive --compress --delete --protect-args
  --exclude=.git/
  --exclude=/build/
  --exclude='/packages/*/build/'
  --exclude='/tools/*/build/'
  --exclude=/examples/build/
  --exclude=/test/build/
  --exclude=.sigil/
  --exclude='**/.sigil/'
  --exclude=.sigilcoin/
  --exclude='**/.sigilcoin/'
  --exclude=.sigilcoin-testnet/
  --exclude='**/.sigilcoin-testnet/'
  --exclude=result
  --exclude='result-*'
  --exclude=.env
  --exclude=deploy/docker/state/
  --exclude=deploy/state/
  --exclude=deploy/logs/
  --exclude=deploy/run/
)

for repo in sigil sigil-bitcoin sigil-coin; do
  printf 'Synchronizing %s\n' "$repo"
  rsync "${rsync_transport[@]}" "${rsync_args[@]}" -- "$workspace/$repo/" "$REMOTE_HOST:$REMOTE_DIR/$repo/"
done

has_env=no
if [[ -n $ENV_FILE ]]; then
  printf 'Uploading Compose environment file\n'
  rsync "${rsync_transport[@]}" --archive --protect-args --chmod=F600 -- \
    "$ENV_FILE" "$REMOTE_HOST:$REMOTE_DIR/sigil-coin/deploy/docker/.env"
  has_env=yes
fi

ssh "${ssh_options[@]}" "$REMOTE_HOST" bash -s -- \
  "$REMOTE_DIR" "$MODE" "${SIGIL_UID:--}" "${SIGIL_GID:--}" \
  "${EXPLORER_UID:--}" "${POOL_UID:--}" "$allow_mainnet" "$has_env" <<'REMOTE_SCRIPT'
set -euo pipefail
remote_dir=$1
mode=$2
sigil_uid=$3
sigil_gid=$4
explorer_uid=$5
pool_uid=$6
allow_mainnet=$7
has_env=$8

[[ $allow_mainnet == yes || $allow_mainnet == no ]] || { echo 'invalid ALLOW_MAINNET' >&2; exit 64; }
[[ $mode == testnet || $mode == mainnet ]] || { echo 'invalid mode' >&2; exit 64; }
[[ $mode != mainnet || $allow_mainnet == yes ]] || { echo 'mainnet is not acknowledged' >&2; exit 64; }

cd "$remote_dir/sigil-coin/deploy/docker"

read_env_value() {
  local wanted=$1 line value=
  [[ $has_env == yes && -f .env ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line == "$wanted="* ]] || continue
    value=${line#*=}
  done < .env
  if [[ $value == \"*\" && $value == *\" ]]; then value=${value:1:${#value}-2}; fi
  if [[ $value == \'*\' && $value == *\' ]]; then value=${value:1:${#value}-2}; fi
  printf '%s' "$value"
}

env_or_file() {
  local name=$1 current=${!1:-}
  if [[ -n $current ]]; then printf '%s' "$current"; else read_env_value "$name"; fi
}

if [[ $sigil_uid == - ]]; then sigil_uid=$(read_env_value SIGIL_UID); fi
if [[ $sigil_gid == - ]]; then sigil_gid=$(read_env_value SIGIL_GID); fi
if [[ $explorer_uid == - ]]; then explorer_uid=$(read_env_value EXPLORER_UID); fi
if [[ $pool_uid == - ]]; then pool_uid=$(read_env_value POOL_UID); fi
[[ -z $sigil_uid || $sigil_uid =~ ^[0-9]+$ ]] || {
  echo 'SIGIL_UID from environment file must be numeric' >&2
  exit 64
}
[[ -z $sigil_gid || $sigil_gid =~ ^[0-9]+$ ]] || {
  echo 'SIGIL_GID from environment file must be numeric' >&2
  exit 64
}
sigil_uid=${sigil_uid:-$(id -u)}
sigil_gid=${sigil_gid:-$(id -g)}
explorer_uid=${explorer_uid:-$((sigil_uid + 1))}
pool_uid=${pool_uid:-$((sigil_uid + 2))}
for identity in "$sigil_uid" "$sigil_gid" "$explorer_uid" "$pool_uid"; do
  [[ $identity =~ ^[0-9]+$ ]] || { echo 'container UID/GID values must be numeric' >&2; exit 64; }
done
[[ $sigil_uid != "$explorer_uid" ]] || { echo 'EXPLORER_UID must differ from SIGIL_UID' >&2; exit 64; }
[[ $pool_uid != "$sigil_uid" ]] || { echo 'POOL_UID must differ from SIGIL_UID' >&2; exit 64; }
[[ $pool_uid != "$explorer_uid" ]] || { echo 'POOL_UID must differ from EXPLORER_UID' >&2; exit 64; }
operator_uid=$(id -u)

is_ipv4() {
  local address=$1 octet
  [[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    ((${#octet} <= 3 && 10#$octet <= 255)) || return 1
  done
}

is_remote_ipv4() {
  local address=$1 first_octet
  is_ipv4 "$address" || return 1
  first_octet=${address%%.*}
  ((10#$first_octet > 0 && 10#$first_octet != 127 && 10#$first_octet < 224))
}

validate_state_spec() {
  local value=$1
  [[ -n $value && $value != / && $value != *//* ]] || return 1
  [[ $value =~ ^/?[A-Za-z0-9_./-]+$ ]] || return 1
  value=${value#./}
  [[ -n $value && ! $value =~ (^|/)\.\.?(/|$) ]]
}

canonical_state_path() {
  local spec=$1 path
  while [[ $spec == */ ]]; do spec=${spec%/}; done
  spec=${spec#./}
  if [[ $spec == /* ]]; then path=$spec; else path=$(pwd -P)/$spec; fi
  [[ $(realpath -m -- "$path") == "$path" ]] || return 1
  printf '%s' "$path"
}

paths_overlap() {
  [[ $1 == "$2" || $1 == "$2/"* || $2 == "$1/"* ]]
}

if [[ $mode == testnet ]]; then
  state_spec=$(env_or_file SIGIL_TESTNET_STATE_DIR)
  state_spec=${state_spec:-./state/testnet}
  pool_state_spec=$(env_or_file SIGIL_TESTNET_POOL_STATE_DIR)
  pool_state_spec=${pool_state_spec:-./state/testnet-pool}
  p2p_bind=$(env_or_file P2P_BIND)
  p2p_bind=${p2p_bind:-127.0.0.1}
  exposure_ack=$(env_or_file TESTNET_EXPOSURE_ACK)
  remote_peer_ip=$(env_or_file REMOTE_PEER_IP)
  peer=$(env_or_file PEER)
  case $exposure_ack in
    ''|peer-ip-allowlisted|public-testnet-approved) ;;
    *)
      echo 'invalid TESTNET_EXPOSURE_ACK (expected empty, peer-ip-allowlisted, or public-testnet-approved)' >&2
      exit 64
      ;;
  esac
  case $p2p_bind in
    127.*) is_ipv4 "$p2p_bind" || { echo 'invalid loopback P2P bind' >&2; exit 64; } ;;
    ::1) ;;
    *)
      is_ipv4 "$p2p_bind" || { echo 'non-loopback P2P bind must be an IPv4 literal' >&2; exit 64; }
      case $exposure_ack in
        peer-ip-allowlisted)
          is_remote_ipv4 "$remote_peer_ip" || { echo 'REMOTE_PEER_IP must be a unicast IPv4 literal' >&2; exit 64; }
          if [[ -n $peer && ${peer%%:*} != "$remote_peer_ip" ]]; then
            echo 'PEER host must match REMOTE_PEER_IP for allowlisted testnet exposure' >&2
            exit 64
          fi
          ;;
        public-testnet-approved) ;;
        *)
          echo 'non-loopback testnet P2P requires an explicit TESTNET_EXPOSURE_ACK mode' >&2
          exit 64
          ;;
      esac
      ;;
  esac
else
  state_spec=$(env_or_file SIGIL_MAINNET_STATE_DIR)
  state_spec=${state_spec:-./state/mainnet}
  p2p_bind=$(env_or_file MAINNET_P2P_BIND)
  p2p_bind=${p2p_bind:-127.0.0.1}
  exposure_ack=$(env_or_file MAINNET_EXPOSURE_ACK)
  case $p2p_bind in
    127.*)
      is_ipv4 "$p2p_bind" || { echo 'invalid loopback mainnet P2P bind' >&2; exit 64; }
      [[ -z $exposure_ack ]] || {
        echo 'MAINNET_EXPOSURE_ACK must be empty for a loopback mainnet P2P bind' >&2
        exit 64
      }
      ;;
    ::1)
      [[ -z $exposure_ack ]] || {
        echo 'MAINNET_EXPOSURE_ACK must be empty for a loopback mainnet P2P bind' >&2
        exit 64
      }
      ;;
    *)
      is_ipv4 "$p2p_bind" || { echo 'non-loopback mainnet P2P bind must be an IPv4 literal' >&2; exit 64; }
      [[ $exposure_ack == public-mainnet-approved ]] || {
        echo 'non-loopback mainnet P2P requires MAINNET_EXPOSURE_ACK=public-mainnet-approved exactly' >&2
        exit 64
      }
      ;;
  esac
fi
validate_state_spec "$state_spec" || { echo 'unsafe chain state directory path' >&2; exit 64; }
state_dir=$(canonical_state_path "$state_spec") || {
  echo 'refusing chain state directory with a symlink component' >&2
  exit 73
}
if [[ $mode == testnet ]]; then
  validate_state_spec "$pool_state_spec" || { echo 'unsafe pool state directory path' >&2; exit 64; }
  pool_state_dir=$(canonical_state_path "$pool_state_spec") || {
    echo 'refusing pool state directory with a symlink component' >&2
    exit 73
  }
  ! paths_overlap "$state_dir" "$pool_state_dir" || {
    echo 'chain and pool state directories must be distinct and non-nested' >&2
    exit 64
  }
fi
[[ $state_dir != / && ! -L $state_dir ]] || { echo 'refusing unsafe chain state directory' >&2; exit 73; }

install -d -m 0750 -- "$state_dir"
chmod 0750 -- "$state_dir"
chgrp "$sigil_gid" -- "$state_dir" || {
  echo "cannot set state group to SIGIL_GID=$sigil_gid; create/chgrp it as an administrator" >&2
  exit 73
}
[[ $(stat -c %u -- "$state_dir") == "$sigil_uid" && $(stat -c %g -- "$state_dir") == "$sigil_gid" ]] || {
  echo "state directory must be owned by $sigil_uid:$sigil_gid" >&2
  exit 73
}

if [[ -e $state_dir/wallet ]]; then
  [[ -d $state_dir/wallet && ! -L $state_dir/wallet ]] || { echo 'unsafe wallet directory' >&2; exit 73; }
  chmod 0700 -- "$state_dir/wallet"
  [[ $(stat -c %u -- "$state_dir/wallet") == "$sigil_uid" ]] || { echo 'wallet directory has wrong owner' >&2; exit 73; }
fi
if [[ -e $state_dir/wallet/wallet.key ]]; then
  [[ -f $state_dir/wallet/wallet.key && ! -L $state_dir/wallet/wallet.key ]] || { echo 'unsafe wallet key' >&2; exit 73; }
  chmod 0600 -- "$state_dir/wallet/wallet.key"
  [[ $(stat -c %u -- "$state_dir/wallet/wallet.key") == "$sigil_uid" ]] || { echo 'wallet key has wrong owner' >&2; exit 73; }
fi

shopt -s nullglob
for db_file in "$state_dir"/*.sqlite "$state_dir"/*.sqlite-wal \
  "$state_dir"/*.sqlite-shm "$state_dir"/*.sqlite-journal
do
  [[ -f $db_file && ! -L $db_file ]] || { echo "unsafe database path: $db_file" >&2; exit 73; }
  chmod 0640 -- "$db_file"
  chgrp "$sigil_gid" -- "$db_file"
  [[ $(stat -c %u -- "$db_file") == "$sigil_uid" ]] || { echo "database has wrong owner: $db_file" >&2; exit 73; }
done
shopt -u nullglob

if [[ $mode == testnet ]]; then
  [[ $pool_state_dir != / && ! -L $pool_state_dir ]] || { echo 'refusing unsafe pool state directory' >&2; exit 73; }
  install -d -m 0770 -- "$pool_state_dir"
  chmod 0770 -- "$pool_state_dir"
  chgrp "$sigil_gid" -- "$pool_state_dir" || {
    echo "cannot set pool state group to SIGIL_GID=$sigil_gid" >&2
    exit 73
  }
  [[ $(stat -c %u -- "$pool_state_dir") == "$operator_uid" &&
     $(stat -c %g -- "$pool_state_dir") == "$sigil_gid" ]] || {
    echo "pool state directory must be owned by remote operator $operator_uid:$sigil_gid" >&2
    exit 73
  }
fi


compose_args=(-p "sigilcoin-$mode" -f "compose.$mode.yml")
if [[ $mode == mainnet ]]; then
  compose_args=(--profile mainnet-explorer "${compose_args[@]}")
fi
if [[ $has_env == yes ]]; then compose_args=(--env-file .env "${compose_args[@]}"); fi

export SIGIL_UID="$sigil_uid" SIGIL_GID="$sigil_gid" EXPLORER_UID="$explorer_uid"
export ALLOW_MAINNET="$allow_mainnet" DOCKER_BUILDKIT=1
if [[ $mode == testnet ]]; then
  export POOL_UID="$pool_uid"
  export P2P_BIND="$p2p_bind" TESTNET_EXPOSURE_ACK="$exposure_ack" REMOTE_PEER_IP="$remote_peer_ip"
  export SIGIL_TESTNET_STATE_DIR="$state_dir" SIGIL_TESTNET_POOL_STATE_DIR="$pool_state_dir"
else
  export MAINNET_P2P_BIND="$p2p_bind" MAINNET_EXPOSURE_ACK="$exposure_ack"
  export SIGIL_MAINNET_STATE_DIR="$state_dir"
fi

docker compose "${compose_args[@]}" config --quiet
if [[ $mode == mainnet ]]; then
  docker compose "${compose_args[@]}" --profile mainnet-miner rm -sf miner
fi
docker compose "${compose_args[@]}" build
if [[ $mode == mainnet ]]; then
  caddy_source=$remote_dir/sigil-coin/deploy/Caddyfile
  if ! cmp -s "$caddy_source" /etc/caddy/Caddyfile; then
    echo 'refusing mainnet explorer start: install the staged Caddy configuration first' >&2
    exit 73
  fi
  caddy validate --config "$caddy_source"
  caddy reload --config "$caddy_source"
fi
docker compose "${compose_args[@]}" up -d --remove-orphans --wait --wait-timeout 180
docker compose "${compose_args[@]}" ps
REMOTE_SCRIPT
