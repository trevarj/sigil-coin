#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: deploy-testnet-remote.sh HOST\n'
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

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$script_dir/../.." && pwd)
env_file=$root/deploy/docker/.env
[[ -f $env_file && ! -L $env_file ]] || {
  printf 'required deployment environment file is missing or unsafe: %s\n' "$env_file" >&2
  exit 66
}

SSH_IDENTITIES_ONLY=no bash "$script_dir/deploy-remote.sh" \
  --host "$host" \
  --remote-dir /srv/sigilcoin \
  --mode testnet \
  --env-file "$env_file"
SSH_IDENTITIES_ONLY=no bash "$script_dir/deploy-site-remote.sh" "$host"
