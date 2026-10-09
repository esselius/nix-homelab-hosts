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
    # Deliberately NOT persisted: /etc/nixos and /etc/nix (declarative NixOS
    # state - a flake checkout doesn't belong in /etc/nixos, and /etc/nix only
    # holds symlinks into /etc/static), and /root (root's home stays ephemeral).
    directories = [
      "/var/lib/nixos"
      "/var/lib/incus"
      "/var/log"
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

  # snapper stores snapshots in <SUBVOLUME>/.snapshots, and that path has to be
  # a subvolume (otherwise snapshots nest inside @persist and recurse); the
  # nixpkgs snapper module writes the config but never creates it, so on a
  # fresh install snapper-timeline fails ("open failed path:/persist/.snapshots").
  # Reuse the dedicated @snapshots subvolume (mounted at /snapshots) by
  # bind-mounting it at /persist/.snapshots: the tool's required path becomes
  # the dedicated subvolume, and /snapshots keeps its clean top-level path.
  fileSystems."/persist/.snapshots" = {
    device = "/snapshots";
    fsType = "none";
    options = [
      "bind"
      "x-systemd.requires-mounts-for=/persist"
      "x-systemd.requires-mounts-for=/snapshots"
    ];
  };
}
