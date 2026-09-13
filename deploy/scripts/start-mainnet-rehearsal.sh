#!/usr/bin/env bash
set -euo pipefail


root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../docker" && pwd)
cd "$root"

for name in sigilcoin-main-rehearsal-a sigilcoin-main-rehearsal-b sigilcoin-main-rehearsal-miner; do
  ! docker container inspect "$name" >/dev/null 2>&1 || {
    echo "refusing existing rehearsal container: $name" >&2
    exit 73
  }
done

state_a=$root/state/mainnet-rehearsal-a-proof-of-golf
state_b=$root/state/mainnet-rehearsal-b-proof-of-golf
[[ ! -e $state_a && ! -e $state_b ]] || {
  echo "refusing existing rehearsal state; archive it first" >&2
  exit 73
}
install -d -m 0750 "$state_a" "$state_b"
docker network inspect sigilcoin-main-rehearsal >/dev/null 2>&1 ||
  docker network create sigilcoin-main-rehearsal >/dev/null

common=(
  --user 1000:1000
  --init
  --read-only
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m
  --cap-drop ALL
  --security-opt no-new-privileges:true
  --pids-limit 128
  --memory 768m
  --cpus 1.0
  --network sigilcoin-main-rehearsal
  -e CHAIN=mainnet
  -e ALLOW_MAINNET=yes
  -e DATA_DIR=/var/lib/sigilcoin
)
image=${SIGIL_IMAGE:-sigilcoin-proof-of-golf:latest}

docker run -d --name sigilcoin-main-rehearsal-a --restart unless-stopped \
  --network-alias main-a "${common[@]}" \
  -v "$state_a:/var/lib/sigilcoin" \
  --entrypoint /usr/local/bin/sigilcoin-entrypoint "$image" listener >/dev/null
docker run -d --name sigilcoin-main-rehearsal-b --restart unless-stopped \
  "${common[@]}" -e PEER=main-a:19444 \
  -v "$state_b:/var/lib/sigilcoin" \
  --entrypoint /usr/local/bin/sigilcoin-entrypoint "$image" sync-loop >/dev/null

# Rehearse the real schedule and payout guard, not an accelerated mainnet.
docker run -d --name sigilcoin-main-rehearsal-miner \
  "${common[@]}" \
  -e MINER_ADDRESS=sgl1qj9f6eeqxhjgynml4glztyrdw5tj5fn72s6shud \
  -e MINE_INTERVAL=60 \
  -v "$state_a:/var/lib/sigilcoin" \
  --entrypoint /usr/local/bin/sigilcoin-entrypoint "$image" producer-loop >/dev/null

printf 'rehearsal-started: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'inspect: docker logs -f sigilcoin-main-rehearsal-miner\n'
printf 'compare: docker exec sigilcoin-main-rehearsal-a /opt/sigilcoin/bin/sigilcoin status --data-dir /var/lib/sigilcoin\n'
printf '         docker exec sigilcoin-main-rehearsal-b /opt/sigilcoin/bin/sigilcoin status --data-dir /var/lib/sigilcoin\n'
