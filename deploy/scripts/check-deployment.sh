#!/usr/bin/env bash
# Compose interpolation strings below are intentionally literal.
# shellcheck disable=SC2016
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$script_dir/../.." && pwd)
cd "$root"

fail() { printf 'deployment check failed: %s\n' "$*" >&2; exit 1; }
assert_fixed() {
  local text=$1 file=$2
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}
expect_exit() {
  local wanted=$1
  shift
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  [[ $actual == "$wanted" ]] || fail "expected exit $wanted, got $actual: $*"
}
expect_not_exit() {
  local forbidden=$1
  shift
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  [[ $actual != "$forbidden" ]] || fail "unexpected exit $forbidden: $*"
}

bash -n deploy/scripts/deploy-remote.sh deploy/scripts/run-local.sh \
  deploy/scripts/stop-local.sh deploy/scripts/check-deployment.sh
sh -n deploy/docker/entrypoint.sh
for script in deploy/scripts/deploy-remote.sh deploy/scripts/run-local.sh deploy/scripts/stop-local.sh; do
  bash "$script" --help >/dev/null
done

for pattern in '/.sigilcoin/' '**/.sigilcoin/' '/.sigilcoin-testnet/' '**/.sigilcoin-testnet/'; do
  assert_fixed "$pattern" .gitignore
done
for pattern in '.sigilcoin' '.sigilcoin/**' '**/.sigilcoin' '**/.sigilcoin/**' \
  '.sigilcoin-testnet' '.sigilcoin-testnet/**' '**/.sigilcoin-testnet' '**/.sigilcoin-testnet/**'; do
  assert_fixed "$pattern" deploy/docker/Dockerfile.dockerignore
done
for pattern in '--exclude=.sigilcoin/' "--exclude='**/.sigilcoin/'" \
  '--exclude=.sigilcoin-testnet/' "--exclude='**/.sigilcoin-testnet/'"; do
  assert_fixed "$pattern" deploy/scripts/deploy-remote.sh
done

for compose in deploy/docker/compose.testnet.yml deploy/docker/compose.mainnet.yml; do
  assert_fixed 'user: "${SIGIL_UID:-1000}:${SIGIL_GID:-1000}"' "$compose"
  assert_fixed 'user: "${EXPLORER_UID:-1001}:${SIGIL_GID:-1000}"' "$compose"
  assert_fixed 'read_only: true' "$compose"
  assert_fixed 'pids_limit:' "$compose"
  assert_fixed 'mem_limit:' "$compose"
  assert_fixed 'cpus:' "$compose"
  assert_fixed 'driver: json-file' "$compose"
  assert_fixed 'max-size: "10m"' "$compose"
  if grep -Fq 'kill -0 1' "$compose"; then fail "$compose uses a PID1-only healthcheck"; fi
done
assert_fixed '"${P2P_BIND:-127.0.0.1}:${P2P_PORT:-19446}:19446/tcp"' deploy/docker/compose.testnet.yml
assert_fixed '"127.0.0.1:${EXPLORER_PORT:-8080}:8080/tcp"' deploy/docker/compose.testnet.yml
if grep -Fq 'EXPLORER_BIND' deploy/docker/compose.testnet.yml; then fail 'testnet explorer has a bind override'; fi
assert_fixed 'TESTNET_EXPOSURE_ACK' deploy/docker/entrypoint.sh
assert_fixed 'peer-ip-allowlisted|public-testnet-approved' deploy/docker/entrypoint.sh
assert_fixed 'peer-ip-allowlisted|public-testnet-approved' deploy/scripts/run-local.sh
assert_fixed 'peer-ip-allowlisted|public-testnet-approved' deploy/scripts/deploy-remote.sh
assert_fixed 'umask 0027' deploy/docker/entrypoint.sh
assert_fixed 'chmod 0640' deploy/docker/entrypoint.sh
assert_fixed 'chmod 0700' deploy/docker/entrypoint.sh
assert_fixed 'chmod 0600' deploy/docker/entrypoint.sh

