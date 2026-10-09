{
  networking.hostName = "rpi5-8gb";
  system.stateVersion = "26.05";

  local.incus = {
    network = {
      ipv4 = "10.42.0.1/24";
      ipv6 = "fd42:0::1/64";
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
}
