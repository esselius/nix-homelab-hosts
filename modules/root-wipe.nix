{ ... }:
{
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
        # systemd auto-creates nested subvolumes under / on first boot
        # (srv, var/lib/portables, var/lib/machines, tmp, var/tmp) - a
        # plain `btrfs subvolume delete @root` fails with "Directory not
        # empty" because of these; they must be deleted first. Initrd has
        # no awk and its shell doesn't reliably support bash array syntax
        # or process substitution - a version using either hung the whole
        # boot rather than failing cleanly, so this is a POSIX `while read`
        # loop against a temp file instead.
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
}
