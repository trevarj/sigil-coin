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

bash -n deploy/scripts/deploy-remote.sh deploy/scripts/deploy-site-remote.sh \
  deploy/scripts/deploy-testnet-remote.sh deploy/scripts/run-local.sh \
  deploy/scripts/start-mainnet-miner.sh deploy/scripts/stop-local.sh \
  deploy/scripts/check-deployment.sh
sh -n deploy/docker/entrypoint.sh
for script in deploy/scripts/deploy-remote.sh \
  deploy/scripts/deploy-site-remote.sh deploy/scripts/deploy-testnet-remote.sh \
  deploy/scripts/run-local.sh deploy/scripts/start-mainnet-miner.sh \
  deploy/scripts/stop-local.sh
do
  bash "$script" --help >/dev/null
done
expect_exit 64 bash deploy/scripts/deploy-site-remote.sh
expect_exit 64 bash deploy/scripts/deploy-testnet-remote.sh
expect_exit 64 bash deploy/scripts/deploy-testnet-remote.sh -host

assert_fixed 'root * /srv/sigilcoin/site' deploy/Caddyfile
assert_fixed 'explorer.sigilcoin.lol {' deploy/Caddyfile
assert_fixed 'reverse_proxy 127.0.0.1:8081' deploy/Caddyfile
if grep -Fq 'respond 404' deploy/Caddyfile; then
  fail 'public mainnet explorer still returns the prelaunch 404'
fi
asset_route='@site_assets path /assets/sigilcoin-symbol.png /assets/sigilcoin-favicon.png /assets/plus-jakarta.woff2 /assets/jetbrains-mono.woff2'
assert_fixed "$asset_route" deploy/Caddyfile
[[ $(grep -Fc "$asset_route" deploy/Caddyfile) == 2 ]] ||
  fail 'both explorer hosts must serve the same branding assets'
assert_fixed 'reverse_proxy 127.0.0.1:8080' deploy/Caddyfile
assert_fixed 'pool.testnet.sigilcoin.lol {' deploy/Caddyfile
assert_fixed 'reverse_proxy 127.0.0.1:8082 {' deploy/Caddyfile
assert_fixed 'request_body {' deploy/Caddyfile
assert_fixed 'max_size 2KB' deploy/Caddyfile
assert_fixed 'header_up X-Sigilcoin-Client-IP {remote_host}' deploy/Caddyfile
caddy_config=$(<deploy/Caddyfile)
[[ $caddy_config != *'header_up -X-Sigilcoin-Client-IP'* ]] ||
  fail 'Caddy deletes its trusted pool client-IP header after setting it'
if grep -Fqi 'Access-Control-Allow-Origin' deploy/Caddyfile; then fail 'Caddy unexpectedly enables CORS'; fi
if command -v caddy >/dev/null; then
  caddy validate --config deploy/Caddyfile >/dev/null
else
  printf 'SKIP: Caddy unavailable\n'
fi

assert_fixed 'rev=0b4617ac000d6f3ed9f3d0906e6b746ad995ea03' deploy/flake.nix
assert_fixed '"narHash": "sha256-WKStVY4fEW+xSk1H5RcU10SpXogimNfyt8CPfPwoUtU="' deploy/flake.lock
[[ $(grep -Fc '"rev": "0b4617ac000d6f3ed9f3d0906e6b746ad995ea03"' deploy/flake.lock) == 2 ]] ||
  fail 'deploy lock does not pin both sigil-http revisions'
if grep -Fq 'c24a14cabdb5ceed6273d7a6c1004baee07d69a0' deploy/flake.nix deploy/flake.lock; then
  fail 'deploy still references the obsolete sigil-http revision'
fi
assert_fixed 'makeWrapper' deploy/package.nix
assert_fixed '--prefix PATH : ${lib.makeBinPath [ curl ]}' deploy/package.nix
assert_fixed '--set CURL_CA_BUNDLE ${cacert}/etc/ssl/certs/ca-bundle.crt' deploy/package.nix
assert_fixed '--set SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt' deploy/package.nix

for pattern in '/.sigilcoin/' '**/.sigilcoin/' '/.sigilcoin-testnet/' '**/.sigilcoin-testnet/'; do
  assert_fixed "$pattern" .gitignore
