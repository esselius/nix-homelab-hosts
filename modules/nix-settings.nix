{ ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # "root" is already trusted by default (confirmed via nix eval) - only
  # @wheel is the actual addition here.
  nix.settings.trusted-users = [ "@wheel" ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  time.timeZone = "UTC";
}
