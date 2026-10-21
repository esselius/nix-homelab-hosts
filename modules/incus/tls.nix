{
  config,
  lib,
  pkgs,
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
        material, safe to commit. Trusted idempotently by the
        `incus-trust-clients` oneshot below, so no mTLS CA and no join token
        is needed. (The preseed `certificates` list is create-only and errors
        on the re-runs triggered by every incus restart, so it is not used.)
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
      sopsFile = ../../secrets/shared/godaddy.yaml;
    };

    # lego reads the GoDaddy creds from the daemon's environment.
    systemd.services.incus.serviceConfig.EnvironmentFile =
      lib.mkIf cfg.acme.enable
        config.sops.secrets.${cfg.acme.sopsSecret}.path;

    # Non-secret lego tuning (the credentials come from the EnvironmentFile
    # above; note EnvironmentFile= settings win over Environment=).
    #
    # Root cause of the first failed issuance (verified on hardware): GoDaddy
    # recursive caches keep serving a *previous* challenge TXT for the full
    # record TTL (~600s) - longer than lego's window - even after GoDaddy's
    # authoritative NS serves the new value, so lego's recursive-nameserver
    # check times out. Disabling the recursive check (a lego flag, passed via
    # the env incusd's children inherit) makes issuance succeed in ~45s.
    # GODADDY_PROPAGATION_TIMEOUT=300 matches lego's own default, pinned here
    # for visibility rather than kept in the sops secret.
    systemd.services.incus.serviceConfig.Environment = lib.mkIf cfg.acme.enable [
      "GODADDY_PROPAGATION_TIMEOUT=300"
      "LEGO_DNS_PROPAGATION_DISABLE_RNS=true"
    ];

    # Trust client certs idempotently. incus preseed's `certificates` list is
    # create-only and errors with "Certificate already in trust store" on the
    # re-runs triggered whenever incus.service restarts (incus-preseed is
    # partOf it), so ensure them here instead. Names must be unique.
    systemd.services.incus-trust-clients = lib.mkIf (cfg.clientCertificates != { }) {
      description = "Ensure configured incus client certificates are trusted";
      after = [ "incus.service" ];
      requires = [ "incus.service" ];
      partOf = [ "incus.service" ];
      wantedBy = [ "incus.service" ];
      path = [
        config.virtualisation.incus.clientPackage
        pkgs.coreutils
        pkgs.gnugrep
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        trusted="$(incus config trust list --format csv | cut -d, -f1)"
      ''
      + lib.concatMapStrings (entry: ''
        if printf '%s\n' "$trusted" | grep -qxF ${lib.escapeShellArg entry.name}; then
          echo "already trusted: ${entry.name}"
        else
          incus config trust add-certificate ${entry.cert} --name ${lib.escapeShellArg entry.name}
        fi
      '') (lib.mapAttrsToList (name: cert: { inherit name cert; }) cfg.clientCertificates);
    };
  };
}
