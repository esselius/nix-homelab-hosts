{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFMdasDSm/XlOpv15asMENnQ/E9W9rXExBcUAVd/G6Mo";
in
{
  imports = [ inputs.nixos-hardware.nixosModules.raspberry-pi-5 ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  hardware.raspberry-pi.firmware = {
    enable = true;
    uboot.enable = true;
  };

  boot.supportedFilesystems = [ "btrfs" ];

  networking.nftables.enable = true;
  networking.firewall.trustedInterfaces = [ "incusbr0" ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/persist" ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  security.sudo.wheelNeedsPassword = false;

  users.groups.incus-admin = { };

  users.users.admin = {
    isNormalUser = true;
    description = "admin";
    extraGroups = [ "wheel" "incus-admin" ];
    openssh.authorizedKeys.keys = [ sshPublicKey ];
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
}
