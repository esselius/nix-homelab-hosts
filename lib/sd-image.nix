{
  lib,
  config,
  pkgs,
  inputs,
  ...
}:

with lib;

let
  rootfsImage = pkgs.callPackage config.sdImage.rootFilesystemCreator (
    {
      inherit (config.sdImage) storePaths;
      compressImage = config.sdImage.compressImage;
      populateImageCommands = config.sdImage.populateRootCommands;
      volumeLabel = config.sdImage.rootVolumeLabel;
    }
    // optionalAttrs (config.sdImage.rootPartitionUUID != null) {
      uuid = config.sdImage.rootPartitionUUID;
    }
  );
in
{
  imports = [ "${inputs.nixpkgs}/nixos/modules/image/file-options.nix" ];

  options.sdImage = {
    storePaths = mkOption {
      type = with types; listOf package;
      description = "Derivations to be included in the Nix store in the generated SD image.";
    };

    firmwarePartitionOffset = mkOption {
      type = types.int;
      default = 8;
      description = ''
        Gap in front of the firmware partition, in MiB.
      '';
    };

    firmwarePartitionID = mkOption {
      type = types.str;
      default = "0x2178694e";
      description = ''
        Volume ID for the firmware FAT partition. 32-bit hexadecimal.
      '';
    };

    firmwarePartitionName = mkOption {
      type = types.str;
      default = "FIRMWARE";
      description = "Name of the FAT filesystem holding the boot firmware.";
    };

    firmwareSize = mkOption {
      type = types.int;
      default = 256;
      description = ''
        Size of the firmware (FAT) partition, in megabytes. Covers firmware,
        vendor DTBs, overlays, and room for config.txt growth.
      '';
    };

    rootPartitionUUID = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "UUID for the filesystem on the rescue (ext4) partition (partition 3).";
    };

    rootVolumeLabel = mkOption {
      type = types.str;
      default = "NIXOS_RESCUE";
      description = "Label for the rescue root ext4 volume (partition 3).";
    };

    bootPartitionUUID = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "UUID for the ext4 filesystem on the main /boot partition (partition 2).";
    };

    bootVolumeLabel = mkOption {
      type = types.str;
      default = "NIXOS_BOOT";
      description = "Label for the main /boot ext4 volume (partition 2).";
    };

    bootSize = mkOption {
      type = types.int;
      default = 4096;
      description = ''
        Size of the main /boot partition, in megabytes. Holds extlinux.conf plus
        kernel/initrd copies for main-OS generations installed later via
        nixos-anywhere.
      '';
    };

    rootFilesystemCreator = mkOption {
      type = types.oneOf [
        types.package
        types.path
      ];
      default = inputs.nixpkgs + "/nixos/lib/make-ext4-fs.nix";
      description = "The filesystem creator used for the rescue root partition.";
    };

    rootFilesystemImage = mkOption {
      type = types.package;
      default = rootfsImage;
      description = "The finished rescue root partition image.";
    };

    populateFirmwareCommands = mkOption {
      description = ''
        Shell commands to populate the ./firmware directory. Copied to the
        firmware partition.
      '';
    };

    populateRootCommands = mkOption {
      description = ''
        Shell commands to populate the ./files directory, copied to the rescue
        root partition.
      '';
    };

    populateBootCommands = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Shell commands to populate the ./boot-fs directory, placed into the
        main /boot partition (partition 3) at image build time. Normally left
        empty: the main OS owns this partition and populates it at install
        time via nixos-anywhere.
      '';
    };

    preBuildCommands = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Commands between root filesystem preparation and image assembly.
        The root filesystem image path is available in `root_fs`.
      '';
    };

    postBuildCommands = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Shell commands to run after the SD image has been assembled. The image
        path is available in `img`.
      '';
    };

    compressImage = mkOption {
      type = types.bool;
      default = true;
      description = "Whether the SD image should be compressed using zstd.";
    };

    nixPathRegistrationFile = mkOption {
      type = types.str;
      default = "/nix-path-registration";
      description = ''
        Location of the file containing the input for nix-store --load-db once
        booted.
      '';
    };
  };

  config = {
    hardware.enableAllHardware = true;

    fileSystems = {
      "/boot/firmware" = {
        device = "/dev/disk/by-label/${config.sdImage.firmwarePartitionName}";
        fsType = "vfat";
        options = [
          "nofail"
          "noauto"
        ];
      };
      "/" = {
        device = "/dev/disk/by-label/${config.sdImage.rootVolumeLabel}";
        fsType = "ext4";
      };
    };

    sdImage.storePaths = [ config.system.build.toplevel ];    image.extension = if config.sdImage.compressImage then "img.zst" else "img";
    image.filePath = "sd-image/${config.image.fileName}";
    system.build.image = config.system.build.sdImage;
    system.build.sdImage = pkgs.callPackage (
      {
        stdenv,
        dosfstools,
        e2fsprogs,
        mtools,
        libfaketime,
        util-linux,
        zstd,
      }:
      stdenv.mkDerivation {
        name = config.image.fileName;

        nativeBuildInputs = [
          dosfstools
          e2fsprogs
          mtools
          libfaketime
          util-linux
        ]
        ++ optional config.sdImage.compressImage zstd;

        inherit (config.sdImage) compressImage;

        buildCommand = ''
          mkdir -p $out/nix-support $out/sd-image
          export img=$out/sd-image/${config.image.baseName}.img

          echo "${pkgs.stdenv.buildPlatform.system}" > $out/nix-support/system
          if test -n "$compressImage"; then
            echo "file sd-image $img.zst" >> $out/nix-support/hydra-build-products
          else
            echo "file sd-image $img" >> $out/nix-support/hydra-build-products
          fi

          root_fs=${config.sdImage.rootFilesystemImage}
          ${optionalString config.sdImage.compressImage ''
            root_fs=./root-fs.img
            echo "Decompressing rootfs image"
            zstd -d --no-progress "${config.sdImage.rootFilesystemImage}" -o $root_fs
          ''}

          ${config.sdImage.preBuildCommands}

          gapSectors=$(( ${toString config.sdImage.firmwarePartitionOffset} * 2048 ))
          fwSectors=$(( ${toString config.sdImage.firmwareSize} * 2048 ))
          bootSectors=$(( ${toString config.sdImage.bootSize} * 2048 ))
          rootSizeBlocks=$(du -B 512 --apparent-size $root_fs | awk '{ print $1 }')
          rootAlignedBlocks=$(( (rootSizeBlocks + 2047) / 2048 * 2048 ))
          bootAlignedBlocks=$(( ${toString config.sdImage.bootSize} * 2048 ))
          p2Start=$(( gapSectors + fwSectors ))
          p3Start=$(( p2Start + bootAlignedBlocks ))
          imageSizeBlocks=$(( p3Start + rootAlignedBlocks + 2048 ))
          truncate -s $(( imageSizeBlocks * 512 )) $img

          sfdisk --no-reread --no-tell-kernel $img <<EOF
              label: dos
              label-id: ${config.sdImage.firmwarePartitionID}

              start=''${gapSectors}, size=''${fwSectors}, type=b
              start=''${p2Start}, size=''${bootAlignedBlocks}, type=83, bootable
              start=''${p3Start}, size=''${rootAlignedBlocks}, type=83, bootable
          EOF

          eval $(partx $img -o START,SECTORS --nr 3 --pairs)
          dd conv=notrunc if=$root_fs of=$img seek=$START count=$SECTORS

          eval $(partx $img -o START,SECTORS --nr 1 --pairs)
          truncate -s $(( SECTORS * 512 )) firmware_part.img
          mkfs.vfat --invariant -i ${config.sdImage.firmwarePartitionID} -n ${config.sdImage.firmwarePartitionName} firmware_part.img

          mkdir firmware
          ${config.sdImage.populateFirmwareCommands}

          find firmware -exec touch --date=2000-01-01 {} +
          cd firmware
          for d in $(find . -type d -mindepth 1 | sort); do
            faketime "2000-01-01 00:00:00" mmd -i ../firmware_part.img "::/$d"
          done
          for f in $(find . -type f | sort); do
            mcopy -pvm -i ../firmware_part.img "$f" "::/$f"
          done
          cd ..
          fsck.vfat -vn firmware_part.img
          dd conv=notrunc if=firmware_part.img of=$img seek=$START count=$SECTORS

          eval $(partx $img -o START,SECTORS --nr 2 --pairs)
          truncate -s $(( SECTORS * 512 )) boot_part.img
          mkdir boot-fs
          ${config.sdImage.populateBootCommands}
          find boot-fs -exec touch --date=2000-01-01 {} +
          mke2fs -F -q \
            ${optionalString (config.sdImage.bootPartitionUUID != null) "-U ${config.sdImage.bootPartitionUUID}"} \
            -L ${config.sdImage.bootVolumeLabel} \
            -d boot-fs boot_part.img
          fsck.ext4 -fn boot_part.img
          dd conv=notrunc if=boot_part.img of=$img seek=$START count=$SECTORS

          ${config.sdImage.postBuildCommands}

          if test -n "$compressImage"; then
              zstd -T$NIX_BUILD_CORES --rm $img
          fi
        '';
      }
    ) { };

    systemd.services.register-nix-paths =
      let
        inherit (config.sdImage) nixPathRegistrationFile;
      in
      {
        description = "Register Nix Store Paths";
        unitConfig = {
          DefaultDependencies = false;
          ConditionPathExists = nixPathRegistrationFile;
        };
        wantedBy = [ "sysinit.target" ];
        before = [
          "sysinit.target"
          "shutdown.target"
          "nix-daemon.socket"
          "nix-daemon.service"
        ];
        after = [ "local-fs.target" ];
        conflicts = [ "shutdown.target" ];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${lib.getExe' config.nix.package.out "nix-store"} --load-db < ${nixPathRegistrationFile}
          touch /etc/NIXOS
          ${lib.getExe' config.nix.package.out "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system
          rm -f ${nixPathRegistrationFile}
        '';
      };
  };
}
