{ ... }:
{
  services.fstrim.enable = true;

  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/persist" ];
  };

  services.snapper.configs."persist" = {
    SUBVOLUME = "/persist";
    TIMELINE_CREATE = true;
    TIMELINE_CLEANUP = true;
    TIMELINE_LIMIT_HOURLY = "8";
    TIMELINE_LIMIT_DAILY = "7";
    TIMELINE_LIMIT_MONTHLY = "3";
  };
}
