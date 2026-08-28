# NixOS module for a SigilCoin seed node and the read-only explorer.
#
# Two node units, because the CLI has two long-running commands and neither
# does the other's job:
#
#   sigilcoin-listen   `sigilcoin listen` — accepts inbound peers. This is
#                      what makes the host a SEED. It never dials out.
#   sigilcoin-sync     `sigilcoin run`    — dials configured peers, downloads
#                      and validates. This is what keeps the seed's own view
#                      of the chain current.
#
# `sigilcoin listen` IS NOT A DAEMON. Verified against the 0.1.0 binary: the
# accept loop returns, and the process exits 0, as soon as `--accept-timeout`
# elapses with no connection waiting (or the `--max-connections` count is
# reached). `--max-connections 0` removes the connection COUNT limit; it does
# NOT make the loop persistent — see the option's description. So the listen
# process is short-lived by design and restarts constantly.
#
# That is survivable for the process. It is NOT survivable for the port: a
# restarting process closes its listening socket, which destroys the accept
# backlog and refuses every peer that dials during the gap. Measured on the
# 0.1.0 binary, a bare TCP connect-and-hangup ended the accept loop 3/3
# times, so an `nc` loop was enough to keep the seed unreachable.
#
# The kernel therefore owns the public port here, not the node:
#
#   sigilcoin-listen-proxy.socket    holds `listen.bind:listen.port` for the
#                                    lifetime of the host. Accept=no, so the
#                                    backlog survives every restart below.
#   sigilcoin-listen-proxy.service   systemd-socket-proxyd, socket-activated,
#                                    forwards to the loopback listener
#   sigilcoin-listen.service         `sigilcoin listen` bound to
#                                    127.0.0.1:listen.internalPort
#   sigilcoin-sync.service           `sigilcoin run --iterations 0`, which
#                                    genuinely does loop forever, so this one
#                                    is an ordinary long-lived service
#
# Why a proxy and not `Accept=no` straight into `sigilcoin listen`: real
# socket activation needs the program to adopt the fd systemd passes in
# $LISTEN_FDS. Neither the Sigil runtime nor sigil-bitcoin has any such API
# (grep for LISTEN_FDS across both trees returns nothing), and `run-listen`
# unconditionally calls `tcp-listen` to make its own socket. Until the CLI
# can adopt an inherited fd, systemd-socket-proxyd is the only way to put a
# permanently-bound kernel socket in front of it.
#
# The proxy costs nothing in fidelity: `node-serve-inbound-socket` takes the
# peer address as a display label only, and the CLI already passes the
# literal string "inbound" and a counter rather than the real remote address,
# so nothing downstream ever knew where an inbound peer came from.
#
# Both open the same SQLite file, `<dataDir>/<chain>.sqlite`. The Sigil SQLite
# driver sets busy_timeout=0 and retries a contended step rather than blocking,
# so concurrent access works, but it is not free: see the contention note in
# RUNBOOK.md before adding a third writer.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.sigilcoin;
  exp = config.services.sigilcoin-explorer;

  chainFlag = [
    "--chain"
    cfg.chain
  ];
  dataFlag = [
    "--data-dir"
    cfg.dataDir
  ];

  # Hardening shared by every unit here. None of these processes needs a
  # writable filesystem outside its state directory, a second user's home, a
  # kernel tunable, or a new privilege.
  hardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    PrivateUsers = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = false; # the Sigil runtime JITs nothing today, but keep the door open
    RemoveIPC = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@resources"
    ];
    CapabilityBoundingSet = "";
  };

  resourceLimits = {
    MemoryMax = cfg.memoryMax;
    CPUQuota = cfg.cpuQuota;
    TasksMax = 64;
    LimitNOFILE = 4096;
  };
