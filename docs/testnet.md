# Public testnet operator runbook

This runbook covers the 30-day public `sigilcoin-testnet` exercise. The stable
seed is a RackNerd host at `seed.testnet.sigilcoin.lol:19446`. Community nodes
may join and leave without permission.

Testnet coins are worthless. Never use a production key, address, seed phrase,
wallet backup, or unrevealed production material on testnet. Do not promote
this chain, its state, or its keys to mainnet, and do not push a mainnet launch
because a testnet gate passed.

## Frozen testnet parameters

- Chain: `sigilcoin-testnet`, selected with `--testnet`.
- DNS seed and P2P endpoint: `seed.testnet.sigilcoin.lol:19446`.
- P2P transport: TCP port `19446`.
- Address HRP: `tsgl`, producing `tsgl1...` addresses.
- Genesis and consensus rules: the existing canonical testnet values.
- Minimum spacing: one hour.
- Explorer: `https://explorer.testnet.sigilcoin.lol` through a host TLS reverse
  proxy to the container's loopback-only `127.0.0.1:8080` mapping.
- Exercise duration: 30 consecutive days, with day-7 and day-30 gates.

One hour is the network's target operating cadence and enforced minimum block
spacing. It is not a participation schedule. Community miners are not assigned
slots, are not required to remain online, and must not mine catch-up bursts.

## Safety boundary

Public mode exposes an unauthenticated P2P service to the Internet. Before
opening it, confirm resource limits, rotating logs, provider and host firewall
rules, monitoring, backups, and an incident shutdown path. The explorer
container must never bind a public host interface. Only the host reverse proxy
may expose it.

Keep SSH administration separate from public services: restrict TCP/22 (or the
chosen admin port) to operator source addresses or a VPN. Do not infer that an
open P2P firewall rule authorizes public SSH.

All testnet wallets are disposable secrets. Keep `wallet/` mode `0700`,
`wallet/wallet.key` mode `0600`, backups encrypted and offline, and commitment
blinds private. Never paste keys or backups into logs, chat, tickets, or source.

## DNS and network readiness

Create these operator-owned DNS records with TTL 300 initially:

| Name | Record | Value |
| --- | --- | --- |
| `seed.testnet.sigilcoin.lol` | A | seed host public IPv4 |
| `explorer.testnet.sigilcoin.lol` | A | seed host public IPv4 (host reverse proxy) |

Both A records point to the RackNerd seed host. Keep the seed record
DNS-only, with no HTTP CDN or proxy in front of P2P. No SRV record is needed;
port `19446` is part of the chain configuration. Add AAAA records only after
the node listener, reverse proxy, provider firewall, host firewall, and
off-host probes have all been validated over IPv6.

Firewall policy:

- allow public TCP/19446 to the seed node;
- allow public TCP/443 to the reverse proxy;
- allow TCP/80 only if the operator intentionally uses HTTP-to-HTTPS redirect
  or an ACME HTTP challenge;
- never allow public TCP/8080; it stays on `127.0.0.1`;
- restrict admin SSH separately to approved operator sources.

Validate from a machine outside the host network:

```sh
dig +short A seed.testnet.sigilcoin.lol
dig +short A explorer.testnet.sigilcoin.lol
nc -vz seed.testnet.sigilcoin.lol 19446
curl -fsS https://explorer.testnet.sigilcoin.lol/api/summary \
  | jq -e '.chain == "sigilcoin-testnet"'
```

If AAAA is published, repeat DNS, `nc`, and `curl` with IPv6 forced. A broken
AAAA record is an outage for clients that prefer IPv6.

## Start the stable seed

Use the Docker deployment workflow in [deployment.md](deployment.md). The seed
host's environment must explicitly select public mode:

```sh
P2P_BIND=0.0.0.0
P2P_PORT=19446
TESTNET_EXPOSURE_ACK=public-testnet-approved
REMOTE_PEER_IP=
EXPLORER_PORT=8080
```

The exact acknowledgement is intentional approval of Internet-facing P2P. A
missing, misspelled, or alternate value must fail before startup. Do not expose
the seed until both provider and host firewall policies are ready.

After startup:

```sh
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml ps
docker compose --env-file .env -f compose.testnet.yml logs --tail=100 listener sync explorer
docker compose --env-file .env -f compose.testnet.yml exec sync \
  /usr/local/bin/sigilcoin-entrypoint cli status
ss -ltn
```

Require P2P on the intended public interface, explorer host port only at
`127.0.0.1:8080`, healthy containers, the canonical testnet genesis, and no
unexpected listener.

## Community bootstrap

A current node automatically reads the canonical DNS seed. An operator may
also make bootstrap explicit:

