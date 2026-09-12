#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: start-mainnet-miner.sh

Start the profiled mainnet miner on this Docker Compose host. It pays every
producer reward to the configured external address and stores no wallet key.
EOF
}

if (($#)); then
  case $1 in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
fi

launch_time=1789228800
now=$(date -u +%s) || {
  printf 'could not read the UTC clock\n' >&2
  exit 64
}
[[ $now =~ ^[0-9]+$ ]] || {
  printf 'invalid UTC clock\n' >&2
  exit 64
}
if ((now < launch_time)); then
  printf 'refusing miner before 2026-09-12T16:00:00Z\n' >&2
  exit 64
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../docker" && pwd)
cd "$root"
[[ -f .env ]] || { printf 'missing %s/.env\n' "$root" >&2; exit 66; }

export ALLOW_MAINNET=yes
export MAINNET_MINER_ADDRESS=sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud

docker compose -p sigilcoin-mainnet --env-file .env --profile mainnet-miner \
  -f compose.mainnet.yml up -d --wait --wait-timeout 180 miner

docker compose -p sigilcoin-mainnet --env-file .env --profile mainnet-miner \
  -f compose.mainnet.yml ps miner
printf 'mainnet miner pays: %s\n' "$MAINNET_MINER_ADDRESS"
printf 'logs: cd %q && docker compose -p sigilcoin-mainnet --env-file .env --profile mainnet-miner -f compose.mainnet.yml logs -f miner\n' "$root"