done
for pattern in '.sigilcoin' '.sigilcoin/**' '**/.sigilcoin' '**/.sigilcoin/**' \
  '.sigilcoin-testnet' '.sigilcoin-testnet/**' '**/.sigilcoin-testnet' '**/.sigilcoin-testnet/**'; do
  assert_fixed "$pattern" deploy/docker/Dockerfile.dockerignore
done
for pattern in '--exclude=.sigilcoin/' "--exclude='**/.sigilcoin/'" \
  '--exclude=.sigilcoin-testnet/' "--exclude='**/.sigilcoin-testnet/'" \
  '--exclude=/build/' "--exclude='/packages/*/build/'" \
  "--exclude='/tools/*/build/'" '--exclude=/examples/build/' '--exclude=/test/build/'; do
  assert_fixed "$pattern" deploy/scripts/deploy-remote.sh
done
if grep -Fq -- '--exclude=build/' deploy/scripts/deploy-remote.sh || \
   grep -Fq -- "--exclude='**/build/'" deploy/scripts/deploy-remote.sh; then
  fail 'remote deployment excludes source directories named build'
fi

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
assert_fixed 'HOST_P2P_BIND: ${MAINNET_P2P_BIND:-127.0.0.1}' deploy/docker/compose.mainnet.yml
assert_fixed 'MAINNET_EXPOSURE_ACK: ${MAINNET_EXPOSURE_ACK:-}' deploy/docker/compose.mainnet.yml
assert_fixed '"${MAINNET_P2P_BIND:-127.0.0.1}:${MAINNET_P2P_PORT:-19444}:19444/tcp"' deploy/docker/compose.mainnet.yml
assert_fixed '"127.0.0.1:8081:8080/tcp"' deploy/docker/compose.mainnet.yml
assert_fixed 'profiles: ["mainnet-explorer"]' deploy/docker/compose.mainnet.yml
assert_fixed 'compose_args=(--profile mainnet-explorer' deploy/scripts/deploy-remote.sh
assert_fixed 'default_explorer_port=8081' deploy/scripts/run-local.sh
assert_fixed 'profiles: ["mainnet-miner"]' deploy/docker/compose.mainnet.yml
assert_fixed 'command: ["miner-loop"]' deploy/docker/compose.mainnet.yml
assert_fixed 'MINER_ADDRESS: ${MAINNET_MINER_ADDRESS:-}' \
  deploy/docker/compose.mainnet.yml
assert_fixed 'MAINNET_MINER_ADDRESS=sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud' \
  deploy/scripts/start-mainnet-miner.sh
assert_fixed 'required_address=sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud' \
  deploy/docker/entrypoint.sh
assert_fixed 'launch_time=1789228800' deploy/docker/entrypoint.sh
assert_fixed 'mine canceled: validated tip changed' deploy/docker/entrypoint.sh
assert_fixed 'for command in chmod date mkdir sleep' deploy/docker/Dockerfile
assert_fixed 'compose -p sigilcoin-mainnet' deploy/scripts/start-mainnet-miner.sh
assert_fixed '--wait-timeout 180 miner' deploy/scripts/start-mainnet-miner.sh
assert_fixed '--profile mainnet-miner rm -sf miner' deploy/scripts/deploy-remote.sh
if grep -Fq 'MAINNET_EXPLORER_' deploy/docker/compose.mainnet.yml deploy/docker/.env.example; then
  fail 'mainnet explorer host mapping has an environment override'
