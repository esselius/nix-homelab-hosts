{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.incus.network;
in
{
  options.local.incus.network = {
    bridge = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
    };
    ipv4 = lib.mkOption {
      type = lib.types.str;
      default = "10.42.0.1/24";
      description = "Explicit IPv4 subnet for the managed bridge (not `auto`), so it stays predictable and non-overlapping across hosts.";
    };
    ipv6 = lib.mkOption {
      type = lib.types.str;
      default = "fd42::1/64";
      description = "Explicit ULA IPv6 subnet for the managed bridge.";
    };
    nat = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "NAT instance traffic to the uplink. Disable only with a routed/macvlan design.";
    };
    macvlan = {
      enable = lib.mkEnableOption "an extra `lan` profile that attaches instances directly to the LAN via macvlan";
      parent = lib.mkOption {
        type = lib.types.str;
        default = "end0";
        description = ''
          Physical uplink the macvlan children are created on. On the Pi 5
          vendor kernel/DTB the wired uplink is end0 (confirmed on rpi5-8gb),
          not eth0; wld0 is the wireless interface. Confirm per board.
        '';
      };
    };
    vpn = {
      enable = lib.mkEnableOption "a managed bridge + `vpn` profile for instances reachable over the WireGuard VPN";
      bridge = lib.mkOption {
        type = lib.types.str;
        default = "incusbr-vpn";
      };
      ipv4 = lib.mkOption {
        type = lib.types.str;
        default = "10.43.0.1/24";
        description = "Explicit IPv4 address for the VPN bridge (not `auto`).";
      };
      subnet = lib.mkOption {
        type = lib.types.str;
        default = "10.43.0.0/24";
        description = ''
          The VPN bridge subnet in network form, used by the egress masquerade.
          For VPN clients to reach instances this must be added to the host's
          peer on the router - on an ASUS WireGuard VPN server that is the
          profile's "Allow IPs (Server)" field, alongside the host's /32
          (e.g. 10.6.0.3/32, 10.43.0.0/24); the default /32 alone is not
          enough, and clients then reach the host but not its instances.
        '';
      };
      uplink = lib.mkOption {
        type = lib.types.str;
        default = "end0";
        description = ''
          Interface instance traffic is masqueraded to for internet egress. On
          the Pi 5 vendor kernel/DTB the wired uplink is end0 (confirmed on
          rpi5-8gb), not eth0. Deliberately never wg0, so instance source IPs
          survive the VPN path. If this does not match the real uplink the
          masquerade rule never matches and VPN-bridge instances lose internet
          egress (they can still reach each other and the host).
        '';
      };
      dns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "10.43.0.14" ];
        description = ''
          Resolvers reachable on the VPN bridge (e.g. a coredns instance). When
          set, the host resolves `dnsDomains` through them via systemd-resolved,
          registered on the bridge link. Must be on this bridge: systemd-resolved
          binds a link's queries to the link, so a resolver on `incusbr-vpn` is
          unreachable if registered on wg0.
        '';
      };
      dnsDomains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "~int.esselius.dev" ];
        description = ''
          systemd-resolved routing domains for `dns`. A leading `~` makes it a
          routing-only domain (split DNS): only queries for that suffix go to
          these resolvers and every other lookup stays direct. Without it the
          name is also added as a search domain.
        '';
      };
    };
  };

  config = {
    # Incus asserts on this directly: "Incus on NixOS is unsupported using
    # iptables. Set networking.nftables.enable = true;" (confirmed via a real
    # build failure with this unset).
    networking.nftables.enable = true;

    # Trusted so incus container/VM traffic isn't dropped by the NixOS firewall.
    networking.firewall.trustedInterfaces = [
      cfg.bridge
    ]
    ++ lib.optional cfg.vpn.enable cfg.vpn.bridge;

    # Incus REST API + web UI. (SSH opens its own port by default.)
    networking.firewall.allowedTCPPorts = [ 8443 ];

    local.incus.spec.networks = [
      {
        name = cfg.bridge;
        type = "bridge";
        config = {
          "ipv4.address" = cfg.ipv4;
          "ipv4.nat" = lib.boolToString cfg.nat;
          "ipv6.address" = cfg.ipv6;
          "ipv6.nat" = lib.boolToString cfg.nat;
        };
      }
    ]
    ++ lib.optionals cfg.vpn.enable [
      {
        name = cfg.vpn.bridge;
        type = "bridge";
        # nat = false is deliberate: an incus bridge with NAT masquerades
        # instance traffic leaving via *any* non-bridge interface (including
        # wg0), which rewrites instance source IPs on the VPN path and breaks
        # inbound VPN-client -> instance connections. Internet egress is served
        # by the uplink-scoped masquerade below instead, leaving wg0 untouched.
        config = {
          "ipv4.address" = cfg.vpn.ipv4;
          "ipv4.nat" = "false";
          "ipv6.address" = "none";
        };
      }
    ];

    # Applied alongside `default` (`-p default -p lan`): same device key eth0,
    # so this overrides the bridged NIC with a macvlan one. The host cannot
    # reach a macvlan guest directly - intended for instances that should be
    # first-class LAN citizens (own MAC, router DHCP).
    local.incus.spec.profiles =
      lib.optionals cfg.macvlan.enable [
        {
          name = "lan";
          description = "Attach instances directly to the LAN via macvlan";
          devices.eth0 = {
            type = "nic";
            nictype = "macvlan";
            parent = cfg.macvlan.parent;
            name = "eth0";
          };
        }
      ]
      # Same stacking trick as `lan`: override `default`'s eth0 to put instances
      # on the WireGuard-reachable bridge (`incus launch ... -p default -p vpn`).
      ++ lib.optionals cfg.vpn.enable [
        {
          name = "vpn";
          description = "Attach instances to the WireGuard-reachable bridge";
          devices.eth0 = {
            type = "nic";
            network = cfg.vpn.bridge;
            name = "eth0";
          };
        }
      ];

    # Internet egress for the VPN bridge, scoped to the uplink only so the VPN
    # path keeps real instance source IPs (see the network's nat = false note).
    networking.nftables.tables."incus-vpn-nat" = lib.mkIf cfg.vpn.enable {
      family = "ip";
      content = ''
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr ${cfg.vpn.subnet} oifname "${cfg.vpn.uplink}" masquerade
        }
      '';
    };

    # Host split DNS for the VPN bridge's resolver (`local.incus.network.vpn.dns`
    # / `dnsDomains`). Registered on the bridge, not wg0: systemd-resolved binds a
    # link's queries to that link, and the resolver is on incusbr-vpn. Needs
    # systemd-resolved (openresolv/glibc cannot route a domain to a server).
    #
    # LLMNR/mDNS are disabled: there are no responders on these subnets, so a
    # PTR (e.g. ping printing a reply address, or any reverse lookup) falls
    # through to LLMNR + mDNS on the link and waits out both timeouts (~10s)
    # after the DNS answer already arrived. Confirmed on hardware.
    services.resolved = lib.mkIf (cfg.vpn.dns != [ ]) {
      enable = true;
      settings.Resolve = {
        LLMNR = false;
        MulticastDNS = false;
      };
    };

    systemd.services.incus-vpn-dns = lib.mkIf (cfg.vpn.dns != [ ]) {
      description = "Register the VPN bridge resolver with systemd-resolved";
      after = [
        "incus.service"
        "systemd-resolved.service"
      ];
      wants = [ "systemd-resolved.service" ];
      partOf = [ "incus.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        config.systemd.package
        pkgs.iproute2
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # incus.service returns before its networks are created; wait for the
        # bridge to exist before registering DNS on it.
        for _ in {1..60}; do
          ip link show ${lib.escapeShellArg cfg.vpn.bridge} >/dev/null 2>&1 && break
          sleep 1
        done
        resolvectl dns ${lib.escapeShellArg cfg.vpn.bridge} ${lib.escapeShellArgs cfg.vpn.dns}
      ''
      + lib.optionalString (cfg.vpn.dnsDomains != [ ]) ''
        resolvectl domain ${lib.escapeShellArg cfg.vpn.bridge} ${lib.escapeShellArgs cfg.vpn.dnsDomains}
      '';
    };
  };
}
