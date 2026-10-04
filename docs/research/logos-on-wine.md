# Logos Bible Software on Wine: research notes for a Nix launcher

Researched 2026-10-04. Ground truth is the community installer's source code.

**Pinned sources:**
- **Community installer:** the canonical repo is now **github.com/FaithLife-Community/OuDedetai**. `github.com/FaithLife-Community/LogosLinuxInstaller` redirects to it (`gh api repos/FaithLife-Community/LogosLinuxInstaller` returns `full_name: FaithLife-Community/OuDedetai`). The default branch is `main`, read at commit **`e72fd5f9a236aed009c8e444a954774da5750f8d`** (2026-10-01, "chore: bump version to 4.0.0-beta.15").
- **Latest release:** tag **`v4.0.0-beta.15`**, published 2026-10-01. GitHub marks it as a full release, not a pre-release, despite the "beta" name. `LLI_CURRENT_VERSION = "4.0.0-beta.15"` is set in `ou_dedetai/constants.py:89`.
- **Permalink base** used below: `https://github.com/FaithLife-Community/OuDedetai/blob/e72fd5f9a236aed009c8e444a954774da5750f8d/` (written as `OD:` followed by the path).

Some claims are marked **UNVERIFIED**. Those are inferences or things I could not confirm from a primary source.

## 0. Launcher recipe distilled from the sections below

1. **Wine package.** Use `wineWow64Packages.stagingFull`: 11.8 on nixos-26.05, 11.18 on unstable. Call `wine`; there is no `wine64`. The environment is `WINEPREFIX=…` and `WINEDEBUG=err+all`; OD sets nothing else.
2. **Create the prefix** if `$WINEPREFIX/system.reg` is missing: `WINEDLLOVERRIDES="mscoree=" wine wineboot --init`, then `wineserver -w`.
3. **Import registry settings** with `wine regedit file.reg`, then `wineserver -w`:
   - `HKCU\Software\Wine\DllOverrides` `"winemenubuilder.exe"=""`;
   - `HKCU\Software\Wine\Direct3D` `"renderer"="gdi"`. OD's default, but slow; DXVK is the reported performance fix, see §4;
   - `HKCU\Control Panel\Desktop` `FontSmoothing="2"`, `FontSmoothingGamma=dword:578`, `FontSmoothingOrientation=dword:1`, `FontSmoothingType=dword:2`.
   - Optionally, the dark-chrome keys from §2.4.
4. **Arial.** Copy the Arial TTFs into `drive_c/windows/Fonts` and register them (§1.4).
5. **ICU.** Extract `icu-win.tar.gz` (FaithLife-Community/icu `72.1-custom+4`) into `drive_c/`, which yields `drive_c/windows/{system32,syswow64,globalization/ICU}` (§1.3.4). This can be a fixed-output `fetchurl` with sha256 `2813ea1205fcf9d9a7930339dae181dc3e299b2391f2f4879c5e542be43f3a7f`.
6. **Download the MSI.**
   - Find the newest version: the first `<logos:version>` in `https://clientservices.logos.com/update/v1/feed/logos10/stable.xml` (Atom, BOM).
   - Download `https://downloads.logoscdn.com/LBS10/Installer/$V/Logos-x64.msi`. Verify size against `Content-Length`, and MD5 against the S3 `ETag`.
7. **Install:** `wine msiexec /i Logos-x64.msi /passive TRANSFORMS="$(wine winepath -w LogosStubFailOK.mst)"`.
   - The MST is required for releases > 39. Vendor it from OD (MIT) with sha256 `11877bde…a95a87`.
   - Re-run steps 6-7 to update Logos. In-app updates break under Wine.
8. **Launch:** `wineserver -k` (optional, as OD does), then `wine "$WINEPREFIX/drive_c/users/$USER/AppData/Local/Logos/Logos.exe"`. The indexer is `…\Logos\System\LogosIndexer.exe`.
9. **Login (required).** Install a desktop file with `MimeType=x-scheme-handler/logos4;x-scheme-handler/libronixdls;` and `Terminal=false`, whose Exec runs `wine 'C:\users\<u>\AppData\Local\Logos\Logos.exe' %u` in the same prefix. Make it the default handler with xdg-mime or `xdg.mime.defaultApplications`.

---

## 1. What Ou Dedetai does to a Wine prefix (source-level walkthrough)

### 1.1 Install-step chain (in order)

`installer.install()` calls `ensure_launcher_shortcuts()`. That function recursively calls the step before it, so the steps run in the order below (`OD:ou_dedetai/installer.py`):

