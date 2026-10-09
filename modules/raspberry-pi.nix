{ inputs, ... }:
{
  # Shared by every Pi 5 host in this flake, including the bootstrap
  # installer: vendor kernel/firmware profile, the overlay it needs, and
  # btrfs support (needed everywhere NVMe gets touched, including from the
  # bootstrap installer during install/mount-dance operations).
  imports = [ inputs.nixos-hardware.nixosModules.raspberry-pi-5 ];

  nixpkgs.overlays = [
    (final: prev: {
      # The vendor linux-rpi kernel doesn't build every module the
      # raspberry-pi-5 profile's initrd wants (e.g. tpm-crb) - without this,
      # the initrd build fails outright on the first missing module instead
      # of just skipping it. Confirmed still required as of this kernel
      # version; not an effect of hardware.enableAllHardware, which is
      # false in this config.
      makeModulesClosure = x: prev.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  hardware.raspberry-pi.firmware = {
    enable = true;
    uboot.enable = true;
  };

  boot.supportedFilesystems = [ "btrfs" ];
}
