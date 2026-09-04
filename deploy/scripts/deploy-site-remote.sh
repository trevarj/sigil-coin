#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-site-remote.sh HOST

SSH_IDENTITIES_ONLY=yes|no controls OpenSSH identity selection (default: no).
EOF
}

if (($# == 1)) && [[ $1 == -h || $1 == --help ]]; then
  usage
  exit 0
fi

if (($# != 1)); then
  usage >&2
  exit 64
fi

host=$1
if [[ $host == -* || ! $host =~ ^([A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
  printf 'HOST must be a safe SSH hostname or user@hostname\n' >&2
  exit 64
fi

ssh_identities_only=${SSH_IDENTITIES_ONLY-no}
[[ $ssh_identities_only == yes || $ssh_identities_only == no ]] || {
  printf 'SSH_IDENTITIES_ONLY must be exactly yes or no\n' >&2
  exit 64
}
ssh_options=(-o "IdentitiesOnly=$ssh_identities_only")

printf 'Staging site and Caddy configuration on %s\n' "$host"
ssh "${ssh_options[@]}" "$host" bash -s <<'REMOTE'
set -euo pipefail

remote_dir=/srv/sigilcoin
compose_dir=$remote_dir/sigil-coin/deploy/docker
caddy_source=$remote_dir/sigil-coin/deploy/Caddyfile

cd "$compose_dir"
explorer_container=$(docker compose --env-file .env -f compose.testnet.yml ps -q explorer)
pool_container=$(docker compose --env-file .env -f compose.testnet.yml ps -q pool)
test -n "$explorer_container"
test -n "$pool_container"
test "$(docker inspect --format '{{.State.Health.Status}}' "$pool_container")" = healthy
docker compose --env-file .env -f compose.testnet.yml exec -T pool \
  /usr/local/bin/sigilcoin-entrypoint health-relay >/dev/null
test -f "$caddy_source"

rm -rf "$remote_dir/site.next"
install -d -m 0755 "$remote_dir/site.next"
docker cp "$explorer_container:/opt/sigilcoin/share/sigilcoin-site/." - |
  tar --extract --file=- --directory="$remote_dir/site.next" \
    --no-same-owner --no-same-permissions
chmod 0711 "$remote_dir"
chmod -R u=rwX,go=rX "$remote_dir/site.next"

rm -rf "$remote_dir/site.previous"
if [[ -e $remote_dir/site ]]; then
  mv "$remote_dir/site" "$remote_dir/site.previous"
fi
mv "$remote_dir/site.next" "$remote_dir/site"
rm -rf "$remote_dir/site.previous"

install -m 0644 "$caddy_source" "$remote_dir/Caddyfile"
install -m 0644 /etc/caddy/Caddyfile "$remote_dir/Caddyfile.rollback"
caddy validate --config "$remote_dir/Caddyfile"
REMOTE

printf 'Installing Caddy configuration; sudo may prompt on %s\n' "$host"
ssh -tt "${ssh_options[@]}" "$host" \
  'sudo install -o root -g root -m 0644 /srv/sigilcoin/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy'

curl -fsS https://sigilcoin.lol/ >/dev/null
curl -fsS https://explorer.testnet.sigilcoin.lol/api/summary >/dev/null
curl -fsS https://pool.testnet.sigilcoin.lol/healthz >/dev/null
curl -fsS https://pool.testnet.sigilcoin.lol/v1/context >/dev/null
printf 'Deployment healthy: site, explorer, and testnet pool\n'