in
{
  options.services.sigilcoin = {
    enable = lib.mkEnableOption "the SigilCoin node";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sigilcoin;
      defaultText = lib.literalExpression "pkgs.sigilcoin";
      description = "Package providing the `sigilcoin` binary.";
    };

    chain = lib.mkOption {
      type = lib.types.enum [
        "sigilcoin-main"
        "sigilcoin-regtest"
      ];
      default = "sigilcoin-main";
      description = ''
        Chain to run. `sigilcoin-main` is the real chain (magic 8f d1 c0 a5,
        default port 19444); `sigilcoin-regtest` is the local chain whose
        block-spacing floor is one second (magic a5 c0 d1 8f, port 19445).
        Changing this after the data directory exists opens a DIFFERENT
        database file, not the same chain under a new name.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sigilcoin";
      description = ''
        Node state. Holds `<chain>.sqlite` (headers, blocks, UTXOs, mempool,
        peers) and `wallet.key` (32-byte secret, mode 0600). Back both up;
        see RUNBOOK.md.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "sigilcoin";
      description = "Unprivileged user the node runs as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "sigilcoin";
      description = "Group owning the data directory. The explorer joins it to read.";
    };

    listen = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run `sigilcoin listen`. Required for a seed node.";
      };

      bind = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        example = "127.0.0.1";
        description = ''
          Public address the `.socket` unit binds. A seed must bind a
          reachable address. The node process itself always binds loopback
          and is reached through the proxy; see the header comment.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = if cfg.chain == "sigilcoin-regtest" then 19445 else 19444;
        defaultText = lib.literalExpression "19444 on sigilcoin-main, 19445 on sigilcoin-regtest";
        description = "Public TCP port for inbound peers, held by the socket unit.";
      };

      internalPort = lib.mkOption {
        type = lib.types.port;
        default = cfg.listen.port + 100;
        defaultText = lib.literalExpression "listen.port + 100";
        description = ''
          Loopback port `sigilcoin listen` binds, and the address
          systemd-socket-proxyd forwards to. Never reachable off-host: the
          node binds 127.0.0.1 and the firewall option only opens
          `listen.port`.
        '';
      };

      backlog = lib.mkOption {
        type = lib.types.ints.positive;
        default = 16;
        description = ''
          Accept backlog. Applied to the kernel-held `.socket` unit, which is
          the one that matters, and passed to the node's own loopback socket
          as well.
        '';
      };

      maxConnections = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = ''
          Connections to serve before exiting. 0 removes the connection COUNT
          limit; it does NOT make the process persistent. The accept loop
          still returns, and the process still exits 0, when
          `acceptTimeout` elapses with nothing waiting — measured at 3.079 s
          with `--accept-timeout 3000 --max-connections 0` and no peers. The
          CLI's own default is 1, which would make the node exit after every
          single peer, so 0 is still the right value for a service.
        '';
      };

      acceptTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60000;
        description = ''
          Milliseconds to wait for an inbound connection before the process
          exits and systemd restarts it. This is the idle re-exec period of
          the listen unit, not just a socket timeout: see the header comment.
          Peers do not see the gap, because the `.socket` unit keeps the
          public port bound across it. Lower it and the unit churns; raise it
          and a crashed listener stays down longer.
        '';
      };

      readTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5000;
        description = "Milliseconds to wait for a peer message.";
      };

      maxSteps = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8;
        description = "Protocol steps served per inbound connection.";
      };

      maxTx = lib.mkOption {
        type = lib.types.ints.positive;
        default = 64;
        description = "Transactions accepted per inbound connection.";
      };
    };

    sync = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run `sigilcoin run` as a long-lived sync and validation loop.";
      };

      retryDelay = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 60000;
        description = ''
          Milliseconds to sleep between passes that made no progress. One
          block a day means an aggressive loop only burns CPU.
        '';
      };

      maxBlocks = lib.mkOption {
        type = lib.types.ints.positive;
        default = 16;
        description = "Block bodies fetched per sync pass.";
      };

      validationBlocks = lib.mkOption {
        type = lib.types.ints.positive;
        default = 128;
        description = ''
          Blocks validated per pass when there is a backlog. Solution
          verification is bounded but not free; a hostile block can cost
          seconds. Lower this if the unit trips its CPU quota.
        '';
      };
    };

    peers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "seed.example.org:19444" ];
      description = ''
        Peers added to the node's peer table before the sync loop starts, as
        HOST, HOST:PORT or [IPv6]:PORT. Adding an existing peer is idempotent.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open `listen.port` in the firewall. A seed node needs this.";
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = "systemd MemoryMax for the node units.";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.str;
      default = "100%";
      description = "systemd CPUQuota for the node units. One core by default.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments appended to both node commands.";
    };
  };

  options.services.sigilcoin-explorer = {
    enable = lib.mkEnableOption "the read-only SigilCoin web explorer";

    package = lib.mkOption {
      type = lib.types.package;
      default = config.services.sigilcoin.package;
      defaultText = lib.literalExpression "config.services.sigilcoin.package";
      description = ''
        Package providing `bin/sigilcoin-explorer`. Defaults to the node
        package: `sigil-coin-explorer`'s package.sgl declares
        `bundle-name: "sigilcoin-explorer"`, so it bundles out of the same
        workspace build and lands in the same derivation.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "sigilcoin-explorer";
      description = ''
        User the explorer runs as. Its PRIMARY group is the node's group,
        which is what lets it read the 0750 data directory and the database.
        It still cannot read `wallet.key`, which is 0600 and owned by the
        node user.

        It is not a supplementary group, and that is deliberate: every unit
        here runs with `PrivateUsers=true`, and in that user namespace only
        the unit's own UID and GID are mapped. A supplementary GID lands as
        65534(nogroup) and `/proc/self/setgroups` reads `deny`, so
        `extraGroups = [ "sigilcoin" ]` fails closed and the explorer cannot
        open the database at all. Verified on this host.
      '';
    };

    bind = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address the explorer binds, passed as the explorer's own `--host`.
        Keep it local and put a TLS reverse proxy in front.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "HTTP port the explorer binds.";
    };

    command = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "${exp.package}/bin/sigilcoin-explorer"
        "--data-dir"
        cfg.dataDir
        "--host"
        exp.bind
        "--port"
        (toString exp.port)
      ]
      ++ lib.optional (cfg.chain == "sigilcoin-regtest") "--regtest";
      defaultText = lib.literalExpression "the explorer's own flag set, derived from services.sigilcoin";
      description = ''
        Confirmed against `explorer-main` in
        `packages/sigil-coin-explorer/src/sigil/coin/explorer/server.sgl`,
        which accepts exactly `--regtest`, `--data-dir`, `--host` and
        `--port`. Chain selection is the bare `--regtest` flag, not
        `--chain NAME` as on the node CLI, and there is no read-only flag:
        read-only is enforced by the unit's `ReadOnlyPaths` instead.

        Override this whole list rather than patching the module if a later
        explorer grows a flag this does not set.
      '';
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = "systemd MemoryMax for the explorer unit.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      users.users.${cfg.user} = {
        isSystemUser = true;
        inherit (cfg) group;
        home = cfg.dataDir;
        description = "SigilCoin node";
      };
      users.groups.${cfg.group} = { };

      # 0750: the explorer's user reads the database through the group; no
      # other account on the host sees the wallet key's directory at all.
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
      ];

      environment.systemPackages = [ cfg.package ];

      networking.firewall.allowedTCPPorts = lib.mkIf (cfg.openFirewall && cfg.listen.enable) [
        cfg.listen.port
      ];

      # The kernel holds the public port. Accept=no, so systemd passes the
      # LISTENING socket to the proxy: the backlog outlives every restart of
      # everything below it, and a peer that dials during a restart waits in
      # that backlog instead of being refused.
      systemd.sockets.sigilcoin-listen-proxy = lib.mkIf cfg.listen.enable {
        description = "SigilCoin public inbound socket (${cfg.chain})";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "${cfg.listen.bind}:${toString cfg.listen.port}" ];
        socketConfig = {
          Accept = false;
          Backlog = cfg.listen.backlog;
          # Bind at boot even if the interface has no address yet, so the
          # port is never briefly absent on a host with slow DHCP or SLAAC.
          FreeBind = true;
        };
      };

      systemd.services.sigilcoin-listen-proxy = lib.mkIf cfg.listen.enable {
        description = "SigilCoin inbound socket proxy (${cfg.chain})";
        requires = [ "sigilcoin-listen-proxy.socket" ];
        after = [
          "sigilcoin-listen-proxy.socket"
          "sigilcoin-listen.service"
        ];

        serviceConfig = {
          Type = "notify";
          User = cfg.user;
          Group = cfg.group;
          ExecStart = lib.escapeShellArgs [
            "${config.systemd.package}/lib/systemd/systemd-socket-proxyd"
            "127.0.0.1:${toString cfg.listen.internalPort}"
          ];
          Restart = "always";
          RestartSec = 1;
          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "sigilcoin-listen-proxy";
        }
        // hardening
        // {
          MemoryMax = "64M";
          CPUQuota = "25%";
          TasksMax = 16;
          LimitNOFILE = 4096;
        };
      };

      systemd.services.sigilcoin-listen = lib.mkIf cfg.listen.enable {
        description = "SigilCoin inbound peer service (${cfg.chain})";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        startLimitIntervalSec = 0;

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.dataDir;
          ExecStart = lib.escapeShellArgs (
            [
              "${cfg.package}/bin/sigilcoin"
              "listen"
              # Loopback on purpose: the public port belongs to the socket
              # unit, and this process is allowed to come and go behind it.
              "--bind"
              "127.0.0.1"
              "--port"
              (toString cfg.listen.internalPort)
              "--backlog"
              (toString cfg.listen.backlog)
              "--max-connections"
              (toString cfg.listen.maxConnections)
              "--accept-timeout"
              (toString cfg.listen.acceptTimeout)
              "--read-timeout"
              (toString cfg.listen.readTimeout)
              "--max-steps"
              (toString cfg.listen.maxSteps)
              "--max-tx"
              (toString cfg.listen.maxTx)
            ]
            ++ chainFlag
            ++ dataFlag
            ++ cfg.extraArgs
          );
          # `listen` exits 0 on an accept timeout, so the restart IS the
          # service. The default start rate limit (5 starts in 10s) would put
          # the unit in `failed` within a minute of normal peer traffic, so
          # it is turned off here. RestartSec is 100ms rather than 1s because
          # the loopback listener is unbound for the whole delay and the
          # proxy drops connections it cannot forward; startup-to-bind was
          # measured at ~0.08 s, so this makes the hole ~0.18 s instead of
          # ~1.07 s. It is not 0: a genuinely crash-looping binary would then
          # spin as fast as it can exit, bounded only by CPUQuota.
          Restart = "always";
          RestartSec = "100ms";
          ReadWritePaths = [ cfg.dataDir ];
          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "sigilcoin-listen";
        }
        // hardening
        // resourceLimits;
      };

      systemd.services.sigilcoin-sync = lib.mkIf cfg.sync.enable {
        description = "SigilCoin sync and validation loop (${cfg.chain})";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.dataDir;
          # Peers are registered before the loop starts. `peers add` is
          # idempotent, so a restart re-asserts the configured set without
          # duplicating rows, and a peer the operator added by hand survives.
          ExecStartPre = map (
            peer:
            "-"
            + lib.escapeShellArgs (
              [
                "${cfg.package}/bin/sigilcoin"
                "peers"
                "add"
                peer
              ]
              ++ chainFlag
              ++ dataFlag
            )
          ) cfg.peers;
          ExecStart = lib.escapeShellArgs (
            [
              "${cfg.package}/bin/sigilcoin"
              "run"
              "--iterations"
              "0"
              "--retry-delay"
              (toString cfg.sync.retryDelay)
              "--max-blocks"
              (toString cfg.sync.maxBlocks)
              "--validation-blocks"
              (toString cfg.sync.validationBlocks)
            ]
            ++ chainFlag
            ++ dataFlag
            ++ cfg.extraArgs
          );
          Restart = "always";
          RestartSec = 30;
          ReadWritePaths = [ cfg.dataDir ];
          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "sigilcoin-sync";
        }
        // hardening
        // resourceLimits;
      };
    })

    (lib.mkIf exp.enable {
      assertions = [
        {
          assertion = cfg.enable;
          message = "services.sigilcoin-explorer needs services.sigilcoin.enable: it reads the node's database.";
        }
      ];

      # Primary group, not a supplementary one. `PrivateUsers=true` maps only
      # the unit's own UID and GID into its user namespace; a supplementary
      # GID arrives unmapped as 65534(nogroup) and cannot be recovered,
      # because `/proc/self/setgroups` is `deny` there. The explorer's own
      # identity is its UID; its read access is its GID.
      users.users.${exp.user} = {
        isSystemUser = true;
        group = cfg.group;
        description = "SigilCoin explorer";
      };

      systemd.services.sigilcoin-explorer = {
        description = "SigilCoin read-only web explorer";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "sigilcoin-sync.service"
        ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "simple";
          User = exp.user;
          Group = cfg.group;
          ExecStart = lib.escapeShellArgs exp.command;
          Restart = "always";
          RestartSec = 10;
          # Read-only is enforced by the kernel, not by a flag the explorer
          # promises to honour. Even a compromised explorer cannot corrupt
          # the chain database.
          ReadOnlyPaths = [ cfg.dataDir ];
          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "sigilcoin-explorer";
        }
        // hardening
        // {
          MemoryMax = exp.memoryMax;
          CPUQuota = "50%";
          TasksMax = 32;
          LimitNOFILE = 1024;
        };
      };
    })
  ];
}
