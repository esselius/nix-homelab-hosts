{ pkgs, lib, ... }:
let
  helpers = import ./lib.nix { inherit lib; };
  script = pkgs.writeShellScript "zram-metrics" (builtins.readFile ./scripts/zram-metrics.sh);
in
{
  imports = [
    (helpers.mkTextfileCollector {
      name = "zram-metrics";
      description = "Publish zram statistics for node_exporter";
      inherit script;
      onBootSec = "15s";
      interval = "30s";
      path = [ pkgs.coreutils ];
    })
  ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };
}
