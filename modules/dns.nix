{
  config,
  lib,
  ...
}:
let
  cfg = config.local.dns;
  zone = "${cfg.zone}.";
  bootstrapNames = builtins.attrNames cfg.bootstrap;
  srvNames = builtins.attrNames cfg.srv;
in
{
  options.local.dns = {
    enable = lib.mkEnableOption "a host-level Unbound resolver for VPN clients";

    listenAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.1" ];
      description = ''
        Addresses Unbound listens on. Include the host's WireGuard address so
        VPN clients can keep resolving when the Incus bridge is down.
      '';
    };

    zone = lib.mkOption {
      type = lib.types.str;
      default = "int.esselius.dev";
      description = "Internal DNS zone served from Incus or forwarded to a legacy CoreDNS.";
    };

    coredns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.43.0.14";
      description = ''
        Upstream resolver for the internal zone (a legacy CoreDNS or another
        host's Unbound); unused when incusPrimary is set.
      '';
    };

    incusPrimary = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1@1053";
      description = ''
        When set, Unbound becomes an AXFR/IXFR secondary for the internal zone
        instead of forwarding it to CoreDNS. Use the address of the local Incus
        built-in DNS server.
      '';
    };

    upstreams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "1.1.1.1"
        "9.9.9.9"
      ];
      description = "Public recursive resolvers for non-internal names.";
    };

    bootstrap = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        cache = "10.43.0.20";
        monitoring = "10.43.0.12";
      };
      description = ''
        Static records that must keep resolving when CoreDNS is unavailable.
        Keys are short names in `zone`; values are IPv4 addresses.
      '';
    };

    srv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "_mqtt._tcp" = "0 0 1883 mosquitto.int.esselius.dev.";
      };
      description = ''
        Static SRV records. Incus network-zone records only accept
        A/AAAA/CNAME/TXT, so SRV lives in Unbound local-data.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.unbound = {
      enable = true;
      # unbound-checkconf runs in the build sandbox, where the control
      # certificates that `unbound-control-setup` creates at start do not
      # exist. With remote control enabled it therefore rejects a valid config;
      # unbound itself still validates the config on startup.
      checkconf = false;
      # The host's systemd-resolved is configured below; don't also rewrite
      # /etc/resolv.conf through resolvconf.
      resolveLocalQueries = false;

      settings = {
        server = {
          interface = cfg.listenAddresses;
          # Per-query-type/cache stats for the DNS dashboard.
          extended-statistics = true;
          access-control = [
            "127.0.0.0/8 allow"
            "10.6.0.0/24 allow"
          ];
          # The private zone is intentionally unsigned/insecure.
          domain-insecure = zone;
          local-zone = map (name: "${name}.${zone} static") (bootstrapNames ++ srvNames);
          local-data =
            map (name: ''"${name}.${zone} 300 IN A ${cfg.bootstrap.${name}}"'') bootstrapNames
            ++ map (name: ''"${name}.${zone} 300 IN SRV ${cfg.srv.${name}}"'') srvNames;
        };

        auth-zone = lib.optional (cfg.incusPrimary != null) {
          name = zone;
          primary = cfg.incusPrimary;
          zonefile = "${config.services.unbound.stateDir}/${cfg.zone}.zone";
          for-downstream = true;
        };

        # The exporter talks to Unbound over the local TLS control channel.
        remote-control.control-enable = true;

        forward-zone =
          lib.optional (cfg.incusPrimary == null && cfg.coredns != null) {
            name = zone;
            forward-addr = cfg.coredns;
          }
          ++ [
            {
              name = ".";
              forward-addr = cfg.upstreams;
            }
          ];
      };
    };

    # Unbound's own query/cache/rcode metrics, scraped by the local Alloy
    # agent and shipped to VictoriaMetrics. Loopback-only, like the Incus
    # metrics listener.
    services.prometheus.exporters.unbound = {
      enable = true;
      listenAddress = "127.0.0.1";
    };

    # Route only the internal zone to the host resolver. Public names keep
    # using the normal per-link resolvers, so a broken Unbound or CoreDNS does
    # not take the host's internet access down.
    services.resolved = {
      enable = true;
      settings.Resolve = {
        DNS = [ "127.0.0.1" ];
        Domains = [ "~${cfg.zone}" ];
        LLMNR = false;
        MulticastDNS = false;
      };
    };

    # Bind the WireGuard address only after wg0 exists. Start after Incus has
    # been told to serve the zone, but do not require it: a persisted zonefile
    # must still load if Incus is down.
    systemd.services.unbound.after =
      lib.optional (config.local.incus.dnsAddress != null) "incus-dns.service"
      ++ lib.optional config.local.wireguard.enable "wireguard-wg0.service";
    systemd.services.unbound.wants = lib.optional config.local.wireguard.enable "wireguard-wg0.service";
  };
}
