{
  config,
  lib,
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
  };

  config = {
    # Incus asserts on this directly: "Incus on NixOS is unsupported using
    # iptables. Set networking.nftables.enable = true;" (confirmed via a real
    # build failure with this unset).
    networking.nftables.enable = true;

    # Trusted so incus container/VM traffic isn't dropped by the NixOS firewall.
    # (The VPN bridge adds itself when modules/incus/vpn-bridge.nix enables it.)
    networking.firewall.trustedInterfaces = [ cfg.bridge ];

    # Incus REST API + web UI. (SSH opens its own port by default.)
    networking.firewall.allowedTCPPorts = [ config.local.incus.httpsPort ];

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
    ];

    # Applied alongside `default` (`-p default -p lan`): same device key eth0,
    # so this overrides the bridged NIC with a macvlan one. The host cannot
    # reach a macvlan guest directly - intended for instances that should be
    # first-class LAN citizens (own MAC, router DHCP).
    local.incus.spec.profiles = lib.optionals cfg.macvlan.enable [
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
    ];

    # The host's split DNS for `int.esselius.dev` lives in modules/dns.nix,
    # which registers the host resolver on loopback (not on any bridge).
  };
}
