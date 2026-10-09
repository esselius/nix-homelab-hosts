{ inputs, config, pkgs, lib, ... }:

{
  imports = [
    ../lib/sd-image.nix
    inputs.nixos-hardware.nixosModules.raspberry-pi-5
  ];

  nixpkgs.overlays = [
    (final: prev: {
      makeModulesClosure = x: prev.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  sdImage.populateRootCommands = "${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot";

  system.nixos.variant_id = "installer";

  networking.hostName = "rpi5-rescue";

  hardware.raspberry-pi.firmware = {
    enable = true;
    uboot.enable = true;
  };

  boot.supportedFilesystems = [ "btrfs" ];

  services.journald.settings.Journal.Storage = "persistent";

  systemd.services.boot-diagnostics = {
    description = "Write boot diagnostics to the firmware FAT for offline pickup";
    path = with pkgs; [
      coreutils
      util-linux
      iproute2
      systemd
    ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      target=/boot/firmware
      mountpoint -q "$target" || mount "$target" || exit 0
      {
        uname -a
        uptime
        echo
        echo "model: $(cat /proc/device-tree/model 2>/dev/null)"
        echo
        echo "== dmesg =="
        dmesg
        echo
        echo "== block devices =="
        lsblk -f
        echo
        echo "== network =="
        ip -br addr
        ip route
        echo
        echo "== failed units =="
        systemctl --failed --no-pager || true
      } > "$target/diag.txt" 2>&1
      chmod 666 "$target/diag.txt"
    '';
  };

  systemd.timers.boot-diagnostics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5s";
      OnUnitActiveSec = "10s";
      AccuracySec = "1s";
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.getty.autologinUser = "admin";

  users.users.admin.initialPassword = "rescue";

  security.sudo.wheelNeedsPassword = false;

  users.users.admin = {
    isNormalUser = true;
    description = "admin";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFMdasDSm/XlOpv15asMENnQ/E9W9rXExBcUAVd/G6Mo" ];
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFMdasDSm/XlOpv15asMENnQ/E9W9rXExBcUAVd/G6Mo"
  ];

  environment.systemPackages = with pkgs; [ vim ];

  system.stateVersion = "26.05";
}
