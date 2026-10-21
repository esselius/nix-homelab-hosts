{ pkgs, lib, ... }:
let
  helpers = import ./lib.nix { inherit lib; };
  script = pkgs.writeShellScript "cgroup-memory-metrics" (
    builtins.readFile ./scripts/cgroup-memory-metrics.sh
  );
in
{
  imports = [
    (helpers.mkTextfileCollector {
      name = "cgroup-memory-metrics";
      description = "Publish per-container cgroup memory statistics for node_exporter";
      inherit script;
      onBootSec = "20s";
      interval = "30s";
      path = [
        pkgs.coreutils
        pkgs.gawk
      ];
    })
  ];
}
