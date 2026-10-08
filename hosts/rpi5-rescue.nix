{ inputs, config, pkgs, ... }:

{
  imports = [
    ../lib/sd-image.nix
    inputs.nixos-hardware.nixosModules.raspberry-pi-5
  ];

  sdImage.populateRootCommands = "${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot";

  system.nixos.variant_id = "installer";

  networking.hostName = "rpi5-rescue";

  boot.kernelPackages = pkgs.linuxPackages_latest;

  hardware.raspberry-pi.firmware = {
    enable = true;
    uboot.enable = true;
  };

  boot.supportedFilesystems = [ "btrfs" ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  security.sudo.wheelNeedsPassword = false;

  users.users.admin = {
    isNormalUser = true;
    description = "admin";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFMdasDSm/XlOpv15asMENnQ/E9W9rXExBcUAVd/G6Mo" ];
  };

  environment.systemPackages = with pkgs; [ vim ];

  system.stateVersion = "26.05";
}
