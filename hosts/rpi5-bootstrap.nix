{ inputs, pkgs, ... }:
{
  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
    ../modules/raspberry-pi.nix
    ../modules/nix-settings.nix
    ../modules/ssh-access.nix
  ];

  system.nixos.variant_id = "installer";

  networking.hostName = "rpi5-bootstrap";

  # Required by nixos-anywhere for installer-variant targets - see
  # modules/ssh-access.nix for the full explanation.
  site.permitRootLogin = "prohibit-password";

  sdImage.firmwareSize = 256;
  sdImage.rootVolumeLabel = "NIXOS_BOOT";
  sdImage.preBuildCommands = ''
    chmod u+w "$root_fs" || true
    resize2fs "$root_fs" 4G
  '';

  services.getty.autologinUser = "admin";

  # No password: admin is reached via the SSH key (modules/ssh-access.nix)
  # or the console autologin above. This is a throwaway image, reflashed
  # fresh before every use - nothing persists here across reflashes.

  environment.systemPackages = with pkgs; [ vim ];

  # The sd-image module pulls in nixos/modules/profiles/base.nix, which enables
  # ZFS. zfs-kernel needs the kernel's `dev` output, which is not in the binary
  # caches (only out/modules are), so leaving it on forces a full linux-rpi
  # build. The installer only ever mounts btrfs/ext4/ESP, so drop it.
  boot.supportedFilesystems.zfs = false;

  system.stateVersion = "26.05";
}
