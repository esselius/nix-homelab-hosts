{ inputs, ... }:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops = {
    # No default file: every module names its own `sopsFile`, so a host only
    # gets the material it needs (per-host WireGuard key, shared ACME creds).
    # The recipient rules live in .sops.yaml; hosts set their per-host file via
    # local.wireguard.sopsFile.
    # Secrets are decrypted at boot with the host's own SSH host key (which
    # this repo already persists under /persist), matching konfig's pattern.
    # The recipient list lives in .sops.yaml at the repo root; each Pi's host
    # key must be added there once (it only exists after first boot).
    useSystemdActivation = true;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };
}
