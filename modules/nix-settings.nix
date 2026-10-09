{ ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
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
