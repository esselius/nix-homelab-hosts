{ config, lib, ... }:
let
  cfg = config.local.wireguard;
in
{
  # The Pi hosts join the router's WireGuard server as *split-tunnel nodes*, not
  # road-warrior clients: AllowedIPs is the VPN subnet only, never 0.0.0.0/0.
  # A default route via wg0 would drag all of the host's (and its instances')
  # traffic through the router and complicate the LAN/incus routing, whereas the
  # split tunnel still lets the Pi reach every VPN client and lets instance
  # reply traffic find its way back. The VPN server must route this host's
  # incus subnets to the tunnel for inbound reachability (see README).
  options.local.wireguard = {
    enable = lib.mkEnableOption "a WireGuard client interface to the router VPN";

    address = lib.mkOption {
      type = lib.types.str;
      example = "10.6.0.3/32";
      description = "This host's address inside the VPN subnet.";
    };

    privateKeySecret = lib.mkOption {
      type = lib.types.str;
      default = "wg_private_key";
      description = "sops secret (in secrets/rpi5.yaml) holding this host's base64 WireGuard private key.";
    };

    serverPublicKey = lib.mkOption {
      type = lib.types.str;
      description = "Public key of the router's WireGuard server (the only peer).";
    };

    serverEndpoint = lib.mkOption {
      type = lib.types.str;
      example = "195.58.123.102";
      description = "Hostname or IP the router's WireGuard server is reachable at.";
    };

    serverPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
    };

    vpnSubnet = lib.mkOption {
      type = lib.types.str;
      default = "10.6.0.0/24";
      description = ''
        VPN subnet. Becomes the peer's AllowedIPs and the route added via wg0,
        so the host can reach other VPN clients and return instance traffic to
        them. Deliberately not 0.0.0.0/0 (split tunnel).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.${cfg.privateKeySecret} = {
      sopsFile = ../secrets/rpi5.yaml;
    };

    networking.wireguard.interfaces.wg0 = {
      ips = [ cfg.address ];
      privateKeyFile = config.sops.secrets.${cfg.privateKeySecret}.path;
      # Add the peer's AllowedIPs as routes; without this the host can reach the
      # router but not the rest of the VPN subnet, and instance replies would
      # egress the wrong interface.
      allowedIPsAsRoutes = true;
      peers = [
        {
          publicKey = cfg.serverPublicKey;
          endpoint = "${cfg.serverEndpoint}:${toString cfg.serverPort}";
          allowedIPs = [ cfg.vpnSubnet ];
          # Keep the NAT mapping on the router alive so the server can always
          # push packets back to this host behind its home NAT.
          persistentKeepalive = 25;
        }
      ];
    };

    # wg0 carries traffic for the incus bridge (and the host itself); trusted so
    # the NixOS firewall doesn't drop the forwarded VPN <-> incusbr-vpn flows.
    networking.firewall.trustedInterfaces = [ "wg0" ];

    # Forward between wg0 and the incus bridges. Incus also sets this, but make
    # it explicit since the routed VPN path depends on it.
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  };
}
