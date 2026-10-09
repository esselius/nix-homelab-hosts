{ ... }:
{
  # Impermanence: root (@root) is reset to a pristine empty btrfs subvolume
  # on every boot (below), and only the paths listed in
  # environment.persistence."/persist" actually survive a reboot.

  fileSystems."/".neededForBoot = true;
  fileSystems."/persist".neededForBoot = true;

  boot.initrd.systemd.services.root-wipe = {
    description = "Reset @root btrfs subvolume to a pristine empty state";
    wantedBy = [ "sysroot.mount" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    # Required: without this, systemd started this service TWICE per boot,
    # and two near-simultaneous mount + btrfs-subvolume delete/create passes
    # against the same device during fragile early-initrd timing reliably
    # hung the whole boot with zero further console output. See README
    # "Root-wipe mechanics" for the full investigation.
    serviceConfig.RemainAfterExit = true;
    serviceConfig.TimeoutStartSec = "30s";
    script = ''
      set -x
      for i in $(seq 1 200); do
        [ -e /dev/disk/by-partlabel/NVME_ROOT ] && break
        sleep 0.05
      done
      udevadm settle --timeout=10 || true
      mkdir -p /btrfs_tmp
      mount -o nodiscard /dev/disk/by-partlabel/NVME_ROOT /btrfs_tmp
      if [ -e /btrfs_tmp/@root ]; then
        btrfs property set /btrfs_tmp/@root ro false 2>/dev/null || true
        # Deletes nested subvolumes systemd creates under / before deleting
        # @root itself; POSIX `while read`, no awk/arrays/process
        # substitution (none reliable in initrd). See README "Root-wipe
        # mechanics" for why.
        btrfs subvolume list -o /btrfs_tmp/@root > /btrfs_tmp/children.txt
        while read -r line; do
          sv="''${line##* }"
          btrfs property set "/btrfs_tmp/$sv" ro false 2>/dev/null || true
          btrfs subvolume delete "/btrfs_tmp/$sv"
        done < /btrfs_tmp/children.txt
        btrfs subvolume delete /btrfs_tmp/@root
      fi
      btrfs subvolume create /btrfs_tmp/@root
      umount /btrfs_tmp
      rmdir /btrfs_tmp
    '';
  };

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"
      "/etc/nix"
      "/var/lib/nixos"
      "/var/lib/incus"
      "/var/log"
      "/root"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
    users.admin = {
      directories = [ ];
    };
  };

  services.fstrim.enable = true;

  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/persist" ];
  };

  services.snapper.configs."persist" = {
    SUBVOLUME = "/persist";
    TIMELINE_CREATE = true;
    TIMELINE_CLEANUP = true;
    TIMELINE_LIMIT_HOURLY = "8";
    TIMELINE_LIMIT_DAILY = "7";
    TIMELINE_LIMIT_MONTHLY = "3";
  };
}
