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
# `sigilcoin listen --max-connections 0` IS A DAEMON, and each unit below is
# an ordinary long-lived service that binds its own socket:
#
#   sigilcoin-listen.service   `sigilcoin listen` bound directly to
#                              `listen.bind:listen.port`
#   sigilcoin-sync.service     `sigilcoin run --iterations 0`
#
# Measured against the binary this flake builds, on this host:
#
#   --max-connections 0 --accept-timeout 2000, idle: alive at 30 s and at
#     55 s, ended only by an external `timeout 61` (exit 124). The accept
#     timeout is a poll interval, not a deadline.
#   6 hostile connections (3 garbage writes, 3 bare hangups): every one
#     absorbed, `connections-dropped: 7` counting the 7th, the process alive
#     throughout and still accepting.
#   --max-connections 1, one connect: `connections-accepted: 1`, exit 0. A
#     POSITIVE count is what makes the command return; 0 never does.
#
# `operate.sgl` is explicit about why: the accept loop's `(= max-connections
# 0)` branch loops instead of returning, so the accept timeout is only a poll
# interval, and each connection is served inside its own guard, so a hangup,
# garbage bytes or a silent drop kill that connection and nothing else.
#
# An earlier revision of this module put `systemd-socket-proxyd` in front of
# a loopback listener, on the belief that `listen` exited on an accept
# timeout and that a bare connect-and-hangup ended the accept loop. Both were
# true of an older build and are false now, and the proxy was worse than
# useless: it added a unit pair and a hop, it hid the real peer address from
# a node that will eventually want to ban one, and its own `Restart=always`
# without `StartLimitIntervalSec=0` could put the proxy in `failed` and take
# the public port out of service — the exact outage it was meant to prevent.
# It is gone. The node binds the public port itself.
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
        Node state, mode 0750. Holds `<chain>.sqlite` (headers, blocks,
        UTXOs, mempool, peers) and `wallet/wallet.key` (32-byte secret, mode
        0600, inside a 0700 subdirectory the explorer cannot enter). Back
        both up; see RUNBOOK.md.
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
          Address `sigilcoin listen` binds. A seed must bind a reachable
          address; the CLI's own default of 127.0.0.1 serves nobody.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = if cfg.chain == "sigilcoin-regtest" then 19445 else 19444;
        defaultText = lib.literalExpression "19444 on sigilcoin-main, 19445 on sigilcoin-regtest";
        description = "Public TCP port for inbound peers, bound by the node itself.";
      };

      backlog = lib.mkOption {
        type = lib.types.ints.positive;
        default = 16;
        description = "Accept backlog passed to the node's listening socket.";
      };

      maxConnections = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = ''
          Connections to serve before exiting. 0 means serve indefinitely:
          the accept loop treats `acceptTimeout` as a poll interval and
          never returns on its own, which is what a supervised seed wants.
          The CLI's own default is 1, which would exit after a single peer,
          so 0 is the only sensible value for a service.
        '';
      };

      acceptTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60000;
        description = ''
          Milliseconds the accept loop waits for an inbound connection
          before looking again. With `maxConnections = 0` this is a poll
          interval and nothing else: the process does not exit when it
          elapses. It costs one wakeup per period, so there is no reason to
          make it small.
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
        It still cannot read the wallet key: that lives in
        `<dataDir>/wallet`, mode 0700, which the group cannot traverse, and
        the key itself is 0600 and owned by the node user.

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

      # 0750: the explorer's user reads the database through the group. The
      # wallet key is NOT in this directory — the CLI keeps it in
      # `<dataDir>/wallet`, which it creates 0700 — so group-execute here
      # does not expose it. An earlier CLI chmodded this directory itself to
      # 0700 on first key use and took the explorer offline; see
      # `wallet.sgl`.
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.dataDir}/wallet 0700 ${cfg.user} ${cfg.group} - -"
      ];

      environment.systemPackages = [ cfg.package ];

      networking.firewall.allowedTCPPorts = lib.mkIf (cfg.openFirewall && cfg.listen.enable) [
        cfg.listen.port
      ];

      systemd.services.sigilcoin-listen = lib.mkIf cfg.listen.enable {
        description = "SigilCoin inbound peer service (${cfg.chain})";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        # The listener is persistent and absorbs peer faults itself, so a
        # restart now means a real fault rather than routine operation. Five
        # of them in a minute is a crash loop worth surfacing as `failed`
        # instead of hiding behind an infinite retry.
        startLimitIntervalSec = 60;
        startLimitBurst = 5;

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.dataDir;
          ExecStart = lib.escapeShellArgs (
            [
              "${cfg.package}/bin/sigilcoin"
              "listen"
              "--bind"
              cfg.listen.bind
              "--port"
              (toString cfg.listen.port)
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
          # The process is expected to run for the lifetime of the host, so
          # this restart is for crashes and for `nixos-rebuild`, not for
          # normal traffic. Five seconds because the port is unbound for the
          # whole delay and there is nothing else holding it: long enough
          # that a crash loop cannot spin on CPU, short enough that a peer
          # retrying a dial gets through on its next attempt.
          Restart = "always";
          RestartSec = "5s";
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
