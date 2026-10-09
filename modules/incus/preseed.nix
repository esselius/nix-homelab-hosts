{ config, ... }:
let
  spec = config.local.incus.spec;
in
{
  local.incus.spec.serverConfig = {
    "core.https_address" = ":8443";
    "images.auto_update_interval" = "6";
  };

  # Single assembly point for the freeform preseed value (see default.nix).
  virtualisation.incus.preseed = {
    config = spec.serverConfig;
    networks = spec.networks;
    storage_pools = spec.storagePools;
    profiles = spec.profiles;
    certificates = spec.certificates;
  };
}
