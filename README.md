# logos-nix

Logos Bible Software on NixOS, as a flake. You get one `logos` command that:

- builds a Wine prefix with the right settings,
- downloads and installs the official Logos release,
- launches Logos in dark mode, with update control and a working sign-in hand-back.

Logos itself is **not** in this repository or the Nix store. Faithlife's installer is downloaded on your machine the first time you run `logos`, and you accept Faithlife's [terms](https://faithlife.com/terms) at that point. The free tier ("Logos Free Edition") works.

Status: tested on 2026-10-04, NixOS with Hyprland on an NVIDIA RTX 5080:
- Wine staging 11.18;
- Logos 53.1;
- sign-in through Brave;
- the free library downloaded and indexed.

## Use it

### Dendritic (flake-parts + import-tree)

Add the input:

```nix
logos-nix = {
  url = "github:s4myz/logos-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Add a feature file, e.g. `modules/features/logos.nix`:

```nix
{ inputs, ... }:
{
  flake.modules.homeManager.logos = {
    imports = [ inputs.logos-nix.modules.homeManager.logos ];
    programs.logos.enable = true;
  };
}
```

Then list `logos` in the home-manager imports of the hosts that should have it.

### Plain NixOS or Home Manager

```nix
imports = [ inputs.logos-nix.nixosModules.default ];   # or homeModules.default
programs.logos.enable = true;
```

### Without modules

```nix
nixpkgs.overlays = [ inputs.logos-nix.overlays.default ];
environment.systemPackages = [
  (pkgs.logos.override { logosConfig.renderer = "dxvk"; })
];
```

You can also try it once with `nix run github:s4myz/logos-nix`.

### Requirements

- **Unfree fonts.** The Arial fonts come from `corefonts`, which is unfree, so your nixpkgs must allow it: `allowUnfree = true`, or an `allowUnfreePredicate` that admits `corefonts`. The flake's own `packages` output already allows it.
- **Graphics.** The NixOS module sets `hardware.graphics.enable` and loads `ntsync`. With the Home Manager module only, your system config needs graphics enabled. Add `ntsync` too if you want faster Windows synchronisation.

## First run

1. Start **Logos Bible Software** from your launcher, or run `logos`. Confirm the dialog. The launcher then creates `~/.local/share/logos/prefix`, downloads the installer (about 480 MB, cached in `~/.cache/logos`) and installs it. This takes 1–2 minutes.
2. **Sign in.** Click *Sign In*, finish in your browser, and allow the browser to open *Logos Bible Software*. The browser hands the result back through a `logos4:` link, which the package's desktop entry handles.
3. Logos downloads your books and indexes them. Leave it running. Logos often crashes once during this first download; just start it again.
4. **Dark mode.** Logos starts dark, because the prefix tells Windows apps that the system uses dark mode (`theme`). To change it, use ⋯ → *Application Theme*, or type the command `Set Application Theme to Dark` / `…Light`.

   Wine's own dialogs (installer progress, file pickers) keep Wine's stock light colours, on purpose. Logos draws Bible text with Windows system colours, so a dark system palette makes that text dark-on-dark and unreadable in either Logos theme.

## Commands

| Command | What it does |
|---|---|
| `logos` / `logos run [URL]` | Start Logos, installing it first if needed. A `logos4:`/`libronixdls:` URL goes to the running instance. |
| `logos update` | Install the newest release if it is newer than yours. |
| `logos install [VERSION]` | Install the latest release, or a specific one. |
| `logos indexer` | Rebuild the library index. Close Logos first. |
| `logos status` | Show the installed and latest versions, Wine version, paths and settings. |
| `logos kill` | Stop Logos and its Wine processes. |
| `logos backup [DIR]` | Write `Data/` and `Documents/` to a `.tar.zst` file. |
| `logos log` | Follow the Wine log (`~/.local/state/logos/wine.log`). |
| `logos winecfg` / `regedit` / `wine …` | Run Wine tools inside the Logos prefix. |

Right-clicking the launcher entry offers *Update Logos*, *Rebuild Library Index*, *Force Quit* and *Wine Settings*.

## Options (`programs.logos.*`)

| Option | Default | Notes |
|---|---|---|
| `enable` | `false` | |
| `wine` | `wineWow64Packages.stagingFull` | Must be a WoW64 build. `stableFull` is the fallback. |
| `theme` | `"dark"` | The Windows app theme reported to Logos. Logos follows it until you pick an *Application Theme* in Logos. |
| `renderer` | `"gdi"` | `gdi` (software; stable but slow), `gl`, `vulkan`, or `dxvk` (Direct3D on Vulkan, which users report fixes a laggy UI). |
| `dpi` | `null` | Windows DPI, e.g. `144` for 150 %. |
| `graphicsDriver` | `"x11"` | `x11` runs through XWayland. Wine's own `wayland` driver is experimental for Logos. |
| `browser` | `null` | Browser for links Logos opens. `null` means xdg-open. Use `"firefox"` if *Sign In* does nothing. |
| `blockAppUpdates` | `true` | Logos updating itself crashes under Wine. Use `logos update` instead. |
| `updateCheck` | `true` | Notify at launch when a newer release exists. |
| `memoryHigh` | `null` | Soft memory cap through systemd, e.g. `"75%"`. Each Logos panel runs its own ~250 MB Chromium. |
| `acceptEula` | `false` | `true` skips the terms dialog before installing. |
| `channel` | `"stable"` | `"beta"` follows Faithlife's beta feed. |
| `extraRegistry` | `""` | Extra REGEDIT4 lines. |
| `urlHandler` (HM) | `true` | Writes the `logos4:` handler to `mimeapps.list` when `xdg.mimeApps.enable` is set. Otherwise the launcher registers it with `xdg-mime`. |
| `ntsync` (NixOS) | `true` | Loads the `ntsync` kernel module. |

## How it works

Everything that can be declared is pinned in the Nix store:
- **Wine:** the build you choose.
- **Registry:** a generated REGEDIT4 file (dark-mode flag, font smoothing, renderer, Wine driver).
- **ICU:** FaithLife-Community's ICU DLLs. Wine has no `icu.dll`, and Logos won't start without one.
- **Arial:** the fonts Logos needs.
- **DXVK.**
- **MSI transform:** the community installer's `LogosStubFailOK.mst`. It lets the Logos installer's MSIX component fail, because Wine cannot install it.

On each start, the launcher compares stamp files in the prefix with those store paths, and reapplies only what changed. Editing your Nix config and rebuilding therefore really changes the prefix. Every setting that can be turned off is written as an explicit delete, so removing a setting reverts it.

Logos itself, with your library and notes, stays mutable in the prefix, under `drive_c/users/$USER/AppData/Local/Logos`.

The Wine setup follows the community installer, [Ou Dedetai](https://github.com/FaithLife-Community/OuDedetai). [`docs/research/logos-on-wine.md`](docs/research/logos-on-wine.md) traces each step to its source.

## Troubleshooting

- **Signing in opens the browser, but it can't hand back to Logos** ("GNOME Software can't find…", or nothing happens). Your browser opens `logos4:` links through the XDG desktop portal. The portal only notices new desktop entries after it restarts, which matters right after you first install the package. Run `systemctl --user restart xdg-desktop-portal`, or log out and back in, then click *Sign In* again.
- **The UI is slow:** set `renderer = "dxvk"`.
- **The UI is too small on a HiDPI screen:** set `dpi`.
- **Logos won't start after a crash:** `logos kill`, then `logos`.
- **Logs:** `~/.local/state/logos/wine.log` (the previous run is `wine.1.log`), and `launcher.log` in the same directory.
- **Known Wine limitations:** printing, audio/video and text-to-speech don't work. On wlroots compositors, Wine popups can have black frames.

## Development

```bash
nix flake check   # builds the launcher variants (shellcheck included) and asserts the registry and module wiring
nix fmt
```
