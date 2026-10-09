{ pkgs, ... }:
{
  # Incus asserts on this directly: "Incus on NixOS is unsupported using
  # iptables. Set networking.nftables.enable = true;" (confirmed via a
  # real build failure with this unset).
  networking.nftables.enable = true;

  # Trusted so incus container/VM traffic isn't dropped by the NixOS
  # firewall, and the API port for the UI/remote clients. (Port 22 doesn't
  # need declaring - services.openssh opens its own port by default.)
  networking.firewall.trustedInterfaces = [ "incusbr0" ];
  networking.firewall.allowedTCPPorts = [ 8443 ];

  users.groups.incus-admin = { };
  users.users.admin.extraGroups = [ "incus-admin" ];

  # incusd seeds its own daemon state directly under /persist/var/lib/incus
  # before the preseed step runs, so that path is never empty when the
  # pool-create step fires - the dir storage pool needs its own separate
  # leaf. preseed doesn't create this directory itself.
  systemd.tmpfiles.rules = [ "d /persist/incus-pool 0755 root root -" ];

  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    package = pkgs.incus-lts;
    preseed = {
      config = {
        "core.https_address" = ":8443";
        "images.auto_update_interval" = "6";
      };
      networks = [
        {
          name = "incusbr0";
          type = "bridge";
          config = {
            "ipv4.address" = "auto";
            "ipv4.nat" = "true";
            "ipv6.address" = "auto";
            "ipv6.nat" = "true";
          };
        }
      ];
      storage_pools = [
        {
          name = "default";
          driver = "dir";
          config = {
            source = "/persist/incus-pool";
          };
        }
      ];
      profiles = [
        {
          name = "default";
          devices = {
            eth0 = {
              name = "eth0";
              type = "nic";
              network = "incusbr0";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
        }
      ];
    };
  };
}
