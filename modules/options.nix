# The `programs.logos` options shared by the NixOS and Home Manager modules.
# Each setting maps 1:1 onto an argument of package/default.nix.
self:
{ lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  color = types.strMatching "#?[0-9a-fA-F]{6}";
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
      Colours of Wine-drawn UI (installer, file pickers, message boxes, menus)
      and the system light/dark preference reported to Windows apps. Logos'
      own window follows its in-app setting: run the command
      "Set Application Theme to Dark" once inside Logos.
    '';
  };

  colors = mkOption {
    type = types.submodule {
      freeformType = types.attrsOf color;
      options =
        lib.genAttrs
          [
            "background"
            "surface"
            "raised"
            "border"
            "shadow"
            "text"
            "mutedText"
            "accent"
            "accentText"
          ]
          (
            name:
            mkOption {
              type = types.nullOr color;
              default = null;
              description = "`#rrggbb`; null keeps the built-in neutral dark palette's value.";
            }
          );
    };
    default = { };
    apply = lib.filterAttrs (_: v: v != null);
    example = lib.literalExpression ''
      with config.lib.stylix.colors.withHashtag; {
        background = base00; surface = base01; raised = base02; border = base03;
        shadow = base00; text = base05; mutedText = base04;
        accent = base0D; accentText = base00;
      }
    '';
    description = "Palette for the dark Wine theme (ignored when `theme = \"light\"`).";
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
      Direct3D backend. `gdi` is the community installer's default: software
      rendering, stable but slow on large or HiDPI screens. `dxvk` (Direct3D on
      Vulkan) is what users report fixes the laggy UI; it needs working Vulkan.
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

  channel = mkOption {
    type = types.enum [
      "stable"
      "beta"
    ];
    default = "stable";
    description = "Faithlife release feed that `logos install`/`update` follow.";
  };
}