fi
assert_fixed 'user: "${POOL_UID:-1002}:${SIGIL_GID:-1000}"' deploy/docker/compose.testnet.yml
assert_fixed 'command: ["relay"]' deploy/docker/compose.testnet.yml
assert_fixed '"127.0.0.1:${POOL_PORT:-8082}:8082/tcp"' deploy/docker/compose.testnet.yml
assert_fixed 'source: ${SIGIL_TESTNET_POOL_STATE_DIR:-./state/testnet-pool}' deploy/docker/compose.testnet.yml
assert_fixed 'target: /var/lib/sigilcoin-pool' deploy/docker/compose.testnet.yml
if grep -Fq 'POOL_UID' deploy/docker/compose.mainnet.yml; then fail 'mainnet Compose includes the testnet pool'; fi
assert_fixed 'TESTNET_EXPOSURE_ACK' deploy/docker/entrypoint.sh
assert_fixed 'peer-ip-allowlisted|public-testnet-approved' deploy/docker/entrypoint.sh
assert_fixed 'peer-ip-allowlisted|public-testnet-approved' deploy/scripts/run-local.sh
assert_fixed 'peer-ip-allowlisted|public-testnet-approved' deploy/scripts/deploy-remote.sh
assert_fixed '"${SIGIL_UID:--}" "${SIGIL_GID:--}"' deploy/scripts/deploy-remote.sh
assert_fixed '"${EXPLORER_UID:--}"' deploy/scripts/deploy-remote.sh
assert_fixed 'umask 0027' deploy/docker/entrypoint.sh
[[ $(grep -Fc 'umask 0027' deploy/docker/entrypoint.sh) == 2 ]] ||
  fail 'relay does not establish the required private-file umask'
assert_fixed 'chmod 0640' deploy/docker/entrypoint.sh
assert_fixed 'chmod 0700' deploy/docker/entrypoint.sh
assert_fixed 'chmod 0600' deploy/docker/entrypoint.sh
assert_fixed 'exec "$coin" relay serve' deploy/docker/entrypoint.sh
assert_fixed '--state-dir /var/lib/sigilcoin-pool' deploy/docker/entrypoint.sh
assert_fixed '--relay http://127.0.0.1:8082' deploy/docker/entrypoint.sh
assert_fixed 'POOL_UID=1002' deploy/docker/.env.example
assert_fixed 'SIGIL_TESTNET_POOL_STATE_DIR=./state/testnet-pool' deploy/docker/.env.example
assert_fixed 'POOL_PORT=8082' deploy/docker/.env.example
grep -Fxq 'MAINNET_P2P_BIND=127.0.0.1' deploy/docker/.env.example ||
  fail 'example mainnet P2P bind is not private'
grep -Fxq 'MAINNET_EXPOSURE_ACK=' deploy/docker/.env.example ||
  fail 'example mainnet exposure acknowledgement is not empty'
assert_fixed 'cmp -s "$caddy_source" /etc/caddy/Caddyfile' \
  deploy/scripts/deploy-remote.sh
assert_fixed 'caddy reload --config "$caddy_source"' deploy/scripts/deploy-remote.sh

assert_fixed 'SSH_IDENTITIES_ONLY must be exactly yes or no' deploy/scripts/deploy-remote.sh
assert_fixed 'rsync "${rsync_transport[@]}"' deploy/scripts/deploy-remote.sh
[[ $(grep -Fc 'rsync "${rsync_transport[@]}"' deploy/scripts/deploy-remote.sh) == 2 ]] ||
  fail 'not every rsync call uses the configured SSH transport'
[[ $(grep -Fc 'ssh "${ssh_options[@]}"' deploy/scripts/deploy-remote.sh) == 2 ]] ||
  fail 'not every deploy-remote SSH call uses configured identity selection'
