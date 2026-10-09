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
                mountOptions = [
                  "noatime"
                  "compress=zstd"
                  "nodiscard"
                ];
              };
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = [
                  "noatime"
                  "compress=zstd"
                  "nodiscard"
                ];
              };
              "@persist" = {
                mountpoint = "/persist";
                mountOptions = [
                  "noatime"
                  "compress=zstd"
                  "nodiscard"
                ];
              };
              "@snapshots" = {
                mountpoint = "/snapshots";
                mountOptions = [
                  "noatime"
                  "compress=zstd"
                  "nodiscard"
                ];
              };
            };
          };
        };
      };
    };
  };
}
