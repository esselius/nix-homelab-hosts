{
  networking.hostName = "rpi5-4gb";
  system.stateVersion = "26.05";

  local.wireguard = {
    enable = true;
    # Per-host secret file; only this Pi's key is in it.
    sopsFile = ../secrets/rpi5-4gb.yaml;
    # Split-tunnel node on the router's WireGuard server, same shape as
    # rpi5-8gb. The router needs a peer for this key (see README).
    address = "10.6.0.5/32";
    privateKeySecret = "wg_private_key_4gb";
    # Fixed port so rpi5-8gb can dial us as a direct peer over the LAN.
    listenPort = 51821;
    # rpi5-8gb's /32 and its instance subnets are more specific than the router
    # peer's 10.6.0.0/24, so DNS forwarding, monitoring, and cross-host instance
    # traffic take the direct LAN path instead of hairpinning through the router.
    extraPeers = [
      {
        publicKey = "NmlbH35CycjE1thGKwfU4pbYDCevMg+ui+jr9PiK9UM=";
        endpoint = "192.168.50.80:51820";
        allowedIPs = [
          "10.6.0.3/32"
          "10.42.0.0/24"
          "10.43.0.0/24"
        ];
        persistentKeepalive = 25;
      }
    ];
  };

  # The zone itself lives on rpi5-8gb, so this resolver forwards
  # int.esselius.dev there over the direct peer and keeps the bootstrap names
  # local. The host itself routes only ~int.esselius.dev through it.
  local.dns = {
    enable = true;
    coredns = "10.6.0.3";
  };

  local.incus = {
    network = {
      ipv4 = "10.42.1.1/24";
      ipv6 = "fd42:1::1/64";
      # Source-preserving bridge for instances reachable across hosts/VPN,
      # mirroring rpi5-8gb. 10.43.1.0/24 keeps it distinct from 8gb's.
      vpn = {
        enable = true;
        ipv4 = "10.43.1.1/24";
      };
    };
    # 4 GB board: containers only, leave ~1.5 GB for the host + zram.
    guest = {
      memoryMiB = 2560;
      cpuCount = 4;
      vms = false;
    };
  };
}