expect_exit 64 env REMOTE_HOST=-host bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host REMOTE_DIR=/ bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host REMOTE_DIR='/srv/sigil coin' bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host REMOTE_DIR=/srv//sigilcoin bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host REMOTE_DIR=/srv/./sigilcoin bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host REMOTE_DIR=/srv/../sigilcoin bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host SIGIL_UID=abc bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host ALLOW_MAINNET=maybe bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host MODE=mainnet ALLOW_MAINNET=no bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host EXPLORER_UID=1000 SIGIL_UID=1000 bash deploy/scripts/deploy-remote.sh
expect_exit 64 env ALLOW_MAINNET=maybe BIN_DIR=/nonexistent bash deploy/scripts/run-local.sh
expect_exit 64 env CHAIN=mainnet sh deploy/docker/entrypoint.sh listener
expect_exit 64 env CHAIN=testnet HOST_P2P_BIND=0.0.0.0 sh deploy/docker/entrypoint.sh listener
expect_exit 64 env CHAIN=testnet HOST_P2P_BIND=0.0.0.0 \
  TESTNET_EXPOSURE_ACK=not-approved sh deploy/docker/entrypoint.sh listener
expect_exit 64 env CHAIN=testnet HOST_P2P_BIND=0.0.0.0 \
  TESTNET_EXPOSURE_ACK=peer-ip-allowlisted REMOTE_PEER_IP=not-an-ip \
  sh deploy/docker/entrypoint.sh listener
expect_exit 64 env P2P_BIND=0.0.0.0 BIN_DIR=/nonexistent bash deploy/scripts/run-local.sh
expect_exit 64 env P2P_BIND=0.0.0.0 TESTNET_EXPOSURE_ACK=not-approved \
  BIN_DIR=/nonexistent bash deploy/scripts/run-local.sh
expect_exit 64 env P2P_BIND=0.0.0.0 TESTNET_EXPOSURE_ACK=peer-ip-allowlisted \
  REMOTE_PEER_IP=not-an-ip BIN_DIR=/nonexistent bash deploy/scripts/run-local.sh
expect_exit 64 env TESTNET_EXPOSURE_ACK=public-testnet-approved-typo \
  BIN_DIR=/nonexistent bash deploy/scripts/run-local.sh

# Valid exposure modes must pass their guards. Later failure is expected here:
# the entrypoint lacks /opt/sigilcoin and run-local receives a missing BIN_DIR.
preflight_state=$(mktemp -d)
expect_not_exit 64 env CHAIN=testnet DATA_DIR="$preflight_state/private" \
  HOST_P2P_BIND=0.0.0.0 TESTNET_EXPOSURE_ACK=peer-ip-allowlisted \
  REMOTE_PEER_IP=198.51.100.10 PEER=198.51.100.10:19446 \
  sh deploy/docker/entrypoint.sh listener
expect_not_exit 64 env CHAIN=testnet DATA_DIR="$preflight_state/public" \
  HOST_P2P_BIND=0.0.0.0 TESTNET_EXPOSURE_ACK=public-testnet-approved \
  sh deploy/docker/entrypoint.sh listener
expect_not_exit 64 env P2P_BIND=0.0.0.0 \
  TESTNET_EXPOSURE_ACK=peer-ip-allowlisted REMOTE_PEER_IP=198.51.100.10 \
  PEER=198.51.100.10:19446 BIN_DIR=/nonexistent bash deploy/scripts/run-local.sh
expect_not_exit 64 env P2P_BIND=0.0.0.0 \
  TESTNET_EXPOSURE_ACK=public-testnet-approved BIN_DIR=/nonexistent \
  bash deploy/scripts/run-local.sh
rm -rf -- "$preflight_state"

if python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 - <<'PY'
import pathlib, yaml
for path in (pathlib.Path('deploy/docker/compose.testnet.yml'), pathlib.Path('deploy/docker/compose.mainnet.yml')):
    with path.open() as stream:
        document = yaml.safe_load(stream)
    assert set(document['services']) == {'listener', 'sync', 'explorer'}
PY
else
  printf 'SKIP: YAML parser unavailable (PyYAML not installed)\n'
fi

