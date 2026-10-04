{
  description = "Logos Bible Software on NixOS: a declarative Wine launcher with dark mode";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # Wine only runs Logos (an x86-64 Windows app) on x86_64.
      systems = [ "x86_64-linux" ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              # Arial for the prefix comes from corefonts (unfreeRedistributable).
              # Configs using the overlay or modules need the same allowance.
              config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "corefonts";
            }
          )
        );

      overlay = final: prev: {
        logos = final.callPackage ./package { };
      };

      nixosModule = import ./modules/nixos.nix self;
      homeModule = import ./modules/home-manager.nix self;
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (pkgs: {
        logos = pkgs.callPackage ./package { };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.logos;
      });

      nixosModules = {
        logos = nixosModule;
        default = nixosModule;
      };
      homeModules = {
        logos = homeModule;
        default = homeModule;
      };

      # The flake-parts `flake.modules.<class>.<name>` shape, so a dendritic
      # config can import `inputs.logos-nix.modules.homeManager.logos`.
      modules = {
        nixos.logos = nixosModule;
        homeManager.logos = homeModule;
      };

      checks = forAllSystems (pkgs: import ./checks { inherit pkgs self; });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
