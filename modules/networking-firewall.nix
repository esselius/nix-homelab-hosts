{ ... }:
{
  networking.nftables.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];
}
