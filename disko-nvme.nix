let
  # Shared by every subvolume: no access-time updates, transparent zstd
  # compression, and no online discard (fstrim handles the NVMe instead).
  mountOptions = [
    "noatime"
    "compress=zstd"
    "nodiscard"
  ];

  subvolume = mountpoint: { inherit mountpoint mountOptions; };
in
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/nvme0n1";
      content = {
        type = "gpt";
        partitions.nvme = {
          type = "8300";
          size = "100%";
          label = "NVME_ROOT";
          attributes = [ 2 ];
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = {
              "@root" = subvolume "/";
              "@nix" = subvolume "/nix";
              "@persist" = subvolume "/persist";
              "@snapshots" = subvolume "/snapshots";
            };
          };
        };
      };
    };
  };
}
