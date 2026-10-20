{ pkgs, lib, ... }:
{
  # Incus is split across modules/incus/*. Each concern contributes to
  # local.incus.spec (internal, see below); preseed.nix is the single place
  # that assembles virtualisation.incus.preseed from it. Keeping the assembly
  # in one spot avoids depending on how the freeform preseed submodule merges
  # list attributes defined across separate modules.
  imports = [
    ./network.nix
    ./storage.nix
    ./profiles.nix
    ./tls.nix
    ./dns.nix
    ./preseed.nix
  ];

  # Internal interface between the incus submodules. Not for host config -
  # hosts tune the higher-level local.incus.{network,guest,tls} options.
  options.local.incus.spec = {
    serverConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      internal = true;
    };
    networks = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      internal = true;
    };
    storagePools = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      internal = true;
    };
    profiles = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      internal = true;
    };
  };

  config = {
    virtualisation.incus = {
      enable = true;
      ui.enable = true;
      package = pkgs.incus-lts;
    };

    users.groups.incus-admin = { };
    users.users.admin.extraGroups = [ "incus-admin" ];
  };
}
