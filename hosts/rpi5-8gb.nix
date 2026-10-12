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
    # Fixed port so adama can dial us as a direct peer (192.168.50.80:51820).
    listenPort = 51820;
    # Direct peer: adama is on the same gigabit LAN, so route its /32 to it
    # directly instead of hairpinning through the ASUS WireGuard server. WireGuard
    # picks the more specific /32 over the router peer's 10.6.0.0/24.
    extraPeers = [
      {
        publicKey = "dWWZ4LE0lK1gRjE5GEGyEkHAbDhXjLsT379K/6Lk7EM=";
        endpoint = "192.168.50.43:51820";
        allowedIPs = [ "10.6.0.5/32" ];
        persistentKeepalive = 25;
      }
    ];
  };

  local.incus = {
    network = {
      ipv4 = "10.42.0.1/24";
      ipv6 = "fd42:0::1/64";
      # Bridge reachable from other WireGuard VPN clients (`-p default -p vpn`).
      # The router must route 10.43.0.0/24 to this host's wg address, and its
      # peer entry must allow it. No eth0 on this board - the wired uplink is
      # end0 (see `ip -br addr`), so the egress masquerade targets it.
      vpn.enable = true;
      vpn.uplink = "end0";
      # coredns instance on the VPN bridge. Only the internal int.esselius.dev
      # zone is resolved through it (split DNS via systemd-resolved); everything
      # else keeps using the normal resolvers.
      vpn.dns = [ "10.43.0.14" ];
      vpn.dnsDomains = [ "~int.esselius.dev" ];
    };
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