| # | Step | What it does |
|---|------|--------------|
| 1 | `ensure_choices` | Asks the user for product (Logos/Verbum), version ("10" only), release, install dir and wine binary |
| 2 | `ensure_install_dirs` | `mkdir -p $INSTALL/data/bin` and the prefix dir |
| 3 | `ensure_sys_deps` | Installs distro packages (skipped when `SKIP_DEPENDENCIES` is set). Lists are in `system.py` ~L433-620, e.g. Debian: `binutils wget winbind p7zip-full cabextract xdg-utils mesa-utils libfuse*` |
| 3b | `check_system_compatibility` | `check_for_known_bugs` (issue #435 browser check) and an OpenGL check (`glxinfo`, needs OpenGL ≥ 3.2, `system.py:377`). The OpenGL check runs only for the AppImage / Recommended / Beta choices |
| 4 | `ensure_appimage_download` | Downloads the "Recommended" or "Beta" Wine AppImage (see 1.2) |
| 5 | `ensure_wine_executables` | Copies the AppImage into `data/bin` and creates the symlinks `selected_wine.AppImage`, `wine`, `wine64`, `wineserver`, `winetricks` pointing at it (`installer.py:464-505`) |
| 6 | `ensure_winetricks_executable` | Symlinks winetricks to the AppImage, or downloads winetricks **20250102** from `https://codeload.github.com/Winetricks/winetricks/zip/refs/tags/20250102` (`system.py:977-1021`, `constants.py:91`) |
| 7 | `ensure_product_installer_download` | Downloads the MSI (see 1.5) |
| 8 | `ensure_wineprefix_init` | Runs `wineboot --init` with `WINEDLLOVERRIDES` extended by `;mscoree=` ("Avoid wine-mono window"). Only runs when `$WINEPREFIX/system.reg` is missing. Then `wineserver -w` (`installer.py:307-322`, `wine.py:240-253`) |
| 9 | `ensure_wineprefix_config` | Imports three .reg files with `regedit.exe`: winemenubuilder off, renderer=gdi, RGB font smoothing (see 1.3) |
| 10 | `ensure_fonts` | Runs `winetricks -q arial` unless Arial is already registered (see 1.4) |
| 11 | `ensure_icu_data_files` | Downloads FaithLife's custom ICU build and copies it into `C:\windows` (see 1.3.4) |
| 12 | `ensure_product_installed` | `wine msiexec /i <msi> /passive [TRANSFORMS=<mst>]` (see 1.5) |
| 13 | `ensure_config_file` | No-op status step |
| 14 | `ensure_launcher_executable` | Copies the `oudedetai` binary into the install dir (binary runmode only) |
| 15 | `ensure_launcher_shortcuts` | `.desktop` files and the `logos4:` / `libronixdls:` URL-scheme handler, registered via `xdg-mime` (see 1.7) |

Default layout (`config.py:465`, `config.py:808`, `constants.py:65-75`):
- **Install dir:** `$XDG_DATA_HOME/FaithLife-Community/oudedetai`, i.e. `~/.local/share/FaithLife-Community/oudedetai`.
- **Prefix:** `$INSTALL/data/wine64_bottle`.
- **Download cache:** `$XDG_CACHE_HOME`, falling back to `~/.cache/FaithLife-Community`. Quirk: when `XDG_CACHE_HOME` is set, the path has no `/FaithLife-Community` suffix (`constants.py:65`).
- **Config:** `~/.config/FaithLife-Community/oudedetai.json`.
- **Wine log:** `~/.local/state/FaithLife-Community/wine.log`, rotated to `wine.1.log` on each app launch.
- **Prefix architecture:** the prefix is always 64-bit, created by a 64-bit `wine`. `config.py:987-1035` prefers `wine64` next to `wine`. Otherwise it uses `wine` after checking with `file -bL` that it is a 64-bit ELF; a 32-bit-only wine is a hard error.

### 1.2 Wine version, flavor, minimums, blacklist

**Default: FaithLife's own Wine AppImage.**
- **Where it comes from:** "Recommended" and "Beta" are both resolved through the GitHub API at `https://api.github.com/repos/FaithLife-Community/wine-appimages/releases` (`network.py:291-293`, `network.py:613-652`).
- **How a release is picked:** releases are sorted by `updated_at`, newest first. "Beta" is the newest release if it is a pre-release. "Recommended" is the newest non-pre-release. The download is the **first asset's** `browser_download_url`. Results are cached for 12 h in `network.json`.
- **Current state of that repo (queried 2026-10-04):**
  - **Recommended = `10.8-staging`** → `https://github.com/FaithLife-Community/wine-appimages/releases/download/10.8-staging/wine-staging_10.8-x86_64.AppImage` (240,103,768 bytes, dated 2025-05-29).
  - **Beta = `10.13-devel`** (pre-release) → `.../10.13-devel/wine-devel_10.13-x86_64.AppImage` (sha256 `9705414e72a7c41fa480e925c3de9eba36c48c3681c83159565359061aec6117`).
  - Older releases: 10.5-staging, 10.0-stable, 10.0-rc5-staging, 9.19-devel.
- **Origin of the builds:** each release body says "From https://github.com/mmtrt/WINE_AppImage/. Because the above repo overwrites its AppImages with the latest Wine bi-weekly release, we have to store our own copies." In other words, these are re-hosted copies of mmtrt's AppImages, not FaithLife builds.
- **Automatic switch to Beta:** if the default `https` handler is Chromium-based, or is a snap/flatpak browser, the installer silently moves the user from Recommended to Beta. The reason is issue #435 (`installer.py:78-161`).
- **Snap and Flatpak use different Wine:** the snap bundles `sil-car/wine-builds` wine 10.6 (`snap/snapcraft.yaml:88-90`). The Flatpak is based on `org.winehq.Wine` `stable-24.08` and uses `/app/bin/wine64` (`io.github.FaithlifeCommunity.OuDedetai.yml`).

**Version rules** are in `check_wine_rules()` (`wine.py:124-206`). Ou Dedetai enforces them for system wines and again before every launch (`logos.py:174-180`).
- **Minimum** for Logos 10 releases ≥ 30.0.0.0: **Wine 9.10**. Older releases: 7.18 (`wine.py:132-136`).
- **Rules for major 7:** proton=True, staging only. Proton is exempt from the minor-version minimum.
- **Rules for major 8:** `minor_bad=[0]`, so **8.0 is blacklisted**. Staging is allowed; devel only from 8.16.
- **Rules for major 9:** devel or staging. A 9.x "stable" (9.0) is rejected, and is below the minimum anyway.
- **Rules for major 10:** stable, devel or staging are all fine.
- **Major 11 and later:** no rule matches, so the check returns `True`. **Wine 11.x passes**; there is no upper bound and no rule for 11.
- **Branch detection:** the branch comes from `wine --version`, e.g. `wine-11.18 (Staging)` gives `staging`. With no suffix, `x.0` counts as stable and any other `x.y` as devel (`wine.py:65-112`). The source says: "Does not check for Staging. Will not implement".
- **User-facing description** (`utils.py:176-178`): "WINE must be 7.18-staging or later, or 8.16-devel or later, and cannot be version 8.0." That text is outdated; the code minimum is 9.10.
- **System-wine discovery** only looks for an executable named **`wine64`** on `PATH` (`utils.py:459-495`). nixpkgs' `wineWow64Packages` ships only `wine` (see §5). This doesn't matter for a custom launcher, but OD's own picker won't list a Nix wine unless `WINE_EXE` is set. OD's `shell.nix` does exactly that with `WINE_EXE="$(which wine)"`.

### 1.3 Registry / winecfg / DLL overrides actually applied (current main)

**All of OD's prefix configuration.** Nothing else is written. Each item is a REGEDIT4 file imported with `wine regedit.exe <file>`, followed by `wineserver -w` (`wine.py:332-353`, called from `installer.py:325-341`):

1. **Disable winemenubuilder** (`wine.py:356-363`):
   ```
   [HKEY_CURRENT_USER\Software\Wine\DllOverrides]
   "winemenubuilder.exe"=""
   ```
2. **Direct3D renderer = gdi** (`wine.py:366-373`). This effectively disables wined3d 3D. WPF falls back to software rendering (**UNVERIFIED** inference about the WPF behaviour).
   ```
   [HKEY_CURRENT_USER\Software\Wine\Direct3D]
   "renderer"="gdi"
   ```
3. **Font smoothing = RGB**, equivalent to `winetricks fontsmooth=rgb` (`wine.py:376-393`):
   ```
   [HKEY_CURRENT_USER\Control Panel\Desktop]
   "FontSmoothing"="2"
   "FontSmoothingGamma"=dword:00000578
   "FontSmoothingOrientation"=dword:00000001
   "FontSmoothingType"=dword:00000002
   ```
4. **ICU data files** (`wine.py:672-698`). This is not a registry change.
   - **Source:** the newest release from `https://api.github.com/repos/FaithLife-Community/icu/releases`, currently tag **`72.1-custom+4`** → `https://github.com/FaithLife-Community/icu/releases/download/72.1-custom%2B4/icu-win.tar.gz` (16,643,352 bytes, sha256 `2813ea1205fcf9d9a7930339dae181dc3e299b2391f2f4879c5e542be43f3a7f`, which I computed). The release note says: "Fixes bug generating x86 binaries, and forwarding dlls. This (besides some locales missing) is very close to what windows ships".
   - **Tarball contents:** `./windows/system32/{icu,icuin,icuuc}.dll`, `./windows/syswow64/{icu,icuin,icuuc}.dll` and `./windows/globalization/ICU/{icudtl.dat,metaZones.res,timezoneTypes.res,windowsZones.res,zoneinfo64.res,LICENSE-ICU.txt}`.
   - **Install:** OD untars it into `drive_c` and then copies `drive_c/icu-win/windows` over `drive_c/windows`. Because the tarball's top level is `./windows/`, the files land directly in `drive_c/windows/...`.
   - **Why it's needed:** Wine has no `icu.dll` ([WineHQ bug 53354](https://bugs.winehq.org/show_bug.cgi?id=53354), still open), and Logos (.NET) needs it.

**Not applied by default on current main:**
- **Windows version.** OD relies on Wine's default, which is **win10, build 19045**. Source: `dlls/ntdll/version.c` at wine-11.0, L169-171 and L484 (https://gitlab.winehq.org/wine/wine/-/raw/wine-11.0/dlls/ntdll/version.c). The Logos release feed says `<logos:minimum-os-version>10.0.19041</logos:minimum-os-version>`, so the default satisfies it.
  - The optional TUI menu "Set Windows version for Logos" runs `wine winecfg /v <ver>`.
  - "…for Indexer" runs `wine reg add "HKCU\Software\Wine\AppDefaults\LogosIndexer.exe" /v Version /t REG_SZ /d <ver> /f` (`wine.py:256-283`, `tui_app.py:582-591`).
- **No `Direct2D` / `max_version_factory`** key, **no `LogPixels`/DPI**, **no `mshtml` override**, **no esync/fsync/ntsync** variables, **no DXVK**, **no winewayland**, and **no `Control Panel\Colors`**. `grep` of the whole `ou_dedetai/` tree finds none of these. The TUI offers "Choose Renderer: gdi/gl/dxvk/vulkan", but that only rewrites the `Direct3D\renderer` value.

**History.** Until commit `667c730` (2025-01-22, "remove winetricks commands from install"), the installer also ran:
- winetricks `corefonts`, `tahoma` and `d3dcompiler_47` (giving the override `"*d3dcompiler_47"="native"`);
- `settings win10`;
- the `AppDefaults\LogosIndexer.exe` `Version=win10` key.

Commit `df7505b` (2024-09-02) notes "Revert Indexer from Vista to Windows 10. Vista prevents it from running." All of those steps were dropped as unnecessary. Only arial came back, via #347/#335 in beta.9: "Fixes crash in 'Copy Bible Verse' and when first hitting 'Continue' due to missing arial font".

### 1.4 Fonts

**Only Arial is installed** (`wine.py:459-485`):
1. OD queries `HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts` for the value `Arial (TrueType)`.
2. If the value exists and is **not** `arial.ttf`, Arial is already provided by another source (e.g. a system font that Wine registered with a `Z:\...` path), and OD skips it.
3. If the value is `arial.ttf` and `drive_c/windows/Fonts/arial.ttf` exists, OD skips it.
4. Otherwise it runs `winetricks -q arial`.

What `winetricks arial` does in winetricks 20250102 (`src/winetricks` L13824-13847, https://raw.githubusercontent.com/Winetricks/winetricks/20250102/src/winetricks):
- downloads `https://github.com/pushcx/corefonts/raw/master/arial32.exe` (sha256 `85297a4d146e9c87ac6f74822734bdee5f4b2a722d7eaa584b7f2cbf76f478f6`) and `arialb32.exe` (sha256 `a425f0ffb6a1a5ede5b979ed6177f4f4f4fdef6ae7c302a7b7720ef332fec0a8`);
- cabextracts `Arial*.TTF` and `AriBlk.TTF` into `C:\windows\Fonts`;
- registers `Arial`, `Arial Bold`, `Arial Italic`, `Arial Bold Italic` and `Arial Black` with `w_register_font`.

**NixOS-specific.** `winetricks -q arial` failed on NixOS (issue #387). PR #413 (commit `5841f8d`) added `pkgs.corefonts` and `allowUnfree` to OD's `shell.nix`.

**For a Nix launcher:** copy the TTFs from `pkgs.corefonts` into `drive_c/windows/Fonts` and register them. This replaces winetricks and needs no network access.
- **File names differ from winetricks'.** I checked `corefonts-1` from nixos-26.05 (`/nix/store/jjmkxbmbi22fz5rl4im2k1qwq74kx8mv-corefonts-1/share/fonts/truetype/`). It contains `Arial.ttf`, `Arial_Bold.ttf`, `Arial_Italic.ttf`, `Arial_Bold_Italic.ttf` and `Arial_Black.ttf`.
- **Use winetricks' names in the prefix.** Copy them as `arial.ttf`, `arialbd.ttf`, `ariali.ttf`, `arialbi.ttf` and `ariblk.ttf`, so OD's `"Arial (TrueType)"="arial.ttf"` check (and winetricks) would also see them as installed.
- **Register** them under `HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts` with a .reg file: `"Arial (TrueType)"="arial.ttf"`, `"Arial Bold (TrueType)"="arialbd.ttf"`, `"Arial Italic (TrueType)"="ariali.ttf"`, `"Arial Bold Italic (TrueType)"="arialbi.ttf"`, `"Arial Black (TrueType)"="ariblk.ttf"`. This matches what `w_register_font` writes (winetricks 20250102 L2769-2798). winetricks also writes the same values to `HKLM\Software\Microsoft\Windows\CurrentVersion\Fonts`.
- **UNVERIFIED alternative:** Wine scans `windows/Fonts` itself, so the copy alone may be enough.

### 1.5 Finding and installing the Logos MSI

**1. Release feed** (`network.py:667-709`):
- Stable: `https://clientservices.logos.com/update/v1/feed/logos10/stable.xml` (the URL is built from `logos{version}`, and version is always `10`).
- Beta: `https://clientservices.logos.com/update/v1/feed/logos10/beta.xml`.
- The feed is an Atom feed. OD parses it with ElementTree using namespaces `ns0=http://www.w3.org/2005/Atom` and `ns1=http://services.logos.com/update/v1/`. It collects every `.//ns1:version` text, decoding as `utf-8-sig` because the feed has a BOM. The **first entry is the newest** (`utils.py:546-556`: "feed is ordered newest-first").
- The feed checked on 2026-10-04 lists, newest first, `53.1.0.0002` (updated 2026-08-26), `52.2.0.0019`, `52.1.0.0002`, `52.0.0.0307`, `51.1.0.0003` … down to `30.1.0.0038`.
- Each entry has `<link href=…/LogosSetup.exe>`, `…/Logos4UpdateScript.lbxdat`, `…/Logos-x64.msi` and `<logos:minimum-os-version>10.0.19041</logos:minimum-os-version>`.
- The beta feed currently tops out at 51.0.0.0237, i.e. it is stale.
- `logos11/stable.xml` and `logos12/stable.xml` return **404**. The feed and installer path are still "LBS10" / "logos10", even though the app's release numbers are now 53.x.

**2. MSI URL** (`config.py:779-783`):
```
https://downloads.logoscdn.com/LBS10/Installer/{release}/Logos-x64.msi
# Verbum: https://downloads.logoscdn.com/LBS10/Verbum/Installer/{release}/Verbum-x64.msi
```
- Example: `https://downloads.logoscdn.com/LBS10/Installer/53.1.0.0002/Logos-x64.msi`. A HEAD request on it returned HTTP 200 with `content-length: 481976320`, `etag: "25e8af73f66fdfffff1e2cfba5da45af"`, `server: AmazonS3` and `accept-ranges: bytes`.
- The local file is named `Logos_v{release}-x64.msi` (`config.py:773-776`).
- **Integrity check:** OD compares the size to `Content-Length`, and the MD5 to the S3 `etag`, which it treats as a hex MD5 and base64-encodes (`network.py:120-134`, `network.py:571-584`). Downloads resume with `Range` when possible.
- `logos_reuse_download` first looks in `~/Downloads` (the XDG user download dir) and the cache dir for an already-verified file.

**3. msiexec command line** (`wine.py:396-436`):
```
WINEPREFIX=... wine msiexec /i "$INSTALL/data/Logos_v53.1.0.0002-x64.msi" /passive TRANSFORMS=<winepath -w of LogosStubFailOK.mst>
```
- The `/i` path is a Unix path. Wine's msiexec accepts it.
- `/passive` is added once the user has agreed to the EULA (https://faithlife.com/terms). The code comment says interactive runs sometimes didn't launch, and the only prompts are the EULA and a pointless install location.
- `TRANSFORMS=` is added **only when the release is > 39.0.0.0**. The MST is `ou_dedetai/assets/LogosStubFailOK.mst`: 20,480 bytes, MIT-licensed repo, sha256 `11877bdedafb080b358cb5da16e016de59c4668c91e01880f4009dcf18a95a87`. PR #263 (commit `eb6f604`, 2025-01-23) says: "modifies 4 attributes of the msi installer… allowing the LogosStub install to fail because it is in msix format and isn't needed at runtime on linux. LogosStub just forwards ref.ly urls". The MST's strings reference the custom actions `RegisterStubMsixPackage(Props)` and `RegisterSparseMsixPackage(Props)`. Without it, msiexec fails on Logos 39+.
- The process is waited on, and a non-zero exit is fatal. OD reinstalls only when nothing is installed or the target release differs from the installed one.
- **Installed version detection** (`utils.py:143-161`): read `AppData/Local/Logos/System/Logos.deps.json`, look under `libraries` for the key `Logos/<version>`, and take `<version>`. The installed form is unpadded, e.g. `51.1.0.3` versus the feed's `51.1.0.0003`.

### 1.6 Install location and launching

The MSI is a **per-user** install. The MST summary info says "This is a per-user installation". Paths (`config.py:491-498`, `config.py:1200-1262`):
- **App dir:** `$WINEPREFIX/drive_c/users/<wineuser>/AppData/Local/Logos/`. `<wineuser>` is the first non-`Public` dir under `drive_c/users`, normally `$USER`.
- **Executables:**
  - `…/Logos/Logos.exe` — the launcher/splash (`logos_exe`, a Unix path).
  - `C:\users\<u>\AppData\Local\Logos\System\Logos.exe` — the main process ("login" state).
  - `C:\users\<u>\AppData\Local\Logos\System\LogosIndexer.exe` — the indexer.
  - `C:\users\<u>\AppData\Local\Logos\System\LogosCEF.exe` — embedded Chromium. OD only watches this process to detect "running"; it passes it no flags.
- **Data:** `…/Logos/Data/<userid>/`, `…/Logos/Documents/<userid>/`. `<userid>` is the first subdirectory of `Data/`.
- **Logs:** `AppData/Local/Faithlife/Logs/Logos/` (e.g. `LogosCrash.log`).

**Launching Logos** (`logos.py:155-201`):
1. Run the wine version-rule check, then `wineserver -k`.
2. Start a thread that edits Logos' SQLite DBs (§1.8).
3. Run `wine "<prefix>/drive_c/users/<u>/AppData/Local/Logos/Logos.exe"` with **WINEDEBUG=`err+all`** (`constants.py:80`). With `--debug` it becomes `err+all,+loaddll,+pid,+threadname` (`main.py:226-229`). **WINEDLLOVERRIDES** is empty by default (`config.py:1114-1119`). stdout and stderr go to `wine.log`.

**The full launch environment** (`wine.py:738-761`) is: `WINE` and `WINELOADER` (path to wine64/wine), `WINEDEBUG`, `WINEDLLOVERRIDES`, `WINEPREFIX` and `WINESERVER`. That is all: **no** `WINEESYNC`, `WINEFSYNC`, `WINE_DISABLE_FAST_SYNC`/ntsync, `DXVK_*` or `WAYLAND_DISPLAY` handling. `LD_LIBRARY_PATH` is only scrubbed of PyInstaller paths.

**Indexing** (`logos.py:303-350`): run `wineserver -k`, then `wine 'C:\users\<u>\AppData\Local\Logos\System\LogosIndexer.exe'`, waiting until it exits (then `wineserver -w`). "Remove all index files" (`control.py:26-47`) deletes the contents of `Data/*/{BibleIndex,LibraryIndex,PersonalBookIndex,LibraryCatalog}/`. "Remove library catalog" deletes `Data/*/LibraryCatalog/*`.

**Stopping** sends `kill -9` to every Logos, System\Logos, Indexer and CEF PID it knows (`logos.py:267-290`).

**Logos' own logging toggle:** `reg add HKCU\Software\Logos4\Logging /v Enabled /t REG_DWORD /d 0001|0000 /f` (`logos.py:392-427`).

### 1.7 Login: the `logos4:` URL scheme (required for Logos ≥ 40.1)

Logos 40.1 and later sign in through the system browser via OAuth and return through a `logos4:` URL. PR #401 (commit `3d84868`, 2025-08-24, released in beta.12 as "supports the Logos 41+ login flow") added a desktop file for it (`installer.py:622-673`):

```
[Desktop Entry]
Name=Logos URL Handler
Type=Application
Exec=/bin/sh -c "(<oudedetai> --wine 'C:\\users\\<u>\\AppData\\Local\\Logos\\Logos.exe' ''%u'') || (echo '...'; sleep 60; exit 1); wait"
MimeType=x-scheme-handler/logos4;x-scheme-handler/libronixdls
Terminal=true
```

It then runs `xdg-mime default Logos-url-handler.desktop x-scheme-handler/logos4` (and the same for `libronixdls`) and `update-desktop-database`. In effect, the browser's redirect runs `wine 'C:\…\Logos.exe' '<logos4:… url>'` in the same prefix and environment, which hands the token to the running Logos.

**For a Nix flake:** ship a desktop entry with `MimeType=x-scheme-handler/logos4;x-scheme-handler/libronixdls;` whose Exec calls your launcher with `%u`. Logos opens the browser through Wine's `winebrowser`, which uses `xdg-open`.
- **Avoid `Terminal=true`.** Issue #438 shows that when no terminal emulator is installed (Hyprland, Sway), the redirect silently does nothing. Users fixed it by installing xterm or xfce4-terminal.
- **Issue #435** (open): "Sign In" does nothing when the default browser is Chromium-based or a snap/flatpak. Their notes say it was introduced in wine-staging after 10.6 and before 10.8, and was fixed in wine devel by Aug 2025. Workarounds:
  - `wine reg add "HKCU\Software\Wine\WineBrowser" /v Browsers /d "firefox" /f`;
  - make Firefox the system default;
  - for flatpak browsers, a `firefox` wrapper script on `PATH` that does `flatpak run org.mozilla.firefox "$@"`.
- **Fallback flow** from OD's "Trouble Signing In?" pop-up (`logos.py:136-152`): on the browser page, click the link for not being redirected automatically, then the "still having trouble" link.

### 1.8 Post-install / runtime fixes

- **App self-updates are disabled.** On every launch a background thread watches `AppData/Local/Logos/Data/<uid>/UpdateManager/Updates.db` with inotify, including `-wal`/`-shm`, and re-runs this SQL after each write (`logos.py:225-257`, `database.py:98-152`):
  ```sql
  DELETE FROM UpdateUrls WHERE UpdateId IN (SELECT UpdateId FROM Updates WHERE Source='Application Update');
  DELETE FROM Updates WHERE UpdateId NOT IN (SELECT UpdateId FROM UpdateUrls) OR Source='Application Update';
  UPDATE Resources SET Status=1, UpdateId=NULL WHERE UpdateId IS NOT NULL AND UpdateId NOT IN (SELECT UpdateId FROM Updates);
  ```
  This exists because in-app updates crash or break the install. Issue #275: "Attempting to download updates or enable auto-updating crashes Logos". `repair.py` detects a failed in-app upgrade as `System/Logos.exe` present but top-level `Logos.exe` missing, and repairs it by re-running the MSI install with the latest release.
  - **Updating Logos = run a newer MSI over the prefix.** The "Update Logos" button (beta.14, `utils.py:546-556`) takes `releases[0]` from the feed and re-runs `install()`.
- **Resource auto-download is forced off.** The same watcher runs on `AppData/Local/Logos/Documents/<uid>/LocalUserPreferences/PreferencesManager.db` (`logos.py:206-223`):
  ```sql
  UPDATE Preferences SET Data='<data OptIn="false" StartDownloadHour="0" StopDownloadHour="0" MarkNewResourcesAsCloud="true" />' WHERE Type='UpdateManagerPreferences'
  ```
- **`wineserver -k`** runs before every Logos and indexer start.
- **Download reuse:** `logos_reuse_download` checks `~/Downloads` and the cache for a file that passes the size and MD5 checks before downloading.
- **First-run crash:** the Flatpak entrypoint has the comment "Run Logos after installing since it crashes once while downloading resources. Opening it again recovers". `repair.py` also flags a stuck `FirstRunDialogWizardState="ResourceBundleSelection"` as a failed resource download.
- **Backups** (`backup.py`) copy `Data/` and `Documents/`. No Wine changes are involved.

### 1.9 Wayland / HiDPI / multi-monitor in the source

Nothing. The only hit is `control.py:170-200`, which records `XDG_SESSION_TYPE`, `DISPLAY`, `XDG_CURRENT_DESKTOP` and similar in the support zip. There is no `winewayland` driver selection (`HKCU\Software\Wine\Drivers` "Graphics"), no `LogPixels`, and no multi-monitor handling. See §4 for user reports.

---

## 2. Dark mode and theming

### 2.1 Logos version naming in 2026
- **No "Logos 11".** Faithlife no longer uses major version numbers in marketing. Releases are monthly, e.g. "What's New in Logos? April 2026" (https://www.logos.com/grow/release-april-2026/), and subscription tiers have existed since October 2024 (https://en.wikipedia.org/wiki/Logos_Bible_Software).
- **Build numbers keep climbing.** The current stable is **53.1.0.0002** (released 2026-08-26, per the feed in §1.5). The update feed and CDN paths are still `logos10` / `LBS10`, and `logos11` / `logos12` feeds return 404. OD and users still call the product "Logos 10" (`FAITHLIFE_PRODUCT_VERSIONS = ["10"]`, `constants.py:102`).
- A Faithlife PM, 2025: "In a normal launch year, you'd have to wait until the launch of L11…" (archived thread: https://web.archive.org/web/20251007142636/https://community.logos.com/discussion/221564/new-feature-instant-dark-light-mode).

### 2.2 Logos' in-app theme
**Light/Dark theme (verified).** Logos Desktop has an **Application Theme** setting with Light and Dark.
- **Where to set it:** toolbar → ⋯ (more actions) → *Application Theme*, or type the command `Set Application Theme to Dark`.
- **Who gets it:** "available to all users only on Logos Desktop", so the free Basic tier has it. F4 toggles it for subscribers.
- **Sources:** https://support.logos.com/hc/en-us/articles/360029535791-Theme-Switching-in-Logos. A November 2025 forum answer says free users can switch to dark but must restart Logos (https://web.archive.org/web/20251216005055/https://community.logos.com/discussion/254006/free-edition-dark-mode).
- Instant switching without a restart reportedly reached everyone in "version 52". **UNVERIFIED:** that comes from a search snippet of community topic 237402, and the page is Cloudflare-blocked.

**"Follow system" option: UNVERIFIED / probably absent.** The official help article lists only Light and Dark.

**Registry value Logos reads: UNVERIFIED.** I found no evidence that Logos reads `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme`.
- Logos most likely stores the choice in its own preferences, i.e. the SQLite `PreferencesManager.db` under `Documents/<uid>/LocalUserPreferences/`. That is an inference.
- **Don't plan on seeding the theme declaratively before first login.** The user picks it once in-app.
- Setting `AppsUseLightTheme=0` is harmless and may help if a future Logos follows the OS (see 2.4).

### 2.3 Does Logos dark mode work under Wine?
**UNVERIFIED.** There are no reports either way in the OD issues or discussions; searches for "dark", "theme" and "AppsUseLightTheme" turned up nothing.

Logos draws its own UI (WPF/.NET plus bundled CEF), so its in-app theme should not depend on Wine's theming. That is an inference.

### 2.4 Theming Wine's own chrome and common dialogs dark
Sources below are Wine master on gitlab.winehq.org; the current release is 11.19 (2026-10-02).

**Built-in msstyles.**
- **History:** `light.msstyles` was added in Wine 6.12 (commit `f42158b62f`, 2021-06-23). It was renamed to **`aero.msstyles`** in Wine 11.3 (commit `d684f92deb`, "dlls: Rename light.msstyles to aero.msstyles", 2026-02-06).
- **No dark variant upstream.** The only color variant is **"Blue"** (`dlls/aero.msstyles/aero.rc`).
- **Defaults on current master**, which I re-checked in https://gitlab.winehq.org/wine/wine/-/raw/master/loader/wine.inf.in L1029-1033:
  ```
  [ThemeManager]
  HKCU,"Software\Microsoft\Windows\CurrentVersion\ThemeManager","ThemeActive",2,"1"
  HKCU,"Software\Microsoft\Windows\CurrentVersion\ThemeManager","DllName",2,"%10%\resources\themes\aero\aero.msstyles"
  HKCU,"Software\Microsoft\Windows\CurrentVersion\ThemeManager","ColorName",2,"Blue"
  HKCU,"Software\Microsoft\Windows\CurrentVersion\ThemeManager","SizeName",2,"NormalSize"
  ```
- On Wine **11.0** (nixpkgs `stable`), `DllName` is still `…\themes\light\light.msstyles`. On 11.8 / 11.18 (`staging` / `unstable`) it is `…\aero\aero.msstyles`.

**winecfg "App theme: Light/Dark".**
- **What it writes:** added in Wine 8.5 (commit `3503ab4e94`). Since Wine 8.18 (commit `26471dd00e`) it writes REG_DWORD `AppsUseLightTheme` and `SystemUsesLightTheme` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, with 0 meaning dark (`programs/winecfg/theme.c` L422, L500-502, re-checked).
- **Who reads it:** uxtheme's `ShouldAppsUseDarkMode` / `ShouldSystemUseDarkMode` (`dlls/uxtheme/system.c`) report these values to apps that ask.
- **It does not recolor** Wine's comctl32 controls or common dialogs. That is inferred from source.

**Darkening Wine's own widgets.** Use the system colors under `HKCU\Control Panel\Colors`.
- **Format:** REG_SZ `"R G B"`, the same as winecfg's `save_sys_color`.
- **Valid names:** `ButtonFace ButtonText Background Menu MenuText Scrollbar Hilight HilightText InfoWindow InfoText Window WindowText ActiveTitle TitleText InactiveTitle InactiveTitleText AppWorkSpace WindowFrame ActiveBorder InactiveBorder ButtonShadow GrayText ButtonHilight ButtonDkShadow ButtonLight ButtonAlternateFace HotTrackingColor GradientActiveTitle GradientInactiveTitle MenuHilight MenuBar`.
- **Turn the msstyles theme off.** An active theme applies its own `[SysMetrics]` colors, so set `ThemeManager\ThemeActive="0"` (and/or an empty `DllName`) for custom colors to stick. Inferred from `dlls/uxtheme/system.c`; **UNVERIFIED** by test.
- **Palette:** no dark palette ships upstream, so the RGB values are your design choice.

**Title bars and window frames.** Under X11, XWayland or winewayland the host compositor or WM draws them, so they follow the desktop theme, not Wine's registry.

**Suggested declarative .reg for "dark":**
- `Personalize\AppsUseLightTheme=dword:0` and `SystemUsesLightTheme=dword:0`;
- `ThemeManager\ThemeActive="0"`;
- a dark `Control Panel\Colors` set.

This only affects Wine-drawn UI such as msiexec progress, file dialogs and message boxes. Logos' own UI uses its in-app theme.

---

## 3. Logos system requirements (2026) and WebView2

**Source:** https://support.logos.com/hc/en-us/articles/360007506971-Logos-Minimum-System-Requirements (fetched 2026-10-04).

**Operating system.** The official text says "Windows 11 (Version 24H2 and newer)". Windows 10, 32-bit Windows and ARM are listed as not compatible.
- Windows 10 grace period: "it will be possible to install new versions of Logos on Windows 10 for a limited time after October 14, 2025… We expect new versions of Logos to be able to be installed on Windows 10 into 2026". Faithlife promises at least 12 weeks' notice before ending it.
- "If your version of Windows is not supported, Logos will notify you, and the automatic update will not be installed."

**Hardware:** 4 GB RAM, 1280×768, 30 GB free disk, broadband.

**What actually gates install today.** The feed's `<logos:minimum-os-version>10.0.19041</logos:minimum-os-version>` (§1.5).
- Wine's default `win10` reports 10.0.19045, which passes. Fresh installs of 53.1 on Wine's win10 default are reported working in September 2026 (OD #493, #497).
- **Future risk:** Wine's `win11` reports only 10.0.**22000** (21H2), so neither Wine preset satisfies "24H2" (build 26100).
  - If the feed's minimum rises to 26100, you would need to fake the build number: `HKLM\Software\Microsoft\Windows NT\CurrentVersion` `CurrentBuild` / `CurrentBuildNumber`, or a custom Wine version. **UNVERIFIED** that Logos reads those keys rather than `RtlGetVersion`.
  - OD has no build-faking code; a grep for `CurrentBuild`, `19045` and `22000` finds nothing.
  - OD discussion #391 already mentions a "windows not being up to date" error under Bottles/Proton.

**.NET:** none needed separately. Logos ships its own runtime.
- Crash logs show ".NET Framework Version: 8.0.10/8.0.11" with `Install path: C:\users\<u>\AppData\Local\Logos\System\Logos.dll` (OD #262, #290).
- OD installs no dotnet verb. That the runtime is bundled self-contained is an inference; I did not check inside the MSI.
- Wine-mono is not needed; OD suppresses it with `mscoree=` at `wineboot`.

**WebView2: not required, as far as the evidence shows.**
- The requirements page doesn't mention it.
- `grep -ri webview` over the OD source and wiki finds nothing, so OD does nothing for WebView2.
- Logos embeds its own Chromium as `System\LogosCEF.exe` (`config.py:1245-1249`).
- Login uses the **system browser** plus the `logos4:` callback (§1.7), not an embedded webview.

**Gecko / mshtml:** OD doesn't touch them. The wiki's sanity test uses `WINEDLLOVERRIDES='mscoree,mshtml='` (`Troubleshooting.md` in the wiki at `2c519bd`). With nixpkgs `*Full`, gecko is embedded anyway.

---

## 4. Known breakages and workarounds (2025-2026)

Numbers refer to issues/PRs at https://github.com/FaithLife-Community/OuDedetai. The wiki is `LogosLinuxInstaller.wiki.git` at `2c519bd` (2026-02-17).

### Login / sign-in
- **#400** (closed; fixed in beta.12 by PR #401): the browser opens, but the redirect never reaches Logos.
  - Fix: a `logos4:` handler (§1.7).
  - Manual fallback: on the "Redirecting you to Logos" page click "click here to try again", then "Still having trouble? Click here…". You may need to do this 2-3 times. Since beta.14, OD shows a pop-up with these steps (commit `2418eec`, #449).
- **#435** (open, a Wine bug): "Sign In" does nothing when the default browser is Chromium-based or a snap/flatpak browser. Regressed in wine-staging 10.6→10.8. Workarounds:
  - `wine reg add "HKCU\Software\Wine\WineBrowser" /v Browsers /d firefox /f`;
  - a native Firefox as the default browser;
  - a `firefox` wrapper on `PATH` for flatpak browsers.
- **#438** (open): with `Terminal=true` in the handler `.desktop` and no terminal configured, the callback silently fails. **Use `Terminal=false` in your handler.**

### Rendering / performance (the biggest everyday complaint)
- **Slow, laggy UI** (#79 open, #444, #391, #453). Cause: OD's `renderer="gdi"` makes Logos render on the CPU, and the log line "Disabling 3D support" is expected.
  - `renderer=gl` helps but causes flicker and black windows (#444).
  - **DXVK is the reported fix** (#493, Discussion #494):
    1. run `winetricks -q dxvk`;
    2. run `wine reg delete 'HKCU\Software\Wine\Direct3D' /v renderer /f`;
    3. keep Logos' own "Enable Hardware Acceleration" on.
  - That was tested on wine-staging 10.8 (wow64) with DXVK 3.1. Side effect: a black strip on Information tooltips; you can turn off "Show Information Tooltips".
  - In nixpkgs, `pkgs.dxvk` exists. **UNVERIFIED** which version, and how best to install it into a prefix without winetricks. One option: copy `d3d9/d3d10core/d3d11/dxgi.dll` into `system32` and set `DllOverrides` to `native`.
  - **Source caveat:** OD's TUI "dxvk" renderer choice (PR #498, `acbb557`) just writes `renderer="dxvk"`. wined3d accepts only `vulkan`, `gl` and `gdi`/`no3d` (`dlls/wined3d/wined3d_main.c` ~L459-476), so that choice does **not** install DXVK; it falls back to the default (GL).
  - Lowering the resolution helps on 4K (#444, #391).
- **#443:** OpenGL ≥ 3.2 is required, otherwise Logos crashes silently. That is why OD checks `glxinfo` (PR #389).
- **#410** (open, a Wine regression): resource panels have loaded slowly since Wine 10.5/10.6.
- **#497** (open PR): black frames around popups on Hyprland/Sway. XWayland ignores the XShape that Wine applies since 9.12 (commit `0931c2a4`). The PR adds an `LD_PRELOAD` shim. GNOME and KDE are fine.
- **#448:** the tray icon appears in its own Wine window on Plasma. It is a Wine issue.

### Memory / CPU / hangs
- **#452** (open): each UI panel spawns a CEF process of about 250 MB (WineHQ https://bugs.winehq.org/show_bug.cgi?id=58805).
- Related: #458 (Smart Search grinds the system), #464 (freeze after indexing on 8 GB), #460/#468 (crash or freeze during library download), Discussion #454.
  - Mitigation proposed in #457 and open PR #474: run Logos under `systemd-run --user --scope -p MemoryMax=… -p MemoryHigh=…`, with about 90% of RAM in the PR.
- **#412** (open): wineserver processes get stuck. Run `wineserver -k` for the prefix (OD does this before every launch).
- **#442:** search broken after indexing. Fixed by updating to Wine 10.18.
- **Discussion #463:** `--run-indexing` (the standalone `LogosIndexer.exe`) does not reliably replace in-app indexing.

### Crashes / functionality
- **Logos ≥ 39:** the MSI contains an MSIX `LogosStub` that Wine can't install ([WineHQ 57674](https://bugs.winehq.org/show_bug.cgi?id=57674)). Use the MST transform (§1.5; #256 → PR #263).
- **#268:** a crash in the library-download dialog with Wine 9. Fixed in Wine 10.
- **#262/#275:** the `seqUris must be non-null` crash on update or auto-update was fixed by #283. Recovery: delete `AppData/Local/Logos/{Documents,Data}/*`. OD also blocks in-app updates (§1.8).
- **#290/#296:** "Not implemented" in `LibraryCatalog.ResizeImage` (GDI+/WIC is missing in Wine) during a full library download. **Workaround: choose the minimal library download first.**
- **#295** (open): crash while scrolling the Library.
- **Menus open only once** (#193/#305/#430): resolved in Wine 10.5; #430 recommends ≥ 10.8.
- **Not working**, per the wiki page "Logos-feature-compatibility": audio/video playback, text-to-speech, printing (#173), Export to HTML (#465). RTF and Markdown export work.
- **#445** (open): the clipboard / copy button fails on Hyprland (Wine/Wayland).
- **#461** (open): stuck at the splash screen on openSUSE Tumbleweed, with an "Xlib is not thread-safe" warning.
- **First run:** Logos commonly crashes once while downloading resources; relaunching recovers (the Flatpak entrypoint comment, and PR #306 testing).

### Wayland / HiDPI / multi-monitor
- OD has no handling for any of these (§1.9).
- From the reports: Wayland desktops run Logos via XWayland. There are issues specific to wlroots compositors (#497 black popup frames, #445 clipboard, #438 terminal-less handler).
- One #400 report said the login window never appeared on X.org i3 / GNOME Classic, while Wayland worked.
- High resolutions hurt performance under the gdi renderer (#444, #391).
- **No reports found** about `LogPixels`/DPI scaling or winewayland, so **UNVERIFIED** whether `HKCU\Control Panel\Desktop\LogPixels` (DWORD, e.g. 144 for 150%) behaves well with Logos.

### Gaps
- I did not read the Telegram (https://t.me/linux_logos) or Matrix (`#logosbible:matrix.org`) channels.
- community.logos.com returns Cloudflare 403, so only Wayback snapshots were used.

---

## 5. Wine in nixpkgs (checked 2026-10-04)

**Channel heads used.** Every attribute name and version below was confirmed with `nix eval github:NixOS/nixpkgs/<rev>#<attr>.name`.
- **nixos-26.05:** `825e2028c29b702a4a5f085f08095d12099784f2` (2026-10-03).
- **nixos-unstable:** `a7868a727837f3c09cee2ce0ca671c76b1589fed` (2026-10-03).

**Where things live:**
- **Version pins:** still `pkgs/applications/emulators/wine/sources.nix`. See https://github.com/NixOS/nixpkgs/blob/a7868a727837f3c09cee2ce0ca671c76b1589fed/pkgs/applications/emulators/wine/sources.nix and https://github.com/NixOS/nixpkgs/blob/825e2028c29b702a4a5f085f08095d12099784f2/pkgs/applications/emulators/wine/sources.nix.
- **Build variants:** `packages.nix` in the same directory.
- **Named sets:** `pkgs/top-level/wine-packages.nix`.
- **Top-level wiring:** in `all-packages.nix`, `wineWow64Packages = recurseIntoAttrs (winePackagesFor "wineWow64")`.

| Attribute | nixos-26.05 | nixos-unstable | Cached on cache.nixos.org |
|---|---|---|---|
| `wineWow64Packages.stable` / `.stableFull` | wine-wow64-11.0 | wine-wow64-11.0 | yes |
| `wineWow64Packages.unstable` / `.unstableFull` | wine-wow64-11.8 | wine-wow64-11.18 | yes |
| `wineWow64Packages.staging` / `.stagingFull` | wine-wow64-staging-11.8 | wine-wow64-staging-11.18 | yes |
| `winetricks` | 20260125 | 20260125 | yes |
| top-level `wine-staging` | 32-bit `winePackages.stagingFull` (**don't use**) | same | — |

"Cached" means the `.narinfo` lookup returned HTTP 200.

**Notes:**
- **Use `wineWow64Packages.*`.** It is built with `--enable-archs=x86_64,i386`: new-style WoW64 with a single `wine` loader (`packages.nix` ~L122-150).
- **Avoid the top-level `wine` / `wine-staging`.** They come from `winePackages`, which defaults to `config.wine.build or "wine32"`, i.e. the i686 build.
- **`wineWowPackages` is deprecated.** It now warns "no longer preferred by upstream. Use wineWow64Packages instead" (`aliases.nix`). OD's own `shell.nix` still uses `wineWowPackages.full` from an old pin.
- **What "staging" is:** the unstable source with **all** wine-staging patchsets applied. The patches are fetched from `gitlab.winehq.org/wine/wine-staging` at tag `v${version}`, with `disabledPatchsets = [ ]` and `patchinstall.py --all` (`base.nix` ~L104-111, L267-272).
- **There is no `wine64` binary.** The wow64 `bin/` holds `wine wineserver wineboot winecfg msiexec regedit regsvr32 wineconsole winedbg winepath notepad …`. Call `wine`, not `wine64`.
- **Wayland driver:** built in by default (`waylandSupport = true`, together with X11). `wineRelease = "wayland"` is deprecated ("Wine now builds with the wayland driver by default", 2025-01-23).
- **Mono / Gecko** are embedded only in the `*Full` variants (`embedInstallers = true`). Gecko is 2.47.4. Mono is 10.0.0 for stable, 11.0.0 for 26.05 staging/unstable, and 11.3.0 for nixos-unstable. A `*Full` build therefore avoids network prompts for mono/gecko. Logos ships its own .NET runtime (see §3), and OD sets `mscoree=` during `wineboot --init`.
- **Does it satisfy OD's requirements?** Yes, every option does. `wine --version` on these packages prints e.g. `wine-11.18 (Staging)`. OD's rule check (§1.2) has no rule for major 11, so it passes, and 11.x is above the 9.10 minimum.
  - Issue #435 (staging regression, fixed in devel by ~10.13) should be fixed in 11.x. **UNVERIFIED** for 11.x.
  - OD itself still recommends 10.8-staging (AppImage) and offers 10.13-devel as beta. I found no upstream statement that tests Wine 11 specifically, so **UNVERIFIED** that 11.x is tested by OD maintainers.
  - **Recommendation:** `wineWow64Packages.stagingFull`, which is closest to OD's "staging" recommendation. Keep `stableFull` (11.0) as a fallback option. Pin both, with `winetricks`, from the same nixpkgs input.

---

## 6. Existing Nix packaging attempts

**Upstream issue #47, "Add Support for NixOS"** (https://github.com/FaithLife-Community/OuDedetai/issues/47). Opened 2024-01-15; closed 2025-02-10 ("Initial support merged in #306, to be enhanced later").
- One user argued for a declarative flake.
- `wine-staging-Full` plus Logos 29.x worked.
- Wine 9.3-staging crashed after the splash screen with Logos 29.1, while Proton-GE worked.
- These are all historical results.

**Branch `origin/47-nixos-support`** (commit `92608f8b`, 2024-03-05). An 8-line change to `utils.py` that blanks package-manager commands on NixOS. It is stale; the PR (#80) was closed 2024-03-12.

**PR #306, "feat: add nix-shell"** (merged 2025-02-10).
- Adds `shell.nix`, which pins nixpkgs `a45fa362…` for Python and `fa35a3c8…` for `wineWowPackages.full`.
- Its shellHook sets `WINE_EXE="$(which wine)" SKIP_DEPENDENCIES=True WINEBIN_CODE=System`. No desktop shortcuts are created.
- Testers saw a crash after "Download All Resources" that went away on relaunch.

**PR #413** (commit `5841f8d`). Adds `pkgs.corefonts` and `allowUnfree` because `winetricks -q arial` failed on NixOS (issue #387, https://github.com/FaithLife-Community/OuDedetai/issues/387#issuecomment-2780111636). One NixOS user said only copying Arial into `~/.local/share/fonts` helped.

**zachcoyle/logos.nix** (https://github.com/zachcoyle/logos.nix). HEAD `06f194274801`, last push 2024-07-11; abandoned.
- **Framework:** a flake-parts flake built on erosanix `mkWindowsAppNoCC` with `wine = pkgs.wineWow64Packages.unstableFull`. Commit `71b2558d9140` switched away from `wineWowPackages.waylandFull` with the message "use wine version that works at least through initial book download".
- **Installer:** the old `LogosSetup.exe` pinned to **29.1.0.0022** with a fixed hash, run as `$WINE start /unix ${src} /S; wineserver -w`.
- **Launch:** `$WINE start /unix "$WINEPREFIX/drive_c/users/$USER/AppData/Local/Logos/Logos.exe"`.
- **Blocker:** 34.x was commented out because of [WineHQ bug 53354](https://bugs.winehq.org/show_bug.cgi?id=53354), "Wine should provide icu.dll". OD solves this with its ICU tarball (§1.3.4).
- **Lessons:**
  - Pinning an installer hash goes stale quickly, because the feed moves about every 2-4 weeks.
  - Logos needs the ICU DLLs.
  - The EXE bootstrapper was replaced by the MSI flow plus MST for 39+.

**Searches with no results:**
- nixpkgs issues/PRs for "logos bible", "faithlife", "LogosLinuxInstaller", "oudedetai";
- NixOS Discourse;
- erosanix (`d0981311`) has no Logos package.

**UNVERIFIED:** GitHub *code* search for `.nix` files mentioning logoscdn / FaithLife-Community was rate-limited (HTTP 403). Private NixOS configs that contain a Logos module may exist.
