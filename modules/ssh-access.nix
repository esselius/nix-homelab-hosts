{ lib, config, ... }:
{
  options.site = {
    sshPublicKey = lib.mkOption {
      type = lib.types.str;
      default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFMdasDSm/XlOpv15asMENnQ/E9W9rXExBcUAVd/G6Mo";
      description = ''
        Shared SSH public key, authorized for both root and the admin user
        on every host in this flake. Single source of truth so it never
        drifts between host configs.
      '';
    };

    permitRootLogin = lib.mkOption {
      type = lib.types.str;
      default = "no";
      description = ''
        sshd PermitRootLogin setting. Main hosts (rpi5-8gb/rpi5-4gb) keep
        this at "no" - day-to-day access goes through the admin user plus
        passwordless sudo instead. The bootstrap installer overrides this
        to "prohibit-password" (key-only root login), because
        nixos-anywhere hardcodes a requirement for root SSH access on any
        target with system.nixos.variant_id = "installer" (used here to
        skip Raspberry Pi 5's flaky kexec) - there is no flag to override
        this in nixos-anywhere itself. See README "Playbooks" for the full
        explanation and the upstream source excerpt.
      '';
    };
  };

  config = {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = config.site.permitRootLogin;
      };
    };

    security.sudo.wheelNeedsPassword = false;

    # Purely declarative users (impermanence: no /etc/passwd to persist, and no
    # runtime `passwd`/`useradd` that would be lost on the next boot anyway).
    users.mutableUsers = false;

    users.users.root.openssh.authorizedKeys.keys = [ config.site.sshPublicKey ];

    users.users.admin = {
      isNormalUser = true;
      description = "admin";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = [ config.site.sshPublicKey ];
    };
  };
}
