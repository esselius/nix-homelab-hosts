{
  networking.hostName = "rpi5-4gb";
  system.stateVersion = "26.05";

  local.wireguard = {
    enable = true;
    # Split-tunnel node on the router's WireGuard server, same shape as
    # rpi5-8gb. The router needs a peer for this key (see README).
    address = "10.6.0.5/32";
    privateKeySecret = "wg_private_key_4gb";
    serverPublicKey = "b+Xgh4RNJl20tlnb41DQDIda+jSgP0xfuSpW/NEJGXE=";
    serverEndpoint = "195.58.123.102";
    serverPort = 51820;
    vpnSubnet = "10.6.0.0/24";
    # Fixed port so rpi5-8gb can dial us as a direct peer over the LAN.
    listenPort = 51821;
    extraPeers = [
      {
        # rpi5-8gb. Its /32 and the two instance subnets are more specific than
        # the router peer's 10.6.0.0/24, so DNS forwarding, monitoring, and
        # cross-host instance traffic take the direct LAN path instead of
        # hairpinning through the router.
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

  # Host resolver for VPN clients. The zone itself lives on rpi5-8gb (Incus
  # built-in DNS + its Unbound secondary), so this resolver forwards
  # int.esselius.dev there over the direct peer and keeps the bootstrap names
  # local. The host itself routes only ~int.esselius.dev through it.
  local.dns = {
    enable = true;
    listenAddresses = [
      "127.0.0.1"
      "10.6.0.5"
    ];
    coredns = "10.6.0.3";
    bootstrap = {
      cache = "10.43.0.20";
      monitoring = "10.43.0.12";
    };
    srv = {
      "_mqtt._tcp" = "0 0 1883 mosquitto.int.esselius.dev.";
    };
  };

  local.incus = {
    network = {
      ipv4 = "10.42.1.1/24";
      ipv6 = "fd42:1::1/64";
      # Source-preserving bridge for instances reachable across hosts/VPN,
      # mirroring rpi5-8gb. 10.43.1.0/24 keeps it distinct from 8gb's 10.43.0.0/24.
      vpn = {
        enable = true;
        ipv4 = "10.43.1.1/24";
        subnet = "10.43.1.0/24";
        uplink = "end0";
      };
    };
    # Expose Incus's /1.0/metrics on loopback for the Alloy agent to scrape.
    metrics.enable = true;
    # 4 GB board: containers only, leave ~1.5 GB for the host + zram.
    guest = {
      memoryMiB = 2560;
      cpuCount = 4;
      vms = false;
    };
    tls = {
      serverName = "rpi5-4gb.x.esselius.dev";
      acme.enable = true;
      # Browser-generated client cert from the Incus UI (public material).
      clientCertificates."incus-ui-localho.st" = ./../certs/incus-ui-localho.st.crt;
    };
  };

  # Ship node metrics + journal to the monitoring workload, over the direct
  # peer to rpi5-8gb's VPN bridge.
  local.monitoringAgent.enable = true;
}