assert_fixed 'ssh "${ssh_options[@]}"' deploy/scripts/deploy-site-remote.sh
assert_fixed 'ssh -tt "${ssh_options[@]}"' deploy/scripts/deploy-site-remote.sh
assert_fixed '"${EXPLORER_UID:--}" "${POOL_UID:--}"' deploy/scripts/deploy-remote.sh
assert_fixed 'chain and pool state directories must be distinct and non-nested' deploy/scripts/deploy-remote.sh
assert_fixed 'install -d -m 0770 -- "$pool_state_dir"' deploy/scripts/deploy-remote.sh
assert_fixed 'POOL_UID must differ from SIGIL_UID' deploy/scripts/deploy-remote.sh
assert_fixed 'POOL_UID must differ from EXPLORER_UID' deploy/scripts/deploy-remote.sh
if grep -Fq 'sudo ' deploy/scripts/deploy-remote.sh; then fail 'pool provisioning requires sudo'; fi
assert_fixed 'SIGIL_TESTNET_POOL_STATE_DIR="$pool_state_dir"' deploy/scripts/deploy-remote.sh
assert_fixed 'up -d --remove-orphans --wait --wait-timeout 180' deploy/scripts/deploy-remote.sh
assert_fixed 'ps -q pool' deploy/scripts/deploy-site-remote.sh
assert_fixed '/usr/local/bin/sigilcoin-entrypoint health-relay' deploy/scripts/deploy-site-remote.sh
assert_fixed 'https://pool.testnet.sigilcoin.lol/healthz' deploy/scripts/deploy-site-remote.sh
assert_fixed 'https://pool.testnet.sigilcoin.lol/v1/context' deploy/scripts/deploy-site-remote.sh
assert_fixed 'SSH_IDENTITIES_ONLY=no bash "$script_dir/deploy-remote.sh"' deploy/scripts/deploy-testnet-remote.sh
assert_fixed 'SSH_IDENTITIES_ONLY=no bash "$script_dir/deploy-site-remote.sh"' deploy/scripts/deploy-testnet-remote.sh
assert_fixed '--remote-dir /srv/sigilcoin' deploy/scripts/deploy-testnet-remote.sh
assert_fixed '--mode testnet' deploy/scripts/deploy-testnet-remote.sh
assert_fixed 'env_file=$root/deploy/docker/.env' deploy/scripts/deploy-testnet-remote.sh

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
expect_exit 64 env REMOTE_HOST=host SSH_IDENTITIES_ONLY=maybe bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host POOL_UID=1000 SIGIL_UID=1000 bash deploy/scripts/deploy-remote.sh
expect_exit 64 env REMOTE_HOST=host POOL_UID=1001 EXPLORER_UID=1001 bash deploy/scripts/deploy-remote.sh
expect_exit 64 env SSH_IDENTITIES_ONLY=maybe bash deploy/scripts/deploy-site-remote.sh host
expect_exit 64 env SSH_IDENTITIES_ONLY= bash deploy/scripts/deploy-site-remote.sh host
expect_exit 64 env REMOTE_HOST=host SSH_IDENTITIES_ONLY= bash deploy/scripts/deploy-remote.sh
expect_exit 64 env ALLOW_MAINNET=maybe BIN_DIR=/nonexistent bash deploy/scripts/run-local.sh
expect_exit 64 env CHAIN=mainnet sh deploy/docker/entrypoint.sh listener
expect_exit 64 env CHAIN=mainnet ALLOW_MAINNET=yes sh deploy/docker/entrypoint.sh relay
expect_exit 64 env CHAIN=testnet MINER_ADDRESS=sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud \
  sh deploy/docker/entrypoint.sh miner-loop
expect_exit 64 env CHAIN=mainnet ALLOW_MAINNET=yes \
  sh deploy/docker/entrypoint.sh miner-loop
expect_exit 64 env CHAIN=mainnet ALLOW_MAINNET=yes MINER_ADDRESS=sgl1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq \
  sh deploy/docker/entrypoint.sh miner-loop
expect_exit 64 env CHAIN=mainnet ALLOW_MAINNET=yes \
  MINER_ADDRESS=sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud MINE_INTERVAL=0 \
  sh deploy/docker/entrypoint.sh miner-loop
expect_exit 64 env CHAIN=testnet sh deploy/docker/entrypoint.sh cli listen
expect_exit 64 env CHAIN=testnet sh deploy/docker/entrypoint.sh cli -- listen
expect_exit 64 env CHAIN=testnet sh deploy/docker/entrypoint.sh cli status \
  --chain sigilcoin-main
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
expect_exit 64 env CHAIN=mainnet ALLOW_MAINNET=yes HOST_P2P_BIND=0.0.0.0 \
  sh deploy/docker/entrypoint.sh listener
expect_exit 64 env CHAIN=mainnet ALLOW_MAINNET=yes HOST_P2P_BIND=0.0.0.0 \
  MAINNET_EXPOSURE_ACK=public-mainnet-approve sh deploy/docker/entrypoint.sh listener
expect_exit 64 env CHAIN=mainnet ALLOW_MAINNET=yes HOST_P2P_BIND=127.0.0.1 \
  MAINNET_EXPOSURE_ACK=public-mainnet-approved sh deploy/docker/entrypoint.sh listener
expect_exit 64 env MODE=mainnet ALLOW_MAINNET=yes P2P_BIND=0.0.0.0 \
  BIN_DIR=/nonexistent bash deploy/scripts/run-local.sh
