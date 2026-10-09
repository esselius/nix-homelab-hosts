{ config, lib, ... }:
let
  cfg = config.local.incus.guest;
  toMiB = n: "${toString n}MiB";

  # `default` carries connectivity + storage only, so every instance gets a
  # NIC and a root disk. Limits live in separate limit-only profiles that are
  # applied alongside it (`incus launch ... -p default -p container`), which
  # is the incus idiom - profiles stack, devices merge by name.
  rootAndNic = {
    eth0 = {
      name = "eth0";
      type = "nic";
      network = config.local.incus.network.bridge;
    };
    root = {
      path = "/";
      pool = "default";
      type = "disk";
    };
  };
in
{
  options.local.incus.guest = {
    memoryMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2048;
      description = "Total RAM budget for guests on this board (host + zram reserve excluded).";
    };
    cpuCount = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
    };
    vms = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Emit the `vm` limits profile. The 4 GB board is containers-only.";
    };
  };

  config.local.incus.spec.profiles = [
    {
      name = "default";
      devices = rootAndNic;
    }
    {
      name = "container";
      description = "Resource limits for containers (apply alongside default)";
      config = {
        "limits.cpu" = toString cfg.cpuCount;
        # Hard enforce: without it a runaway container is a soft hint and can
        # still OOM the host (matters a lot on 4 GB).
        "limits.memory" = toMiB (builtins.div cfg.memoryMiB 2);
        "limits.memory.enforce" = "hard";
      };
    }
  ]
  ++ lib.optionals cfg.vms [
    {
      name = "vm";
      description = "Resource limits for virtual machines (apply alongside default)";
      config = {
        "limits.cpu" = toString cfg.cpuCount;
        "limits.memory" = toMiB (builtins.div (cfg.memoryMiB * 3) 4);
      };
    }
  ];
}
