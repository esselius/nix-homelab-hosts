{
  description = "NixOS Raspberry Pi 5 incus VM hosts, impermanence on NVMe, SD boot for bootloader";

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

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      disko,
      impermanence,
      ...
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
        ./modules/raspberry-pi.nix
        ./modules/nix-settings.nix
        ./modules/ssh-access.nix
        ./modules/zram.nix
        ./modules/incus
        ./modules/sops.nix
        ./modules/storage.nix
        ./disko-nvme.nix
        ./disko-sd.nix
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
        "rpi5-bootstrap" = mkHost "rpi5-bootstrap" (
          [ { imports = [ ./hosts/rpi5-bootstrap.nix ]; } ]
        );
      };

      images.rpi5-bootstrap = self.nixosConfigurations."rpi5-bootstrap".config.system.build.sdImage;

      devShells.aarch64-darwin.default =
        let
          pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        in
        pkgs.mkShell {
          packages = [
            # incus-lts.client builds on darwin (platforms = linux ++ darwin),
            # so the Mac gets the CLI to drive the Pis over the remote API.
            pkgs.incus-lts.client
            # Secrets workflow: edit/rotate secrets/rpi5.yaml.
            pkgs.sops
            pkgs.age
            # Convert each Pi's SSH host key into an age recipient.
            pkgs.ssh-to-age
          ];

          # sops 3.13.3 does not read ~/.ssh/id_ed25519 directly (its SSH
          # fallback is ~/.ssh/id_rsa only), so derive a native age identity
          # from the on-disk SSH key on the fly. $HOME is expanded here at
          # shell entry (the command is exec'd without a shell by sops).
          shellHook = ''
            export SOPS_AGE_KEY_CMD="ssh-to-age -private-key -i $HOME/.ssh/id_ed25519"
          '';
        };
    };
}
