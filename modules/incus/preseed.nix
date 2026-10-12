{ config, lib, ... }:
let
  spec = config.local.incus.spec;
  metrics = config.local.incus.metrics;
in
{
  options.local.incus.metrics = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Expose Incus's Prometheus metrics API on a loopback listener so a local
        scraper (Grafana Alloy, see modules/monitoring-agent.nix) can collect
        per-instance CPU/memory/disk/network metrics. Off by default; the
        listener is only useful where a collector runs.
      '';
    };
    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:9100";
      description = ''
        Address:port for the metrics listener. Loopback so it never leaves the
        host; auth is disabled below, which is only safe because of that.
      '';
    };
  };

  config = {
    # The metrics endpoint is served over HTTPS (same certificate as the API;
    # confirmed on hardware - a plain HTTP request is rejected). Authentication
    # (a dedicated `type=metrics` client cert) is disabled because the listener
    # is loopback-only; anything able to reach it already has local access.
    local.incus.spec.serverConfig = {
      "core.https_address" = ":8443";
      "images.auto_update_interval" = "6";
    }
    // lib.optionalAttrs metrics.enable {
      "core.metrics_address" = metrics.address;
      "core.metrics_authentication" = "false";
    };

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
