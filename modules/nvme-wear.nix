{ pkgs, ... }:
let
  script = pkgs.writeShellScript "nvme-wear" (builtins.readFile ./scripts/nvme-wear.sh);
in
{
  systemd.tmpfiles.rules = [
    "d /run/node_exporter/textfile 0755 root root -"
  ];

  systemd.services.nvme-wear = {
    description = "Publish NVMe SMART wear metrics for node_exporter";
    path = [
      pkgs.coreutils
      pkgs.jq
      pkgs.smartmontools
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = script;
    };
  };

  systemd.timers.nvme-wear = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1h";
    };
  };
}
