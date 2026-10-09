{ inputs, config, pkgs, lib, ... }:

let
  sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFMdasDSm/XlOpv15asMENnQ/E9W9rXExBcUAVd/G6Mo";
in
{
  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
    inputs.nixos-hardware.nixosModules.raspberry-pi-5
  ];

  nixpkgs.overlays = [
    (final: prev: {
      makeModulesClosure = x: prev.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.nixos.variant_id = "installer";

  networking.hostName = "rpi5-bootstrap";

  hardware.raspberry-pi.firmware = {
    enable = true;
    uboot.enable = true;
  };

  boot.supportedFilesystems = [ "btrfs" ];

  sdImage.firmwareSize = 256;
  sdImage.rootVolumeLabel = "NIXOS_BOOT";
  sdImage.preBuildCommands = ''
    chmod u+w "$root_fs" || true
    resize2fs "$root_fs" 4G
  '';

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.getty.autologinUser = "admin";

  users.users.admin.initialPassword = "bootstrap";

  security.sudo.wheelNeedsPassword = false;

  users.users.admin = {
    isNormalUser = true;
    description = "admin";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ sshPublicKey ];
  };

  users.users.root.openssh.authorizedKeys.keys = [ sshPublicKey ];

  environment.systemPackages = with pkgs; [ vim ];

  system.stateVersion = "26.05";
}