```sh
sigilcoin peers add seed.testnet.sigilcoin.lol:19446 --testnet \
  --data-dir "$DATA"
sigilcoin peers test seed.testnet.sigilcoin.lol:19446 --testnet \
  --data-dir "$DATA"
sigilcoin sync --peer seed.testnet.sigilcoin.lol:19446 --testnet \
  --data-dir "$DATA" --iterations 1 --max-steps 4096 --max-blocks 256
```

A community operator may manually configure any trusted reachable testnet peer.
DNS is bootstrap, not an authority over consensus. Every node validates the
canonical genesis and rules independently. A `sgl1...` address or a genesis
mismatch is grounds to stop; testnet addresses must begin `tsgl1...`.

## Local Nix loopback workflow

From the `sigil-coin` checkout inside the workspace, use the workspace's pinned
Nix environment. This joins the public seed outbound while keeping local P2P
and explorer ports loopback-only:

```sh
nix develop .. -c env \
  MODE=testnet \
  BIN_DIR="$PWD/build/dev/bin" \
  PEER=seed.testnet.sigilcoin.lol:19446 \
  P2P_BIND=127.0.0.1 \
  P2P_PORT=19446 \
  EXPLORER_PORT=8080 \
  bash deploy/scripts/run-local.sh
```

The explorer is available only at `http://127.0.0.1:8080/`. No exposure
acknowledgement is needed for this fail-closed loopback mode. Ctrl-C stops the
foreground stack and preserves state. This workflow is for a trusted local
host, not the public RackNerd seed.

## Explorer TLS reverse proxy

The Docker mapping is fixed at `127.0.0.1:8080`. Certificate issuance,
renewal, redirects, headers, and proxy lifecycle are operator-owned host
configuration. Do not place Docker on ports 80 or 443 and do not add an
explorer bind override.

A Caddy site using certificate files already provisioned by the operator:

```caddyfile
explorer.testnet.sigilcoin.lol {
    tls /path/to/operator-managed/fullchain.pem /path/to/operator-managed/privkey.pem
    reverse_proxy 127.0.0.1:8080
}
```

A generic nginx server after the operator has provisioned certificate files:

