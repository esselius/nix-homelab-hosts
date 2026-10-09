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
  disko.devices.disk.sd = {
    type = "disk";
    device = "/dev/mmcblk0";
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
