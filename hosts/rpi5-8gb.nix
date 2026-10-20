{
  networking.hostName = "rpi5-8gb";
  system.stateVersion = "26.05";

  local.wireguard = {
    enable = true;
    # Split-tunnel node on the router's WireGuard server (not a full-tunnel
    # client): only the VPN subnet is routed via wg0.
    address = "10.6.0.3/32";
    serverPublicKey = "b+Xgh4RNJl20tlnb41DQDIda+jSgP0xfuSpW/NEJGXE=";
    serverEndpoint = "195.58.123.102";
    serverPort = 51820;
    vpnSubnet = "10.6.0.0/24";
    # Fixed port so rpi5-4gb can dial us as a direct peer (192.168.50.80:51820).
    listenPort = 51820;
    # Direct peer: rpi5-4gb is on the same gigabit LAN, so route its /32 to it
    # directly instead of hairpinning through the ASUS WireGuard server. WireGuard
    # picks the more specific /32 over the router peer's 10.6.0.0/24.
    extraPeers = [
      {
        # rpi5-4gb (formerly the "adama" profile); it dials us back on 51821,
        # so DNS forwarding, monitoring, and cross-host instance traffic stay
        # on the LAN instead of hairpinning through the router.
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
  # bridge, so DNS keeps working when Incus or incusbr-vpn is down. The host
  # itself only routes int.esselius.dev through it (see modules/dns.nix).
  local.dns = {
    enable = true;
    listenAddresses = [
      "127.0.0.1"
      "10.6.0.3"
    ];
    incusPrimary = "127.0.0.1@1053";
    bootstrap = {
      cache = "10.43.0.20";
      monitoring = "10.43.0.12";
    };
    srv = {
      "_mqtt._tcp" = "0 0 1883 mosquitto.int.esselius.dev.";
    };
  };

  local.incus = {
    # Incus's built-in DNS serves the network zone over AXFR only; Unbound
    # consumes it on loopback. No dependency on the bridge's :53 listener.
    dnsAddress = "127.0.0.1:1053";
    network = {
      ipv4 = "10.42.0.1/24";
      ipv6 = "fd42:0::1/64";
      # Bridge reachable from other WireGuard VPN clients (`-p default -p vpn`).
      # The router must route 10.43.0.0/24 to this host's wg address, and its
      # peer entry must allow it. No eth0 on this board - the wired uplink is
      # end0 (see `ip -br addr`), so the egress masquerade targets it.
      vpn.enable = true;
      vpn.uplink = "end0";
      vpn.dnsZone = "int.esselius.dev";
    };
    # Expose Incus's /1.0/metrics on loopback for the Alloy agent to scrape.
    metrics.enable = true;
    # 8 GB board: leave ~2 GB for the host + zram.
    guest = {
      memoryMiB = 6144;
      cpuCount = 4;
      vms = true;
    };
    tls = {
      serverName = "rpi5-8gb.x.esselius.dev";
      acme.enable = true;
      # Browser-generated client cert from the Incus UI (public material).
      clientCertificates."incus-ui-localho.st" = ./../certs/incus-ui-localho.st.crt;
    };
  };

  # Ship node metrics + journal to the monitoring workload (VictoriaMetrics/Loki
  # on the VPN bridge), resolved via the int.esselius.dev split DNS above.
  local.monitoringAgent.enable = true;
}
