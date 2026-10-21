{ config, lib, ... }:
let
  cfg = config.local.site;
in
{
  # Values that must agree across every host in this flake. Declared here as
  # options (so they show up in `nixos-option`) and wired into the per-concern
  # modules with `mkDefault`, so a host can still override any of them.
  options.local.site = {
    zone = lib.mkOption {
      type = lib.types.str;
      default = "int.esselius.dev";
      description = ''
        Internal DNS zone. Served by Incus's built-in DNS (see
        modules/incus/dns.nix) and resolved by each host's Unbound.
      '';
    };

    vpnServer = {
      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "b+Xgh4RNJl20tlnb41DQDIda+jSgP0xfuSpW/NEJGXE=";
        description = "Public key of the router's WireGuard server (public, safe to commit).";
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "195.58.123.102";
        description = "Hostname or IP the router's WireGuard server is reachable at.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 51820;
      };
      vpnSubnet = lib.mkOption {
        type = lib.types.str;
        default = "10.6.0.0/24";
        description = "VPN subnet, used as the router peer's AllowedIPs and route.";
      };
    };

    dns = {
      bootstrap = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          cache = "10.43.0.20";
          monitoring = "10.43.0.12";
        };
        description = ''
          Static A records that must keep resolving when Incus or the zone
          transfer is unavailable. Keys are short names in `zone`.
        '';
      };
      srv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          "_mqtt._tcp" = "0 0 1883 mosquitto.int.esselius.dev.";
        };
        description = "Static SRV records (Incus network zones only accept A/AAAA/CNAME/TXT).";
      };
    };

    incus.uiClientCertificate = lib.mkOption {
      type = lib.types.path;
      default = ../certs/incus-ui-localho.st.crt;
      description = ''
        Browser-generated Incus UI client certificate trusted by every host.
        Public material; see modules/incus/tls.nix for the trust mechanism.
      '';
    };
  };

  config = {
    local.wireguard = {
      serverPublicKey = lib.mkDefault cfg.vpnServer.publicKey;
      serverEndpoint = lib.mkDefault cfg.vpnServer.endpoint;
      serverPort = lib.mkDefault cfg.vpnServer.port;
      vpnSubnet = lib.mkDefault cfg.vpnServer.vpnSubnet;
    };

    local.dns = {
      zone = lib.mkDefault cfg.zone;
      bootstrap = lib.mkDefault cfg.dns.bootstrap;
      srv = lib.mkDefault cfg.dns.srv;
    };

    # Identical on every main host; a host can opt out with a plain `false`.
    local.incus.tls = {
      acme.enable = lib.mkDefault true;
      clientCertificates."incus-ui-localho.st" = cfg.incus.uiClientCertificate;
    };
    local.monitoringAgent.enable = lib.mkDefault true;
  };
}
