# NixOS: `programs.logos` system-wide. Every user who runs `logos` gets their
# own prefix in ~/.local/share/logos.
self:
{
  config,
  lib,
  pkgs,
  ...
}@args:
let
  cfg = config.programs.logos;
in
{
  imports = [
    (lib.mkRemovedOptionModule [ "programs" "logos" "colors" ] ''
      The dark Wine palette was removed: Logos paints its Bible text with
      system colours, so it made the text unreadable. `theme` alone sets
      Logos' dark mode.
    '')
  ];

  options.programs.logos = import ./options.nix self args // {
    ntsync = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Load the ntsync kernel module. Wine 11 uses /dev/ntsync for Windows
        synchronisation primitives when it exists, which is faster than its
        wineserver fallback.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.logos.finalPackage = import ./package.nix cfg;

    environment.systemPackages = [ cfg.finalPackage ];

    boot.kernelModules = lib.mkIf cfg.ntsync [ "ntsync" ];

    # DXVK and wined3d's GL/Vulkan paths need the userspace graphics stack.
    hardware.graphics.enable = lib.mkDefault true;
  };
}
