{
  description = "NixOS Raspberry Pi 5 incus VM hosts, impermanence on NVMe, SD boot + rescue";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence = {
      url = "github:nix-community/impermanence";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      disko,
      impermanence,
    }@inputs:
    let
      mkHost =
        name: extraModules:
        nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit inputs; };
          modules = extraModules;
        };

      mainHostModules = [
        ./hosts/pi5-common.nix
        ./disko-nvme.nix
        disko.nixosModules.disko
        impermanence.nixosModules.impermanence
      ];
    in
    {
      nixosConfigurations = {
        "rpi5-8gb" = mkHost "rpi5-8gb" (
          mainHostModules ++ [ { imports = [ ./hosts/rpi5-8gb.nix ]; } ]
        );
        "rpi5-4gb" = mkHost "rpi5-4gb" (
          mainHostModules ++ [ { imports = [ ./hosts/rpi5-4gb.nix ]; } ]
        );
        "rpi5-rescue" = mkHost "rpi5-rescue" (
          [ { imports = [ ./hosts/rpi5-rescue.nix ]; } ]
        );
      };

      images.rpi5-bootstrap = self.nixosConfigurations."rpi5-rescue".config.system.build.sdImage;

      devShells.x86_64-darwin.default = nixpkgs.legacyPackages.x86_64-darwin.mkShell {
        packages = [ ];
      };
    };
}
