{
  config,
  lib,
  ...
}:
let
  cfg = config.local.incus.network.vpn;
  helpers = import ../lib.nix { inherit lib; };

  # Derived from `ipv4` rather than configured separately: the masquerade rule
  # must match the bridge's actual subnet, and a stale duplicate silently drops
  # VPN-bridge egress.
  vpnSubnet = helpers.cidrToNetwork cfg.ipv4;
in
{
  options.local.incus.network.vpn = {
    enable = lib.mkEnableOption "a managed bridge + `vpn` profile for instances reachable over the WireGuard VPN";

    bridge = lib.mkOption {
      type = lib.types.str;
      default = "incusbr-vpn";
    };

    ipv4 = lib.mkOption {
      type = lib.types.str;
      default = "10.43.0.1/24";
      description = ''
        Explicit IPv4 address for the VPN bridge (not `auto`). Its network
        address is derived from this value for the egress masquerade.

        For VPN clients to reach instances this subnet must be added to the
        host's peer on the router - on an ASUS WireGuard VPN server that is
        the profile's "Allow IPs (Server)" field, alongside the host's /32
        (e.g. 10.6.0.3/32, 10.43.0.0/24); the default /32 alone is not enough,
        and clients then reach the host but not its instances.
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

    dnsZone = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "int.esselius.dev";
      description = ''
        Forward network zone served by Incus's built-in DNS. The zone itself
        and its records are owned by the workload repo's Terranix config.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Trusted so incus traffic on this bridge isn't dropped by the NixOS firewall.
    networking.firewall.trustedInterfaces = [ cfg.bridge ];

    local.incus.spec.networks = lib.mkAfter [
      {
        name = cfg.bridge;
        type = "bridge";
        # nat = false is deliberate: an incus bridge with NAT masquerades
        # instance traffic leaving via *any* non-bridge interface (including
        # wg0), which rewrites instance source IPs on the VPN path and breaks
        # inbound VPN-client -> instance connections. Internet egress is served
        # by the uplink-scoped masquerade below instead, leaving wg0 untouched.
        config = {
          "ipv4.address" = cfg.ipv4;
          "ipv4.nat" = "false";
          "ipv6.address" = "none";
        };
      }
    ];

    # Applied alongside `default` (`-p default -p vpn`): same device key eth0,
    # so this overrides `default`'s bridged NIC onto the VPN bridge.
    local.incus.spec.profiles = lib.mkAfter [
      {
        name = "vpn";
        description = "Attach instances to the WireGuard-reachable bridge";
        devices.eth0 = {
          type = "nic";
          network = cfg.bridge;
          name = "eth0";
        };
      }
    ];

    # Internet egress for the VPN bridge, scoped to the uplink only so the VPN
    # path keeps real instance source IPs (see the network's nat = false note).
    networking.nftables.tables."incus-vpn-nat" = {
      family = "ip";
      content = ''
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr ${vpnSubnet} oifname "${cfg.uplink}" masquerade
        }
      '';
    };
  };
}
