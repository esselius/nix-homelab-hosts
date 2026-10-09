{
  # Describes the SD card's EXISTING partition layout (created once by the
  # rpi5-bootstrap sd-image build, never by this config). This is only ever
  # used with disko in "mount" mode (nixos-anywhere --disko-mode mount, or
  # the default mode for the real nixosConfigurations which never re-run
  # disko's create step): it lets disko (and therefore nixos-anywhere)
  # auto-generate fileSystems."/boot" and fileSystems."/boot/firmware" AND
  # mount them during install, which is what was previously missing and
  # required the manual mount + nixos-enter dance after every
  # nixos-anywhere run (see README "bootloader-install caveat").
  #
  # Must NOT be used with disko's default "disko" mode (destroy+create) or
  # with "format" mode - both would reformat the SD card, destroying the
  # bootstrap/bootloader content that lives there. Only "mount" mode is
  # safe for this disk.
  #
  # Defense in depth: `destroy = false` below additionally excludes this disk
  # from disko's destroy stage (which runs `wipefs --all` on every partition
  # plus the whole disk, and zeroes the MBR boot sector - genuinely
  # destructive, not just a "format if empty" no-op) even if `nixos-anywhere`
  # is ever run without `--disko-mode mount` by mistake. This was a real gap:
  # the documented hard-reset playbook (no `--disko-mode` flag, default mode)
  # would otherwise wipe the SD card too, since default mode destroys *every*
  # disk declared in disko.devices, not just the one being targeted for reuse.
  disko.devices.disk.sd = {
    type = "disk";
    device = "/dev/mmcblk0";
    destroy = false;
    content = {
      type = "table";
      format = "msdos";
      partitions = [
        {
          name = "firmware";
          fs-type = "fat32";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot/firmware";
            mountOptions = [ "nofail" ];
          };
        }
        {
          name = "nixos_boot";
          fs-type = "ext4";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/boot";
            mountOptions = [ "noatime" ];
          };
        }
      ];
    };
  };
}
