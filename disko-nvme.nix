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
              "@root" = {
                mountpoint = "/";
                mountOptions = [ "subvol=@root" "noatime" "compress=zstd" ];
              };
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = [ "subvol=@nix" "noatime" "compress=zstd" ];
              };
              "@persist" = {
                mountpoint = "/persist";
                mountOptions = [ "subvol=@persist" "noatime" "compress=zstd" ];
              };
              "@snapshots" = {
                mountpoint = "/snapshots";
                mountOptions = [ "subvol=@snapshots" "noatime" "compress=zstd" ];
              };
            };
          };
        };
      };
    };
  };
}
