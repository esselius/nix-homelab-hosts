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
}
