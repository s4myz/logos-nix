# `nix flake check`: the launcher builds (with shellcheck) in its common
# configurations, the registry renders as intended, and both modules evaluate.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  logos = self.packages.${pkgs.stdenv.hostPlatform.system}.logos;

  dxvkDark = logos.override {
    logosConfig = {
      renderer = "dxvk";
      dpi = 144;
      browser = "firefox";
      memoryHigh = "75%";
      colors.accent = "#89b4fa";
    };
  };
  light = logos.override { logosConfig.theme = "light"; };

  # Assert on the generated .reg text without running Wine.
  registry = pkgs.runCommand "logos-registry-check" { } ''
    dark=${logos.settings}
    dxvk=${dxvkDark.settings}
    light=${light.settings}
    fail() { echo "FAIL: $*" >&2; exit 1; }

    grep -qx 'REGEDIT4' $dark || fail "no REGEDIT4 header"
    grep -qx '"ThemeActive"="0"' $dark || fail "dark: msstyles still active"
    grep -qx '"AppsUseLightTheme"=dword:00000000' $dark || fail "dark: AppsUseLightTheme"
    grep -qx '"Window"="30 30 30"' $dark || fail "dark: default palette"
    grep -qx '"renderer"="gdi"' $dark || fail "default renderer"
    grep -qx '"d3d11"=-' $dark || fail "gdi must clear DXVK overrides"
    grep -qx '"LogPixels"=-' $dark || fail "default DPI must be cleared"

    grep -qx '"renderer"=-' $dxvk || fail "dxvk: renderer value must be deleted"
    grep -qx '"d3d11"="native,builtin"' $dxvk || fail "dxvk: override"
    grep -qx '"LogPixels"=dword:00000090' $dxvk || fail "dpi 144"
    grep -qx '"Browsers"="firefox"' $dxvk || fail "browser"
    grep -qx '"Hilight"="137 180 250"' $dxvk || fail "custom accent"
    grep -q 'MemoryHigh' ${dxvkDark}/bin/.logos-wrapped || fail "launcher lost memoryHigh handling"
    grep -q '^readonly MEMORY_HIGH=75%' ${dxvkDark}/bin/.logos-wrapped || fail "memoryHigh not substituted"

    grep -qx '"ThemeActive"="1"' $light || fail "light: msstyles"
    grep -qx '\[-HKEY_CURRENT_USER\\Control Panel\\Colors\]' $light || fail "light: colours not reset"
    grep -q '"Window"=' $light && fail "light: dark palette leaked"

    touch $out
  '';

  nixosEval =
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
      system = null;
      modules = [
        self.nixosModules.default
        {
          nixpkgs.pkgs = pkgs;
          programs.logos = {
            enable = true;
            renderer = "dxvk";
            colors.accent = "#89b4fa";
          };
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          boot.loader.grub.enable = false;
          system.stateVersion = "26.05";
        }
      ];
    }).config;

  # Home Manager isn't an input, so evaluate its module against stubs of the
  # two HM options it writes.
  hmEval =
    (lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        self.homeModules.default
        {
          options.home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; };
          options.xdg.mimeApps.defaultApplications = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
          config.programs.logos = {
            enable = true;
            theme = "light";
          };
        }
      ];
    }).config;
in
{
  inherit logos registry;
  logos-dxvk = dxvkDark;
  logos-light = light;

  # The NixOS module wires the configured launcher into the system.
  nixos-module = pkgs.runCommand "logos-nixos-module-check" { } ''
    ${lib.optionalString (
      !(lib.elem nixosEval.programs.logos.finalPackage nixosEval.environment.systemPackages)
    ) "echo 'launcher not in systemPackages' >&2; exit 1"}
    ${lib.optionalString (
      !(lib.elem "ntsync" nixosEval.boot.kernelModules)
    ) "echo 'ntsync not loaded' >&2; exit 1"}
    grep -qx '"renderer"=-' ${nixosEval.programs.logos.finalPackage.settings}
    touch $out
  '';

  home-manager-module = pkgs.runCommand "logos-hm-module-check" { } ''
    ${lib.optionalString (
      hmEval.xdg.mimeApps.defaultApplications."x-scheme-handler/logos4" != "logos.desktop"
    ) "echo 'no logos4 handler' >&2; exit 1"}
    grep -qx '"ThemeActive"="1"' ${(lib.head hmEval.home.packages).settings}
    touch $out
  '';
}
