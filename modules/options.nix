# The `programs.logos` options shared by the NixOS and Home Manager modules.
# Each setting maps 1:1 onto an argument of package/default.nix.
self:
{ lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
in
{
  enable = mkEnableOption "Logos Bible Software (installed into a Wine prefix on first run)";

  package = mkOption {
    type = types.package;
    default = pkgs.callPackage "${self}/package" { };
    defaultText = lib.literalExpression "pkgs.callPackage \"\${logos-nix}/package\" { }";
    description = "The launcher package; the settings below are applied to it with `.override`.";
  };

  finalPackage = mkOption {
    type = types.package;
    readOnly = true;
    description = "The launcher with every setting applied.";
  };

  wine = mkOption {
    type = types.package;
    default = pkgs.wineWow64Packages.stagingFull;
    defaultText = lib.literalExpression "pkgs.wineWow64Packages.stagingFull";
    description = ''
      Wine build that runs Logos. It must be a WoW64 build (`wineWow64Packages.*`);
      `stableFull` is the fallback if a staging release misbehaves.
    '';
  };

  theme = mkOption {
    type = types.enum [
      "dark"
      "light"
    ];
    default = "dark";
    description = ''
      Windows app theme reported to Logos, which follows it until an
      Application Theme is chosen inside Logos (⋯ → Application Theme).
      Wine's own dialogs always keep their stock colours: a dark system
      palette makes Logos' Bible text unreadable.
    '';
  };

  renderer = mkOption {
    type = types.enum [
      "gdi"
      "gl"
      "vulkan"
      "dxvk"
    ];
    default = "gdi";
    description = ''
      Direct3D backend. `gdi` renders in software: stable, and the only choice
      whose popups render correctly on wlroots compositors (Hyprland, Sway),
      but slower on big screens. `dxvk` (Direct3D on Vulkan) and `gl` are
      smoother; on Hyprland their menus and tooltips come out black, and `gl`
      has frozen Logos. They should be fine on GNOME and KDE (untested).
    '';
  };

  dpi = mkOption {
    type = types.nullOr (types.ints.between 96 480);
    default = null;
    example = 144;
    description = "Windows DPI (96 = 100 %, 144 = 150 %, 192 = 200 %). null keeps Wine's default.";
  };

  graphicsDriver = mkOption {
    type = types.nullOr (
      types.enum [
        "x11"
        "wayland"
      ]
    );
    default = "x11";
    description = ''
      Wine graphics driver. `x11` runs through XWayland on a Wayland session,
      which is what Logos users report working; Wine's native `wayland` driver
      is experimental for Logos.
    '';
  };

  browser = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "firefox";
    description = ''
      Program Wine opens web links (including Logos' sign-in page) with. null
      uses xdg-open. Set it to "firefox" if clicking Sign In does nothing with a
      Chromium-based default browser (OuDedetai issue #435).
    '';
  };

  extraRegistry = mkOption {
    type = types.lines;
    default = "";
    description = "Extra REGEDIT4 lines imported into the prefix with the generated settings.";
  };

  acceptEula = mkOption {
    type = types.bool;
    default = false;
    description = ''
      Accept Faithlife's terms of use (https://faithlife.com/terms) up front,
      skipping the confirmation shown before the first install.
    '';
  };

  blockAppUpdates = mkOption {
    type = types.bool;
    default = true;
    description = ''
      Keep Logos from updating itself while it runs; in-app updates crash under
      Wine. New releases are installed with `logos update` (or the "Update
      Logos" desktop action) instead. Resource (book) downloads are unaffected
      when started by hand.
    '';
  };

  updateCheck = mkOption {
    type = types.bool;
    default = true;
    description = "Show a notification at launch when a newer Logos release is available.";
  };

  memoryHigh = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "75%";
    description = ''
      Soft memory cap for Logos and its Wine processes (systemd `MemoryHigh`).
      Each Logos panel runs its own ~250 MB Chromium process, so this keeps a
      long session from pushing the rest of the desktop into swap.
    '';
  };

  popupShadowFix = mkOption {
    type = types.enum [
      "auto"
      "on"
      "off"
    ];
    default = "auto";
    description = ''
      Preload a small shim that stops Logos' tooltips, menus and popups being
      drawn inside oversized dark boxes on wlroots compositors (Hyprland, Sway).
      Those compositors ignore the X11 shape Wine gives popups with shadows.
      `auto` enables it with `renderer = "gdi"` on Wayland sessions other
      than GNOME and KDE. With `dxvk`/`gl` it would make popups solid black.
    '';
  };

  channel = mkOption {
    type = types.enum [
      "stable"
      "beta"
    ];
    default = "stable";
    description = "Faithlife release feed that `logos install`/`update` follow.";
  };
}
