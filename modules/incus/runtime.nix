{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.incus;
in
{
  options.local.incus.dnsAddress = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "127.0.0.1:1053";
    description = ''
      Enable Incus's built-in DNS server at this address. It serves network
      zones over AXFR only; a local secondary (Unbound) consumes the zone.
    '';
  };

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
        host; authentication is disabled, which is only safe because of that.
      '';
    };
  };

  # Settings that must be applied through the daemon API rather than the
  # preseed. The preseed unit is PartOf=incus.service but has
  # RestartIfChanged=false, so a deploy that only edits the preseed does not
  # take effect until incus is restarted by hand. Everything here is
  # idempotent (`incus config set`) and re-applied on every incus start.
  config = lib.mkIf (cfg.dnsAddress != null || cfg.metrics.enable) {
    systemd.services.incus-runtime-config = {
      description = "Apply idempotent Incus runtime settings (DNS + metrics)";
      after = [
        "incus.service"
        "incus-preseed.service"
      ];
      wants = [ "incus.service" ];
      partOf = [ "incus.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.incus-lts.client ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 2;
      };
      script = ''
        set -euo pipefail
      ''
      + lib.optionalString (cfg.dnsAddress != null) ''
        incus config set core.dns_address=${lib.escapeShellArg cfg.dnsAddress}
      ''
      + lib.optionalString (cfg.metrics.enable) ''
        incus config set core.metrics_address=${lib.escapeShellArg cfg.metrics.address}
        incus config set core.metrics_authentication=false
      ''
      +
        lib.optionalString
          (cfg.dnsAddress != null && cfg.network.vpn.enable && cfg.network.vpn.dnsZone != null)
          ''
            incus network set ${lib.escapeShellArg cfg.network.vpn.bridge} \
              dns.zone.forward=${lib.escapeShellArg cfg.network.vpn.dnsZone}
          '';
    };
  };
}
