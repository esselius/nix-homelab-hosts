{
  networking.hostName = "rpi5-4gb";
  system.stateVersion = "26.05";

  local.incus = {
    network = {
      ipv4 = "10.42.1.1/24";
      ipv6 = "fd42:1::1/64";
    };
    # 4 GB board: containers only, leave ~1.5 GB for the host + zram.
    guest = {
      memoryMiB = 2560;
      cpuCount = 4;
      vms = false;
    };
    tls = {
      serverName = "rpi5-4gb.x.esselius.dev";
      # Enable once this host's SSH key is an age recipient in .sops.yaml
      # (ssh-keyscan <ip> | ssh-to-age) and secrets/rpi5.yaml is rekeyed:
      # acme.enable = true;
      # Browser-generated client cert from the Incus UI (public material).
      clientCertificates."incus-ui-localho.st" = ./../certs/incus-ui-localho.st.crt;
    };
  };
}
