{
  description = "NixOS Raspberry Pi 5 incus VM hosts, impermanence on NVMe, SD boot for bootloader";

  nixConfig = {
    extra-substituters = [ "https://esselius.cachix.org" ];
    extra-trusted-public-keys = [
      "esselius.cachix.org-1:h6FQzpdflxdZfnnL0caV88xt5K5sNzgO0VIHQthTymA="
    ];
  };

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
        modules:
        nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit inputs; };
          inherit modules;
        };

      # Shared by the permanent hosts and the bootstrap installer.
      baseModules = [
        ./modules/raspberry-pi.nix
        ./modules/nix-settings.nix
        ./modules/ssh-access.nix
      ];

      mainHostModules = baseModules ++ [
        ./modules/site.nix
        ./modules/zram.nix
        ./modules/wireguard.nix
        ./modules/dns.nix
        ./modules/incus
        ./modules/sops.nix
        ./modules/monitoring-agent.nix
        ./modules/cgroup-metrics.nix
        ./modules/nvme-wear.nix
        ./modules/nix-cache.nix
        ./modules/pki.nix
        ./modules/storage.nix
        ./disko-nvme.nix
        ./disko-sd.nix
        disko.nixosModules.disko
        impermanence.nixosModules.impermanence
      ];
    in
    {
      nixosConfigurations = {
        rpi5-8gb = mkHost (mainHostModules ++ [ ./hosts/rpi5-8gb.nix ]);
        rpi5-4gb = mkHost (mainHostModules ++ [ ./hosts/rpi5-4gb.nix ]);
        rpi5-bootstrap = mkHost (baseModules ++ [ ./hosts/rpi5-bootstrap.nix ]);
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
            # Derive/verify WireGuard public keys (`wg pubkey`) and inspect peers.
            pkgs.wireguard-tools
            # Push host closures to the caches (`task cache-push`): the external
            # Cachix fallback and the local Attic workload.
            pkgs.cachix
            pkgs.attic-client
            pkgs.opencode
          ];

          # sops 3.13.3 does not read ~/.ssh/id_ed25519 directly (its SSH
          # fallback is ~/.ssh/id_rsa only), so derive a native age identity
          # from the on-disk SSH key on the fly. $HOME is expanded here at
          # shell entry (the command is exec'd without a shell by sops).
          shellHook = ''
            export SOPS_AGE_KEY_CMD="ssh-to-age -private-key -i $HOME/.ssh/id_ed25519"
          '';
        };

      formatter.aarch64-darwin =
        let
          pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        in
        pkgs.writeShellApplication {
          name = "fmt-nix-homelab-hosts";
          runtimeInputs = [
            pkgs.fd
            pkgs.nixfmt
          ];
          text = ''
            if [ "$#" -eq 0 ]; then
              fd --extension nix --exec nixfmt {}
            elif [ "$1" = "--check" ]; then
              fd --extension nix --exec nixfmt --check {}
            else
              nixfmt "$@"
            fi
          '';
        };

      checks.aarch64-darwin =
        let
          pkgs = nixpkgs.legacyPackages.aarch64-darwin;
          # Eval does not require the target platform, so a Darwin `nix flake
          # check` can still prove the aarch64-linux hosts evaluate.
          hostDrvs =
            map (c: c.config.system.build.toplevel) (builtins.attrValues self.nixosConfigurations)
            ++ [ self.images.rpi5-bootstrap ];
        in
        {
          # Force evaluation of every host's toplevel drvPath (eval, not build):
          # fails here if any host stops evaluating.
          eval-all = builtins.deepSeq (map (d: d.drvPath) hostDrvs) (
            pkgs.runCommand "eval-all" { } ''
              touch $out
            ''
          );

          # Formatting gate, matching `nix fmt`.
          fmt =
            pkgs.runCommand "fmt-check"
              {
                nativeBuildInputs = [
                  pkgs.fd
                  pkgs.nixfmt
                ];
                src = self;
              }
              ''
                cd "$src"
                fd --extension nix --exec nixfmt --check {}
                touch $out
              '';

          # The hand-written shell (node_exporter textfile collectors) is the
          # one layer `nix fmt` does not cover.
          shellcheck =
            pkgs.runCommand "shellcheck"
              {
                nativeBuildInputs = [ pkgs.shellcheck ];
                src = self;
              }
              ''
                cd "$src"
                shellcheck modules/scripts/*.sh scripts/*.sh
                touch $out
              '';
        };
    };
}
