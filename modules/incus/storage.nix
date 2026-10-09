{ config, lib, ... }:
let
  cfg = config.local.incus.storage;
in
{
  options.local.incus.storage.source = lib.mkOption {
    type = lib.types.str;
    default = "/persist/incus-pool";
    description = ''
      Leaf directory for the btrfs storage pool. Deliberately NOT
      /persist/var/lib/incus: incusd seeds its own daemon state there before
      the preseed step runs, so that path is never empty when the pool-create
      step fires. No tmpfiles rule pre-creates this path - the btrfs driver
      creates its own subvolume on first preseed run, and a pre-existing plain
      directory at the exact path makes `btrfs subvolume create` fail with
      "File exists".
    '';
  };

  config.local.incus.spec.storagePools = [
    {
      name = "default";
      # btrfs (not dir): this lives on the @persist btrfs filesystem, so incus
      # manages it with native subvolumes - CoW clones for instance creation
      # and efficient native snapshots, instead of plain directory copies.
      driver = "btrfs";
      config.source = cfg.source;
    }
  ];
}
