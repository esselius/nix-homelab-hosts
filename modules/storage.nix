{ ... }:
{
  # Project-specific state only. The generic Pi 5/NVMe boot and storage layer
  # (root wipe, fstrim, auto-scrub, snapper, machine-id/SSH host keys,
  # /var/lib/nixos, /var/log) comes from pi5.impermanence via
  # pi5.nixosModules.default.
  pi5.impermanence.extraDirectories = [
    "/var/lib/incus"
    "/var/lib/unbound"
  ];
}
