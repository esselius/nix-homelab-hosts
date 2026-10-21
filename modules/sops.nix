{ inputs, ... }:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops = {
    # Every secret in this repo lives in the one encrypted file; individual
    # modules only name their key (see local.wireguard.privateKeySecret etc.).
    defaultSopsFile = ../secrets/rpi5.yaml;
    # Secrets are decrypted at boot with the host's own SSH host key (which
    # this repo already persists under /persist), matching konfig's pattern.
    # The recipient list lives in .sops.yaml at the repo root; each Pi's host
    # key must be added there once (it only exists after first boot).
    useSystemdActivation = true;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };
}
