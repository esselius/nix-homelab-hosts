{ pkgs, ... }:
let
  script = pkgs.writeShellScript "cgroup-memory-metrics" (
    builtins.readFile ./scripts/cgroup-memory-metrics.sh
  );
in
{
  systemd.tmpfiles.rules = [
    "d /run/node_exporter/textfile 0755 root root -"
  ];

  systemd.services.cgroup-memory-metrics = {
    description = "Publish per-container cgroup memory statistics for node_exporter";
    path = [
      pkgs.coreutils
      pkgs.gawk
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = script;
    };
  };

  systemd.timers.cgroup-memory-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "20s";
      OnUnitActiveSec = "30s";
    };
  };
}