tmp=$(mktemp -d)
runner=
deceptive=
cleanup() {
  [[ -z $runner ]] || kill -KILL "$runner" 2>/dev/null || true
  [[ -z $deceptive ]] || kill -KILL "$deceptive" 2>/dev/null || true
  [[ -z $runner ]] || wait "$runner" 2>/dev/null || true
  [[ -z $deceptive ]] || wait "$deceptive" 2>/dev/null || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT

bash_path=$(command -v bash)
mkdir -p -- "$tmp/bin"
cat > "$tmp/bin/sigilcoin" <<EOF
#!$bash_path
case \${1:-} in
  listen)
    child=
    trap '[ -z "\$child" ] || kill "\$child" 2>/dev/null; exit 0' TERM INT HUP
    while :; do sleep 30 & child=\$!; wait "\$child" || true; done
    ;;
  sync)
    : > "\${FAKE_SYNC_STARTED:?}"
    child=
    trap '[ -z "\$child" ] || kill "\$child" 2>/dev/null; exit 0' TERM INT HUP
    sleep 300 & child=\$!; wait "\$child"
    ;;
  *) exit 0 ;;
esac
EOF
cat > "$tmp/bin/sigilcoin-explorer" <<EOF
#!$bash_path
child=
trap '[ -z "\$child" ] || kill "\$child" 2>/dev/null; exit 0' TERM INT HUP
while :; do sleep 30 & child=\$!; wait "\$child" || true; done
EOF
chmod +x -- "$tmp/bin/sigilcoin" "$tmp/bin/sigilcoin-explorer"

DATA_DIR="$tmp/state" LOG_DIR="$tmp/logs" RUN_DIR="$tmp/run" \
  BIN_DIR="$tmp/bin" SYNC_INTERVAL=300 FAKE_SYNC_STARTED="$tmp/sync-started" \
  bash deploy/scripts/run-local.sh >"$tmp/run-local.out" 2>&1 &
runner=$!
for _ in {1..150}; do
  [[ -e $tmp/sync-started ]] && break
  kill -0 "$runner" 2>/dev/null || { cat "$tmp/run-local.out" >&2; fail 'foreground smoke exited early'; }
  sleep 0.05
done
[[ -e $tmp/sync-started ]] || fail 'sync child did not start'
[[ $(stat -c %a -- "$tmp/state") == 750 ]] || fail 'local state mode is not 0750'
for record in stack listener explorer; do
  [[ $(wc -l < "$tmp/run/$record.pid") == 5 ]] || fail "$record PID record lacks identity fields"
done

start_seconds=$SECONDS
RUN_DIR="$tmp/run" bash deploy/scripts/stop-local.sh >/dev/null
for _ in {1..100}; do
  kill -0 "$runner" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$runner" 2>/dev/null && fail 'foreground controller did not exit'
wait "$runner" 2>/dev/null || true
runner=
((SECONDS - start_seconds < 8)) || fail 'active sync child was not stopped promptly'
[[ ! -e $tmp/run/stack.pid && ! -e $tmp/run/listener.pid && ! -e $tmp/run/explorer.pid ]] || \
  fail 'successful stop retained PID files'

mkdir -p -- "$tmp/deceptive-run"
bash -c 'while :; do sleep 1; done' "$root/deploy/scripts/run-local.sh" &
deceptive=$!
sleep 0.1
stat_line=$(<"/proc/$deceptive/stat")
rest=${stat_line##*) }
read -r -a stat_fields <<< "$rest"
starttime=${stat_fields[19]}
exe=$(readlink -f -- "/proc/$deceptive/exe")
printf '%s\n' "$deceptive" "$starttime" stack "$root/deploy/scripts/run-local.sh" "$exe" \
  > "$tmp/deceptive-run/stack.pid"
expect_exit 70 env RUN_DIR="$tmp/deceptive-run" bash deploy/scripts/stop-local.sh
kill -0 "$deceptive" 2>/dev/null || fail 'deceptive unrelated process was killed'
[[ -e $tmp/deceptive-run/stack.pid ]] || fail 'failed stop removed deceptive PID record'
kill -TERM "$deceptive" 2>/dev/null || true
wait "$deceptive" 2>/dev/null || true
deceptive=

printf 'deployment checks passed\n'
