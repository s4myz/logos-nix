# Home Manager: `programs.logos` for one user. The prefix lives in
# $XDG_DATA_HOME/logos, so this is the natural place to enable it.
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
    urlHandler = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Make Logos the handler for logos4:/libronixdls: links, which is how
        sign-in returns from the browser. Written to mimeapps.list only when
        `xdg.mimeApps.enable` is set; otherwise the launcher registers itself
        with xdg-mime on first run (unless something else already has).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.logos.finalPackage = import ./package.nix cfg;

    home.packages = [ cfg.finalPackage ];

    xdg.mimeApps.defaultApplications = lib.mkIf cfg.urlHandler {
      "x-scheme-handler/logos4" = "logos.desktop";
      "x-scheme-handler/libronixdls" = "logos.desktop";
    };
  };
}
