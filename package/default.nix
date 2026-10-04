# The `logos` launcher. Logos itself is never in the Nix store: it is
# proprietary, updates monthly and installs per-user, so the launcher downloads
# the official MSI into a Wine prefix on first run. Everything that CAN be
# declared — Wine, its settings, fonts, ICU, DXVK, the theme — is pinned here.
#
# Settings come in through `logosConfig`; the NixOS and Home Manager modules
# set it with `.override`.
{
  lib,
  stdenvNoCC,
  fetchurl,
  writeText,
  makeWrapper,
  makeDesktopItem,
  copyDesktopItems,
  shellcheck,

  wineWow64Packages,
  corefonts,
  dxvk,
  curl,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  gnutar,
  gzip,
  findutils,
  procps,
  sqlite,
  inotify-tools,
  icoutils,
  gtk3,
  zenity,
  libnotify,
  xdg-utils,
  zstd,
  systemd,

  # Every setting lives in this one attrset (see `defaults` below). They are
  # NOT separate arguments: callPackage fills any argument that shares a name
  # with a nixpkgs attribute (`wine`, `theme`, …), silently beating defaults.
  logosConfig ? { },
}:
let
  defaults = {
    # Wine build. stagingFull is the closest to the community installer's
    # recommendation (wine-staging) and embeds mono/gecko, so nothing prompts.
    wine = wineWow64Packages.stagingFull;
    # "dark" | "light": colours Wine's own UI and tells apps that ask (uxtheme)
    # which mode the system is in. Logos' window follows its in-app theme.
    theme = "dark";
    colors = { };
    # "gdi" (community default: slow, software) | "gl" | "vulkan" (wined3d) |
    # "dxvk" (D3D on Vulkan: the fix users report for a laggy UI).
    renderer = "gdi";
    # Windows DPI (96 = 100 %, 144 = 150 %). null keeps Wine's default.
    dpi = null;
    # "x11" (XWayland on a Wayland session) | "wayland" | null (Wine decides).
    graphicsDriver = "x11";
    # Browser Wine opens links with (e.g. "firefox"). null = xdg-open. Setting
    # it works around OuDedetai#435: Sign In doing nothing with Chromium.
    browser = null;
    # Raw REGEDIT4 lines appended to the generated registry file.
    extraRegistry = "";
    # Skip the first-install confirmation of Faithlife's terms.
    acceptEula = false;
    # Keep Logos from updating itself (it crashes under Wine); `logos update`.
    blockAppUpdates = true;
    # Notify on launch when a newer Logos release is out.
    updateCheck = true;
    # Soft memory cap for Logos (systemd MemoryHigh, e.g. "75%"); null = none.
    memoryHigh = null;
    winedebug = "err+all";
    channel = "stable";
  };

  unknown = lib.attrNames (removeAttrs logosConfig (lib.attrNames defaults));
  cfg =
    assert lib.assertMsg (unknown == [ ]) "logos: unknown setting(s): ${toString unknown}";
    defaults // logosConfig;

  inherit (cfg)
    wine
    theme
    renderer
    dpi
    graphicsDriver
    browser
    extraRegistry
    acceptEula
    blockAppUpdates
    updateCheck
    memoryHigh
    winedebug
    channel
    ;

  defaultColors = {
    background = "#1e1e1e";
    surface = "#2b2b2b";
    raised = "#3a3a3a";
    border = "#4a4a4a";
    shadow = "#121212";
    text = "#e6e6e6";
    mutedText = "#8c8c8c";
    accent = "#3d7ae0";
    accentText = "#ffffff";
  };

  palette = defaultColors // cfg.colors;

  # FaithLife-Community's ICU build for Windows: Wine has no icu.dll
  # (WineHQ bug 53354) and Logos' .NET runtime will not start without it.
  icu = fetchurl {
    url = "https://github.com/FaithLife-Community/icu/releases/download/72.1-custom%2B4/icu-win.tar.gz";
    hash = "sha256-KBPqEgX8+dmnkwM52uGB3D4pmyOR8vSHnF5UK+Q/On8=";
  };

  settingsReg = writeText "logos-settings.reg" (
    import ./registry.nix {
      inherit
        lib
        theme
        renderer
        dpi
        graphicsDriver
        browser
        extraRegistry
        ;
      colors = palette;
    }
  );

  setup = stdenvNoCC.mkDerivation {
    name = "logos-setup";
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out
      cp ${settingsReg} $out/settings.reg
      # From FaithLife-Community/OuDedetai (MIT), ou_dedetai/assets/.
      cp ${./LogosStubFailOK.mst} $out/LogosStubFailOK.mst
    '';
  };

  dxvkDir = if renderer == "dxvk" then "${dxvk.bin}" else "";

  boolStr = b: if b then "1" else "0";

  runtimePath = lib.makeBinPath [
    wine
    curl
    coreutils
    gawk
    gnugrep
    gnused
    gnutar
    gzip
    findutils
    procps
    sqlite
    inotify-tools
    icoutils
    gtk3 # gtk-update-icon-cache
    zenity
    libnotify
    xdg-utils
    zstd
    systemd
  ];
