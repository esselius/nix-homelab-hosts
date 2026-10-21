{ config, lib, ... }:
let
  spec = config.local.incus.spec;
in
{
  options.local.incus.httpsPort = lib.mkOption {
    type = lib.types.port;
    default = 8443;
    description = ''
      Port the Incus API/web UI listens on (`core.https_address`). Also opened
      in the host firewall, so the two can never drift apart.
    '';
  };

  config = {
    # The metrics endpoint is served over HTTPS (same certificate as the API;
    # confirmed on hardware - a plain HTTP request is rejected). Its address and
    # the (disabled) authentication are applied by incus-runtime-config
    # (modules/incus/runtime.nix), together with core.dns_address, so a deploy
    # applies them without restarting incus.
    local.incus.spec.serverConfig = {
      "core.https_address" = ":${toString config.local.incus.httpsPort}";
      "images.auto_update_interval" = "6";
    };

    # The preseed service is PartOf incus.service, so it re-applies on every
    # incus restart/reboot - not just at install. Don't also restart it merely
    # because its unit file changed; the create-only bits (`certificates`) are
    # deliberately kept out, and DNS/metrics are applied idempotently by
    # incus-runtime-config.
    systemd.services.incus-preseed.restartIfChanged = false;

    # Single assembly point for the freeform preseed value (see default.nix).
    # Client certificates are NOT part of the preseed: its `certificates` list is
    # create-only and errors ("Certificate already in trust store") on the
    # re-runs triggered whenever incus.service restarts - tls.nix trusts them
    # idempotently instead.
    virtualisation.incus.preseed = {
      config = spec.serverConfig;
      networks = spec.networks;
      storage_pools = spec.storagePools;
      profiles = spec.profiles;
    };
  };
}
