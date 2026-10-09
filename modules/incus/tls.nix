{
  config,
  lib,
  ...
}:
let
  cfg = config.local.incus.tls;
in
{
  options.local.incus.tls = {
    domain = lib.mkOption {
      type = lib.types.str;
      default = "x.esselius.dev";
    };
    serverName = lib.mkOption {
      type = lib.types.str;
      default = "${config.networking.hostName}.${cfg.domain}";
      description = "FQDN clients use to reach this daemon; becomes the issued cert's SAN.";
    };
    acme = {
      enable = lib.mkEnableOption ''
        a Let's Encrypt server certificate fetched with the DNS-01 challenge via
        the GoDaddy API (incus-native ACME). Needs the GoDaddy credentials in a
        sops secret; until that exists this stays off and incusd serves its
        own self-signed cert (browser warns, but the daemon is fully functional).
      '';
      email = lib.mkOption {
        type = lib.types.str;
        default = "incus@esselius.dev";
      };
      sopsSecret = lib.mkOption {
        type = lib.types.str;
        default = "godaddy_acme";
        description = ''
          Name of the sops secret holding the lego GoDaddy environment, i.e. a
          file whose contents are:
            GODADDY_API_KEY=...
            GODADDY_API_SECRET=...
        '';
      };
    };
    clientCertificates = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        incus clients (e.g. this Mac) to trust, as name -> PEM path. Public
        material, safe to commit. Trusted declaratively via the preseed
        `certificates` list, so no mTLS CA and no join token is needed.
      '';
    };
  };

  config = {
    # incus-native ACME, Let's Encrypt (default ca_url) + DNS-01 through
    # GoDaddy. DNS-01 needs no inbound reachability and no name resolution on
    # the Pi; the browser/client still needs the A record so it can connect.
    local.incus.spec.serverConfig = lib.mkIf cfg.acme.enable {
      "acme.domain" = cfg.serverName;
      "acme.email" = cfg.acme.email;
      "acme.challenge" = "DNS-01";
      "acme.provider" = "godaddy";
      "acme.agree_tos" = "true";
    };

    sops.secrets.${cfg.acme.sopsSecret} = lib.mkIf cfg.acme.enable {
      sopsFile = ../../secrets/rpi5.yaml;
    };

    # lego reads the GoDaddy creds from the daemon's environment.
    systemd.services.incus.serviceConfig.EnvironmentFile =
      lib.mkIf cfg.acme.enable config.sops.secrets.${cfg.acme.sopsSecret}.path;

    # Root cause of the first failed issuance (verified on hardware): GoDaddy
    # recursive caches keep serving a *previous* challenge TXT for the full
    # record TTL (~600s) - longer than lego's window - even after GoDaddy's
    # authoritative NS serves the new value, so lego's recursive-nameserver
    # check times out. incus hardcodes GODADDY_PROPAGATION_TIMEOUT=300 for the
    # lego child, so widening it from here has no effect; disabling the
    # recursive check instead (a lego flag, passed via the env that incusd's
    # children inherit) makes issuance succeed in ~45s.
    systemd.services.incus.serviceConfig.Environment =
      lib.mkIf cfg.acme.enable [ "LEGO_DNS_PROPAGATION_DISABLE_RNS=true" ];

    local.incus.spec.certificates = lib.mapAttrsToList (name: cert: {
      inherit name;
      type = "client";
      certificate = builtins.readFile cert;
    }) cfg.clientCertificates;
  };
}
