{ config, ... }:
{
  networking.hostName = "rpi5-8gb";
  system.stateVersion = "26.05";

  local.wireguard = {
    enable = true;
    # Per-host secret file; only this Pi's key is in it.
    sopsFile = ../secrets/rpi5-8gb.yaml;
    # Split-tunnel node on the router's WireGuard server (not a full-tunnel
    # client): only the VPN subnet is routed via wg0.
    address = "10.6.0.3/32";
    # Fixed port so rpi5-4gb can dial us as a direct peer (192.168.50.80:51820).
    listenPort = 51820;
    # Direct peer: rpi5-4gb is on the same gigabit LAN, so route its /32 (and
    # its instance subnets) directly instead of hairpinning through the router.
    # WireGuard picks the more specific /32 over the router peer's 10.6.0.0/24.
    extraPeers = [
      {
        publicKey = "9MuNcL6y5nT0F2EQSI42mJ01BTEnhSRpc5sPZyKBEFU=";
        endpoint = "192.168.50.33:51821";
        allowedIPs = [
          "10.6.0.5/32"
          "10.42.1.0/24"
          "10.43.1.0/24"
        ];
        persistentKeepalive = 25;
      }
    ];
  };

  # Host-level resolver for VPN clients. It lives on wg0, not on the Incus
  # bridge, so DNS keeps working when Incus or incusbr-vpn is down. This host
  # is the authoritative secondary for the zone, transferred from Incus's
  # built-in DNS on loopback (AXFR only).
  local.dns = {
    enable = true;
    incusPrimary = "127.0.0.1@1053";
  };

  local.incus = {
    dnsAddress = "127.0.0.1:1053";
    network.vpn = {
      enable = true;
      # Bridge reachable from other WireGuard VPN clients (`-p default -p vpn`).
      # The router must route 10.43.0.0/24 to this host's wg address, and its
      # peer entry must allow it. The wired uplink is end0 (no eth0 on this
      # board), so the egress masquerade targets it.
      dnsZone = config.local.site.zone;
    };
    # 8 GB board: leave ~2 GB for the host + zram.
    guest = {
      memoryMiB = 6144;
      cpuCount = 4;
      vms = true;
    };
  };
}