expect_exit 64 env MODE=mainnet ALLOW_MAINNET=yes P2P_BIND=0.0.0.0 \
  MAINNET_EXPOSURE_ACK=public-mainnet-approve BIN_DIR=/nonexistent \
  bash deploy/scripts/run-local.sh
expect_exit 64 env MODE=mainnet ALLOW_MAINNET=yes P2P_BIND=127.0.0.1 \
  MAINNET_EXPOSURE_ACK=public-mainnet-approved BIN_DIR=/nonexistent \
  bash deploy/scripts/run-local.sh

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
expect_not_exit 64 env -u HOST_P2P_BIND -u MAINNET_EXPOSURE_ACK \
  CHAIN=mainnet ALLOW_MAINNET=yes DATA_DIR="$preflight_state/mainnet-private" \
  sh deploy/docker/entrypoint.sh listener
expect_not_exit 64 env CHAIN=mainnet ALLOW_MAINNET=yes \
  DATA_DIR="$preflight_state/mainnet-public" HOST_P2P_BIND=0.0.0.0 \
  MAINNET_EXPOSURE_ACK=public-mainnet-approved \
  sh deploy/docker/entrypoint.sh listener
expect_not_exit 64 env -u P2P_BIND -u MAINNET_EXPOSURE_ACK \
  MODE=mainnet ALLOW_MAINNET=yes BIN_DIR=/nonexistent \
  bash deploy/scripts/run-local.sh
expect_not_exit 64 env MODE=mainnet ALLOW_MAINNET=yes P2P_BIND=0.0.0.0 \
  MAINNET_EXPOSURE_ACK=public-mainnet-approved BIN_DIR=/nonexistent \
  bash deploy/scripts/run-local.sh

# Exercise the actual deploy-remote heredoc without SSH, Docker, or deployment.
remote_script=$(sed -n "/<<'REMOTE_SCRIPT'$/,/^REMOTE_SCRIPT$/p" \
  deploy/scripts/deploy-remote.sh | sed '1d;$d')
[[ $remote_script == set\ -euo\ pipefail* ]] ||
  fail 'could not extract deploy-remote preflight'
remote_dir=$preflight_state/remote
mkdir -p -- "$remote_dir/sigil-coin/deploy/docker" "$preflight_state/bin"
cat > "$preflight_state/bin/cmp" <<'EOF'
exit 0
EOF
cat > "$preflight_state/bin/caddy" <<'EOF'
printf '%s\n' "$*" >> "${FAKE_CADDY_CALLS:?}"
EOF
cat > "$preflight_state/bin/docker" <<'EOF'
case " $* " in
  *" config "*|*" build "*|*" rm "*) exit 0 ;;
  *" up "*)
    grep -Fq 'reload --config' "${FAKE_CADDY_CALLS:?}" || exit 68
    exit 69
    ;;
  *) exit 67 ;;
esac
EOF
chmod +x -- "$preflight_state/bin/cmp" "$preflight_state/bin/caddy" \
  "$preflight_state/bin/docker"
remote_uid=$(id -u)
remote_gid=$(id -g)
remote_mainnet=(bash -s -- "$remote_dir" mainnet "$remote_uid" "$remote_gid" \
  "$((remote_uid + 1))" "$((remote_uid + 2))" yes no)
remote_env=(env PATH="$preflight_state/bin:$PATH"
  FAKE_CADDY_CALLS="$preflight_state/caddy-calls"
  SIGIL_MAINNET_STATE_DIR=./state/mainnet)
expect_exit 64 "${remote_env[@]}" MAINNET_P2P_BIND=0.0.0.0 \
  MAINNET_EXPOSURE_ACK= "${remote_mainnet[@]}" <<< "$remote_script"
expect_exit 64 "${remote_env[@]}" MAINNET_P2P_BIND=0.0.0.0 \
  MAINNET_EXPOSURE_ACK=public-mainnet-approve "${remote_mainnet[@]}" <<< "$remote_script"
expect_exit 64 "${remote_env[@]}" MAINNET_P2P_BIND=127.0.0.1 \
  MAINNET_EXPOSURE_ACK=public-mainnet-approved "${remote_mainnet[@]}" <<< "$remote_script"
