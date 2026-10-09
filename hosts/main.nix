{
  inputs,
  lib,
  pkgs,
  ...
}:

{
  fileSystems."/".neededForBoot = true;
  fileSystems."/persist".neededForBoot = true;

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXOS_BOOT";
    fsType = "ext4";
    options = [ "noatime" ];
    neededForBoot = true;
  };

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "nofail" ];
    neededForBoot = true;
  };

  boot.initrd.systemd.services.root-wipe = {
    description = "Reset @root btrfs subvolume to a pristine empty state";
    wantedBy = [ "sysroot.mount" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    script = ''
      for i in $(seq 1 200); do
        [ -e /dev/disk/by-partlabel/NVME_ROOT ] && break
        sleep 0.05
      done
      mkdir -p /btrfs_tmp
      mount /dev/disk/by-partlabel/NVME_ROOT /btrfs_tmp
      if [ -e /btrfs_tmp/@root ]; then
        btrfs property set /btrfs_tmp/@root ro false 2>/dev/null || true
        btrfs subvolume delete /btrfs_tmp/@root
      fi
      btrfs subvolume create /btrfs_tmp/@root
      umount /btrfs_tmp
      rmdir /btrfs_tmp
    '';
  };

  services.snapper = {
    configs."persist" = {
      SUBVOLUME = "/persist";
      TIMELINE_CREATE = true;
      TIMELINE_CLEANUP = true;
      TIMELINE_LIMIT_HOURLY = "8";
      TIMELINE_LIMIT_DAILY = "7";
      TIMELINE_LIMIT_MONTHLY = "3";
    };
  };

  systemd.tmpfiles.rules = [ "d /persist/incus-pool 0755 root root -" ];

  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    package = pkgs.incus-lts;
    preseed = {
      config = {
        "core.https_address" = ":8443";
        "images.auto_update_interval" = "6";
      };
      networks = [
        {
          name = "incusbr0";
          type = "bridge";
          config = {
            "ipv4.address" = "auto";
            "ipv4.nat" = "true";
            "ipv6.address" = "auto";
            "ipv6.nat" = "true";
          };
        }
      ];
      storage_pools = [
        {
          name = "default";
          driver = "dir";
          config = {
            source = "/persist/incus-pool";
          };
        }
      ];
      profiles = [
        {
          name = "default";
          devices = {
            eth0 = {
              name = "eth0";
              type = "nic";
              network = "incusbr0";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
        }
      ];
    };
  };

  system.stateVersion = "26.05";
}