```nginx
server {
    listen 443 ssl;
    server_name explorer.testnet.sigilcoin.lol;

    ssl_certificate     /path/to/operator-managed/fullchain.pem;
    ssl_certificate_key /path/to/operator-managed/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

These are examples, not automatic certificate installation. Validate `/`,
`/blocks`, `/difficulty`, `/api/summary`, `/api/blocks`, and `/api/difficulty`
over HTTPS. Confirm direct off-host access to TCP/8080 fails.

## Daily operations

Record evidence in UTC. Do not record environment dumps or wallet material.
At least daily:

1. Capture node status: tip height/hash, validated bodies, next complexity,
   peer successes/failures, and last sync outcome.
2. Compare the seed with at least one independently operated node at the same
   height.
3. Probe DNS, public P2P, HTTPS explorer, and confirm TCP/8080 remains private.
4. Review listener, sync, reverse-proxy, firewall, and kernel logs for malformed
   traffic, repeated connection pressure, crashes, and rate spikes.
5. Record container restart counts, RSS, CPU, disk use, inode use, database
   growth, network traffic, and file-descriptor/PID pressure against limits.
6. Confirm log rotation is retaining useful incident evidence without filling
   disk. Never enable request or environment logging that leaks secrets.
7. Check backup freshness without printing or opening wallet material.

The seed operator targets roughly one accepted block per hour without catch-up
mining. Community blocks may change the observed count, so do not treat a
volunteer's missed hour as an incident or impose a participation roster.

## Consensus and interoperability evidence

Complete these before day 7 and repeat representative cases before day 30:

- Retarget: capture H15, H16, and H17 puzzle complexity and historical queries;
  the first 16-block boundary must agree across nodes.
- Maturity: show H1 coinbase immature through H99 and spendable at H100, then
  send a small amount between disposable `tsgl1...` wallets.
- Co-op: carry a commitment at H and its authorized reveal at H+1; require
  non-zero aggregate Q and positive share/carrier payouts.
- Reorg: create equal-height siblings in a controlled window, extend one, and
  require all nodes and explorer canonical views to converge without database
  editing.
- Restart: cleanly restart each service and preserve tip, balance, peers, and
  explorer state.
- Hard kill: once while the listener is idle, kill only one node, recover via
  normal SQLite opening/sync, and verify no lost validated state.
- Restore: restore an offline backup onto an empty test location and verify
  status, disposable address, balance, sync, and explorer routes.
- Explorer: check canonical block/PBE/score/Q/co-op and address HTML/JSON,
  read-only behavior, and escaping of harmless hostile-looking graffiti such
  as `<b>test</b>`.

Never coordinate a fault drill that takes every reachable bootstrap node down
at once. Announce a bounded drill window, but do not assign mining obligations
to community members.

## Backups and restore

A plain filesystem archive is consistent only while listener, sync, explorer,
and every command that can write the database are stopped:

```sh
cd /srv/sigilcoin/sigil-coin/deploy/docker
docker compose --env-file .env -f compose.testnet.yml stop
install -d -m 0700 "$HOME/sigilcoin-testnet-backups"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
state_dir=${SIGIL_TESTNET_STATE_DIR:-"$PWD/state/testnet"}
[[ $state_dir == /* ]] || state_dir=$PWD/${state_dir#./}
tar -C "$state_dir" -czf "$HOME/sigilcoin-testnet-backups/$stamp.tgz" .
chmod 0600 "$HOME/sigilcoin-testnet-backups/$stamp.tgz"
sha256sum "$HOME/sigilcoin-testnet-backups/$stamp.tgz" \
  >"$HOME/sigilcoin-testnet-backups/$stamp.tgz.sha256"
docker compose --env-file .env -f compose.testnet.yml up -d
```

Encrypt backups at rest and copy them to an operator-controlled offline
location. A backup contains the disposable private key and may contain
unrevealed commitment blinds. Never commit it or rsync it into a source tree.
For a restore drill, verify the checksum, preserve the failed state, extract to
an empty directory with restrictive modes, start sync before explorer, and
compare the restored node to an independent peer.

## Upgrade and rollback

Before every upgrade:

1. Review and record exact source revisions and image identity.
2. Stop database users and take a verified offline backup.
3. Preserve the current image under an immutable rollback tag.
4. Build and start the reviewed image without changing genesis or rules.
5. Compare status, resource use, public P2P, and explorer routes with the
   pre-upgrade baseline and an independent node.

Rollback only to a reviewed schema-compatible image. If compatibility is
uncertain, stop and restore the matching backup instead of trying binaries
against a newer database. Never make an unreviewed source push or a mainnet
push to repair the public testnet.

## Incident shutdown

Shut down public service immediately for suspected consensus divergence,
database corruption, key disclosure, uncontrolled resource exhaustion, or an
abuse event that cannot be safely bounded:

1. Block new public TCP/19446 at provider and host firewalls. Keep restricted
   admin access available.
2. Stop mining and sync, then stop listener and explorer cleanly when possible.
3. If compromise is suspected, stop the reverse proxy route as well; do not
   expose port 8080 as a workaround.
4. Preserve rotating logs, status output, process/resource metrics, image
   identity, and a read-only copy of state. Do not publish secrets.
5. Notify participants through the established testnet channel with symptoms
   and the last trusted tip, not speculative fixes.
6. Reproduce and review the cause offline. Resume only with a documented
   recovery and independent-node agreement.

A testnet outage is preferable to silently serving a divergent chain. Incident
recovery does not authorize mainnet, deployment automation, a source push, or
DNS changes.

## Day-7 gate

Continue only when all of these are evidenced:

1. Seed and an independent node agree on canonical tip and validated bodies.
2. DNS bootstrap, public TCP/19446, and HTTPS explorer work off-host while
   direct TCP/8080 remains unreachable.
3. H16 retarget, H100 maturity/transfer, and one commit/reveal/Q/payout cycle
   pass where their heights have been reached. If public cadence has not yet
   reached a boundary, extend the gate rather than waive it.
4. A reorg, clean restart, hard-kill recovery, offline backup, and restore pass.
5. Explorer canonical/read-only/XSS checks pass.
6. Logs and metrics show bounded CPU, memory, disk, PIDs, file descriptors,
   traffic, and restart behavior under public input.
7. No production key, secret, backup, or mainnet state was used or disclosed.

Stop and preserve evidence for any unexplained tip disagreement, validation
mismatch, database error, sustained resource growth, or loss of network
control.

## Day-30 gate

The public testnet exercise completes only when:

- it operated for 30 consecutive days with the one-hour cadence used as a
  network target, not an enforced community participation schedule;
- seed and independent nodes finish on the same canonical tip, validated body
  count, next complexity, and UTXO-derived balances;
- every observed retarget and the H100 maturity boundary are correct;
- at least two commit/reveal/co-op cycles from distinct periods produce valid
  non-zero Q and payouts;
- repeated reorg, restart, hard-kill, backup, restore, upgrade, and rollback
  exercises recover without manual database editing or wallet loss;
- explorer HTML/JSON remains correct, read-only, TLS-only publicly, and
  XSS-safe, with port 8080 loopback-only;
- abuse, logs, resources, uptime, and database growth have a reviewed 30-day
  record with no unresolved trend or incident;
- bootstrap from `seed.testnet.sigilcoin.lol:19446` works for a fresh community
  node without a hand-entered IP;
- no production key or mainnet state entered the exercise.

Archive only sanitized evidence. Passing day 30 is a prerequisite for the
separate mainnet soak, not approval to launch, push, deploy mainnet, or reuse
any testnet key or database.