rm -f -- "$preflight_state/caddy-calls"
expect_exit 69 env -u MAINNET_P2P_BIND -u MAINNET_EXPOSURE_ACK \
  PATH="$preflight_state/bin:$PATH" \
  FAKE_CADDY_CALLS="$preflight_state/caddy-calls" \
  SIGIL_MAINNET_STATE_DIR=./state/mainnet \
  "${remote_mainnet[@]}" <<< "$remote_script"
rm -f -- "$preflight_state/caddy-calls"
expect_exit 69 "${remote_env[@]}" MAINNET_P2P_BIND=0.0.0.0 \
  MAINNET_EXPOSURE_ACK=public-mainnet-approved "${remote_mainnet[@]}" \
  <<< "$remote_script"
injection_marker=$preflight_state/arithmetic-injection
printf 'SIGIL_UID=x[$(touch %s)]\n' "$injection_marker" \
  > "$remote_dir/sigil-coin/deploy/docker/.env"
remote_mainnet_file=(bash -s -- "$remote_dir" mainnet - "$remote_gid" \
  "$((remote_uid + 1))" "$((remote_uid + 2))" yes yes)
expect_exit 64 "${remote_env[@]}" "${remote_mainnet_file[@]}" <<< "$remote_script"
[[ ! -e $injection_marker ]] ||
  fail 'deploy environment executed a command through arithmetic expansion'
rm -rf -- "$preflight_state"

if python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 - <<'PY'
import pathlib, yaml

def load(name):
    with pathlib.Path(name).open() as stream:
        return yaml.safe_load(stream)

testnet = load('deploy/docker/compose.testnet.yml')
mainnet = load('deploy/docker/compose.mainnet.yml')
assert set(testnet['services']) == {'listener', 'sync', 'explorer', 'pool'}
assert set(mainnet['services']) == {'listener', 'sync', 'explorer', 'miner'}

mainnet_listener = mainnet['services']['listener']
assert mainnet_listener['environment']['HOST_P2P_BIND'] == '${MAINNET_P2P_BIND:-127.0.0.1}'
assert mainnet_listener['environment']['MAINNET_EXPOSURE_ACK'] == '${MAINNET_EXPOSURE_ACK:-}'
assert mainnet_listener['ports'] == [
    '${MAINNET_P2P_BIND:-127.0.0.1}:${MAINNET_P2P_PORT:-19444}:19444/tcp'
]
assert mainnet['services']['explorer']['profiles'] == ['mainnet-explorer']
assert mainnet['services']['explorer']['ports'] == ['127.0.0.1:8081:8080/tcp']
miner = mainnet['services']['miner']
assert miner['profiles'] == ['mainnet-miner']
assert miner['command'] == ['miner-loop']
assert miner['environment']['MINER_ADDRESS'] == '${MAINNET_MINER_ADDRESS:-}'
assert miner['depends_on']['sync']['condition'] == 'service_healthy'

pool = testnet['services']['pool']
assert pool['user'] == '${POOL_UID:-1002}:${SIGIL_GID:-1000}'
assert pool['command'] == ['relay']
assert pool['read_only'] is True
assert pool['pids_limit'] == 64
assert pool['mem_limit'] == '256m'
assert pool['cpus'] == '0.5'
assert pool['healthcheck']['test'][-1] == 'health-relay'
assert pool['depends_on']['sync']['condition'] == 'service_healthy'
assert pool['ports'] == ['127.0.0.1:${POOL_PORT:-8082}:8082/tcp']

volumes = {volume['target']: volume for volume in pool['volumes']}
chain = volumes['/var/lib/sigilcoin']
state = volumes['/var/lib/sigilcoin-pool']
assert chain['source'] == '${SIGIL_TESTNET_STATE_DIR:-./state/testnet}'
assert chain['read_only'] is True
assert state['source'] == '${SIGIL_TESTNET_POOL_STATE_DIR:-./state/testnet-pool}'
assert not state.get('read_only', False)
assert chain['source'] != state['source']
PY
else
  printf 'SKIP: YAML parser unavailable (PyYAML not installed)\n'
fi

