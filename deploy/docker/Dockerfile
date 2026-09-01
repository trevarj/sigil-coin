# syntax=docker/dockerfile:1.7

ARG NIX_IMAGE=nixos/nix:2.35.2

FROM ${NIX_IMAGE} AS builder
WORKDIR /src/sigil-coin

# The main build context is sigil-coin. These two stages are BuildKit named
# contexts supplied by Compose, not images pulled from a registry.
COPY --from=sigil / /src/sigil
COPY --from=sigil-bitcoin / /src/sigil-bitcoin
COPY . /src/sigil-coin

RUN nix --extra-experimental-features 'nix-command flakes' build \
      'path:/src/sigil-coin?dir=deploy#sigilcoin' \
      --override-input sigil path:/src/sigil \
      --override-input sigil-bitcoin path:/src/sigil-bitcoin \
      --out-link /tmp/sigilcoin \
    && readlink -f /tmp/sigilcoin > /tmp/sigilcoin-out \
    && nix-store -qR /tmp/sigilcoin > /tmp/sigilcoin-closure \
    && nix-store --export $(cat /tmp/sigilcoin-closure) > /tmp/sigilcoin.nar

FROM ${NIX_IMAGE} AS runtime
COPY --from=builder /tmp/sigilcoin.nar /tmp/sigilcoin.nar
COPY --from=builder /tmp/sigilcoin-out /tmp/sigilcoin-out
RUN nix-store --import < /tmp/sigilcoin.nar \
    && out="$(cat /tmp/sigilcoin-out)" \
    && test -x "$out/bin/sigilcoin" \
    && test -x "$out/bin/sigilcoin-explorer" \
    && test -f "$out/share/sigilcoin-site/index.html" \
    && mkdir -p /opt /usr/local/bin \
    && ln -s "$out" /opt/sigilcoin \
    && for command in chmod mkdir sleep; do \
         ln -s "$(readlink -f "$(command -v "$command")")" "/usr/local/bin/$command"; \
       done \
    && rm -f /tmp/sigilcoin.nar /tmp/sigilcoin-out

COPY --chmod=0555 deploy/docker/entrypoint.sh /usr/local/bin/sigilcoin-entrypoint
ENV PATH=/opt/sigilcoin/bin:/usr/local/bin:/bin \
    HOME=/tmp \
    DATA_DIR=/var/lib/sigilcoin
WORKDIR /var/lib/sigilcoin
ENTRYPOINT ["/usr/local/bin/sigilcoin-entrypoint"]
CMD ["cli", "help"]
