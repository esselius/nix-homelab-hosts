{ pkgs, lib, ... }:
let
  helpers = import ./lib.nix { inherit lib; };
  script = pkgs.writeShellScript "nvme-wear" (builtins.readFile ./scripts/nvme-wear.sh);
in
{
  imports = [
    (helpers.mkTextfileCollector {
      name = "nvme-wear";
      description = "Publish NVMe SMART wear metrics for node_exporter";
      inherit script;
      onBootSec = "2min";
      interval = "1h";
      path = [
        pkgs.coreutils
        pkgs.jq
        pkgs.smartmontools
      ];
    })
  ];
}