tmp=$(mktemp -d)
runner=
deceptive=
miner_runner=
cleanup() {
  [[ -z $runner ]] || kill -KILL "$runner" 2>/dev/null || true
  [[ -z $deceptive ]] || kill -KILL "$deceptive" 2>/dev/null || true
  [[ -z $miner_runner ]] || kill -KILL "$miner_runner" 2>/dev/null || true
  [[ -z $runner ]] || wait "$runner" 2>/dev/null || true
  [[ -z $deceptive ]] || wait "$deceptive" 2>/dev/null || true
  [[ -z $miner_runner ]] || wait "$miner_runner" 2>/dev/null || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT

bash_path=$(command -v bash)
mkdir -p -- "$tmp/miner-bin"
cat > "$tmp/miner-bin/date" <<EOF
#!$bash_path
printf '%s\n' "\${FAKE_NOW:?}"
EOF
cat > "$tmp/miner-bin/sigilcoin" <<EOF
#!$bash_path
case \${1:-} in
  status)
    if [[ -e \${FAKE_TIP_CHANGED:?} ]]; then
      printf 'best-block-hash: bb\n'
    else
      printf 'best-block-hash: aa\n'
    fi
    ;;
  mine)
    printf '%s\n' "\$*" > "\${FAKE_MINE_ARGS:?}"
    : > "\${FAKE_MINE_STARTED:?}"
    child=
    stop() {
      [[ -z \$child ]] || kill "\$child" 2>/dev/null || true
      : > "\${FAKE_MINE_CANCELED:?}"
      exit 0
    }
    trap stop TERM INT HUP
    while :; do sleep 30 & child=\$!; wait "\$child" || true; done
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x -- "$tmp/miner-bin/date" "$tmp/miner-bin/sigilcoin"
sed -e "s|coin=/opt/sigilcoin/bin/sigilcoin|coin=$tmp/miner-bin/sigilcoin|" \
  -e "s|/usr/local/bin/date|$tmp/miner-bin/date|" \
  -e 's|sleep 10|sleep 0.05|' \
  deploy/docker/entrypoint.sh > "$tmp/miner-entrypoint.sh"

expect_exit 64 env CHAIN=mainnet ALLOW_MAINNET=yes \
  MINER_ADDRESS=sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud \
  MINE_INTERVAL=1 FAKE_NOW=1789228799 DATA_DIR="$tmp/miner-state" \
  sh "$tmp/miner-entrypoint.sh" miner-loop
[[ ! -e $tmp/mine-started ]] ||
  fail 'prelaunch miner reached its child'

CHAIN=mainnet ALLOW_MAINNET=yes \
  FAKE_NOW=1789228800 \
  MINER_ADDRESS=sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud \
  MINE_INTERVAL=1 DATA_DIR="$tmp/miner-state" \
  FAKE_TIP_CHANGED="$tmp/tip-changed" \
  FAKE_MINE_ARGS="$tmp/mine-args" \
  FAKE_MINE_STARTED="$tmp/mine-started" \
  FAKE_MINE_CANCELED="$tmp/mine-canceled" \
  sh "$tmp/miner-entrypoint.sh" miner-loop >"$tmp/miner.out" 2>&1 &
miner_runner=$!
for _ in {1..100}; do
  [[ -e $tmp/mine-started ]] && break
  kill -0 "$miner_runner" 2>/dev/null || {
    cat "$tmp/miner.out" >&2
    fail 'miner loop exited before launching its child'
  }
  sleep 0.05
done
[[ -e $tmp/mine-started ]] || fail 'miner loop did not launch its child'
grep -Fxq "mine --address sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud --data-dir $tmp/miner-state" \
  "$tmp/mine-args" || fail 'miner did not use the fixed payout address'
[[ ! -e $tmp/miner-state/wallet/wallet.key ]] ||
  fail 'fixed-address miner created a wallet key'
: > "$tmp/tip-changed"
for _ in {1..100}; do
  [[ -e $tmp/mine-canceled ]] && break
  sleep 0.05
done
[[ -e $tmp/mine-canceled ]] || fail 'miner did not cancel after a tip change'
grep -Fq 'mine canceled: validated tip changed' "$tmp/miner.out" ||
  fail 'miner did not report stale-work cancellation'
kill -TERM "$miner_runner"
for _ in {1..100}; do
  kill -0 "$miner_runner" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$miner_runner" 2>/dev/null &&
  fail 'miner loop did not stop promptly'
wait "$miner_runner" 2>/dev/null || true
miner_runner=

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