in
assert lib.assertOneOf "theme" theme [
  "dark"
  "light"
];
assert lib.assertOneOf "renderer" renderer [
  "gdi"
  "gl"
  "vulkan"
  "dxvk"
];
assert lib.assertOneOf "graphicsDriver" graphicsDriver [
  null
  "x11"
  "wayland"
];
assert lib.assertOneOf "channel" channel [
  "stable"
  "beta"
];
stdenvNoCC.mkDerivation {
  pname = "logos";
  version = "0.1.0";

  src = ./logos.sh;
  dontUnpack = true;

  nativeBuildInputs = [
    makeWrapper
    copyDesktopItems
  ];

  desktopItems = [
    (makeDesktopItem {
      name = "logos";
      desktopName = "Logos Bible Software";
      genericName = "Bible Study";
      comment = "Logos Bible Software, running in Wine";
      exec = "logos run %u";
      icon = "logos-bible";
      categories = [
        "Education"
        "Literature"
      ];
      keywords = [
        "Bible"
        "Faithlife"
        "Study"
      ];
      # Sign-in comes back from the browser as logos4: URLs.
      mimeTypes = [
        "x-scheme-handler/logos4"
        "x-scheme-handler/libronixdls"
      ];
      startupWMClass = "logos.exe";
      startupNotify = true;
      actions = {
        update = {
          name = "Update Logos";
          exec = "logos update";
        };
        indexer = {
          name = "Rebuild Library Index";
          exec = "logos indexer";
        };
        stop = {
          name = "Force Quit";
          exec = "logos kill";
        };
        winecfg = {
          name = "Wine Settings";
          exec = "logos winecfg";
        };
      };
    })
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/logos
    substituteInPlace $out/bin/logos \
      --subst-var-by setup ${setup} \
      --subst-var-by icu ${icu} \
      --subst-var-by fonts ${corefonts}/share/fonts/truetype \
      --subst-var-by dxvk '${dxvkDir}' \
      --subst-var-by renderer ${renderer} \
      --subst-var-by theme ${theme} \
      --subst-var-by acceptEula ${boolStr acceptEula} \
      --subst-var-by blockAppUpdates ${boolStr blockAppUpdates} \
      --subst-var-by updateCheck ${boolStr updateCheck} \
      --subst-var-by memoryHigh '${toString memoryHigh}' \
      --subst-var-by winedebug '${winedebug}' \
      --subst-var-by feed 'https://clientservices.logos.com/update/v1/feed/logos10/${channel}.xml'
    wrapProgram $out/bin/logos --prefix PATH : ${runtimePath}
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    ${lib.getExe shellcheck} --shell=bash $src
    if grep -n '^[^#]*@[a-zA-Z]*@' $out/bin/.logos-wrapped; then
      echo "unsubstituted placeholder in the launcher" >&2
      exit 1
    fi
    $out/bin/logos help >/dev/null
    runHook postInstallCheck
  '';

  passthru = {
    inherit wine setup icu;
    settings = settingsReg;
  };

  meta = {
    description = "Declarative Wine launcher and installer for Logos Bible Software";
    longDescription = ''
      Installs the official Logos Bible Software into a per-user Wine prefix on
      first run and launches it, with dark Wine theming, DXVK, update control
      and a logos4: URL handler for signing in. Logos itself is downloaded from
      Faithlife and is subject to its terms.
    '';
    homepage = "https://github.com/s4myz/logos-nix";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "logos";
  };
}
