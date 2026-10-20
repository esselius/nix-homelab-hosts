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
  config = lib.mkIf (cfg.dnsAddress != null) {
    # The preseed has create-only fields and does not rerun on script changes;
    # apply the DNS settings to the daemon/network idempotently instead.
    systemd.services.incus-dns = {
      description = "Configure Incus built-in DNS and network zone";
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
        incus config set core.dns_address=${lib.escapeShellArg cfg.dnsAddress}
      ''
      + lib.optionalString (cfg.network.vpn.dnsZone != null) ''
        incus network set ${lib.escapeShellArg cfg.network.vpn.bridge} \
          dns.zone.forward=${lib.escapeShellArg cfg.network.vpn.dnsZone}
      '';
    };
  };
}
