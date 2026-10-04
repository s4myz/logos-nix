#!/usr/bin/env bash
# logos — run Logos Bible Software in a Wine prefix managed by logos-nix.
# @placeholders@ are substituted at build time (package/default.nix).
set -euo pipefail

readonly SETUP=@setup@          # store dir: settings.reg, LogosStubFailOK.mst, …
readonly ICU=@icu@              # FaithLife's ICU build for Windows (icu.dll)
readonly FONTS=@fonts@          # corefonts TTFs
readonly DXVK=@dxvk@            # dir with x64/ and x32/ DLLs, or empty
readonly RENDERER=@renderer@
readonly THEME=@theme@
readonly ACCEPT_EULA=@acceptEula@
readonly BLOCK_APP_UPDATES=@blockAppUpdates@
readonly UPDATE_CHECK=@updateCheck@
readonly MEMORY_HIGH=@memoryHigh@
readonly FEED=@feed@
readonly SHAPE_SHIM=@shapeShim@ # package/nowineshape.c
readonly POPUP_SHADOW_FIX=@popupShadowFix@

readonly LOGOS_HOME=${LOGOS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/logos}
readonly CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/logos
readonly STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/logos
readonly LOG=$STATE_DIR/wine.log

export WINEPREFIX=$LOGOS_HOME/prefix
export WINEDEBUG=${WINEDEBUG:-@winedebug@}
export WINEARCH=win64
# winemenubuilder would litter ~/.local/share/{applications,mime,icons} with
# Wine file associations. The registry disables it too, but only after the
# prefix exists — this covers the very first wineboot.
export WINEDLLOVERRIDES="winemenubuilder.exe=d${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
# Popups drawn inside dark boxes on wlroots compositors: see nowineshape.c.
# Only with the gdi renderer: with dxvk/gl the popups' opaque GPU child window
# shows through once the shape is gone, and they turn solid black.
want_shape_shim() {
  case $POPUP_SHADOW_FIX in
    on) return 0 ;;
    off) return 1 ;;
  esac
  [ "$RENDERER" = gdi ] || return 1
  [ "${XDG_SESSION_TYPE:-}" = wayland ] || return 1
  case ${XDG_CURRENT_DESKTOP,,} in
    *gnome* | *kde*) return 1 ;;
  esac
}
if want_shape_shim; then
  export LD_PRELOAD="$SHAPE_SHIM${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# DXVK otherwise writes <exe>_d3d11.log files into the current directory.
export DXVK_LOG_PATH=${DXVK_LOG_PATH:-$STATE_DIR}

# Wine names the prefix's user directory after the Unix user.
WINE_USER=${USER:-$(id -un)}
readonly WINE_USER
readonly APP_DIR=$WINEPREFIX/drive_c/users/$WINE_USER/AppData/Local/Logos
readonly LOGOS_EXE=$APP_DIR/Logos.exe
readonly LOGOS_EXE_WIN="C:\\users\\$WINE_USER\\AppData\\Local\\Logos\\Logos.exe"
readonly INDEXER_WIN="C:\\users\\$WINE_USER\\AppData\\Local\\Logos\\System\\LogosIndexer.exe"
readonly ICON=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps/logos-bible.png

# ── output ──────────────────────────────────────────────────────────────────

interactive() { [ -t 0 ] && [ -t 2 ]; }

say() { printf 'logos: %s\n' "$*" >&2; }

die() {
  say "error: $*"
  interactive || notify-send -a Logos -i dialog-error "Logos" "$*" 2>/dev/null || true
  exit 1
}

notify() {
  say "$*"
  interactive || notify-send -a Logos -i logos-bible "Logos" "$*" 2>/dev/null || true
}

confirm() { # confirm <title> <text>
  if interactive; then
    printf '%s\n\n%s\n\nContinue? [y/N] ' "$1" "$2" >&2
    local reply
    read -r reply
    [[ $reply == [yY]* ]]
  else
    zenity --question --title="$1" --text="$2" --width=460 2>/dev/null
  fi
}

# Run a command with a pulsating progress window when there is no terminal.
with_progress() { # with_progress <text> <cmd…>
  local text=$1
  shift
  if interactive; then
    "$@"
    return
  fi
  "$@" &
  local pid=$!
  (while kill -0 "$pid" 2>/dev/null; do echo "# $text"; sleep 1; done) |
    zenity --progress --pulsate --auto-close --no-cancel --title=Logos --text="$text" --width=420 >/dev/null 2>&1 &
  local dialog=$!
  local rc=0
  wait "$pid" || rc=$?
  wait "$dialog" 2>/dev/null || true
  return "$rc"
}

# ── versions ────────────────────────────────────────────────────────────────

# 53.1.0.0002 -> 53.1.0.2 (the feed pads, Logos.deps.json does not)
normalize() { awk -F. '{ for (i = 1; i <= NF; i++) printf "%s%d", (i > 1 ? "." : ""), $i }' <<<"$1"; }

version_gt() { # version_gt a b: a > b
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

latest_version() { # newest first in the feed
  local feed
  feed=$(curl -fsSL --max-time "${1:-30}" "$FEED") || return 1
  [[ $feed =~ \<logos:version\>([0-9.]+) ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

installed_version() {
  # The MSI stages a release in Pending/; Logos.exe moves it to System/ on
  # its next start.
  local dir
  for dir in System Pending; do
    if [ -f "$APP_DIR/$dir/Logos.deps.json" ]; then
      grep -m1 -o '"Logos/[0-9.]*"' "$APP_DIR/$dir/Logos.deps.json" | tr -d '"' | cut -d/ -f2
      return
    fi
  done
}

is_installed() { [ -f "$LOGOS_EXE" ]; }

# Any Wine process of Logos in THIS prefix (main app, CEF panels, indexer).
logos_pids() {
  local pid
  for pid in $(pgrep -f -i 'AppData.Local.Logos.*\.exe' || true); do
    if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qxF "WINEPREFIX=$WINEPREFIX"; then
      echo "$pid"
    fi
  done
}

is_running() { [ -n "$(logos_pids)" ]; }

# ── prefix ──────────────────────────────────────────────────────────────────

stamp_file() { echo "$WINEPREFIX/.logos-nix-$1"; }

ensure_prefix() {
  mkdir -p "$LOGOS_HOME" "$CACHE_DIR" "$STATE_DIR"

  if [ ! -f "$WINEPREFIX/system.reg" ]; then
    say "creating Wine prefix in $WINEPREFIX"
    # mscoree= keeps wine-mono from installing: Logos ships its own .NET.
    WINEDLLOVERRIDES="$WINEDLLOVERRIDES;mscoree=" with_progress "Creating the Wine prefix…" \
      wine wineboot --init >>"$LOG" 2>&1
    wineserver -w
  fi

  # ICU: Wine has no icu.dll (WineHQ bug 53354) and Logos' .NET needs it.
  if [ "$(cat "$(stamp_file icu)" 2>/dev/null)" != "$ICU" ]; then
    say "installing ICU"
    tar -xzf "$ICU" -C "$WINEPREFIX/drive_c" --no-same-owner --no-same-permissions
    chmod -R u+w "$WINEPREFIX/drive_c/windows/globalization" 2>/dev/null || true
    echo "$ICU" >"$(stamp_file icu)"
  fi

  if [ "$(cat "$(stamp_file fonts)" 2>/dev/null)" != "$FONTS" ]; then
    say "installing Arial"
    local fonts=$WINEPREFIX/drive_c/windows/Fonts src dst
    mkdir -p "$fonts"
    for pair in Arial:arial Arial_Bold:arialbd Arial_Italic:ariali Arial_Bold_Italic:arialbi Arial_Black:ariblk; do
      src=$FONTS/${pair%%:*}.ttf
      dst=$fonts/${pair##*:}.ttf
      install -m644 "$src" "$dst"
    done
    echo "$FONTS" >"$(stamp_file fonts)"
  fi

  ensure_renderer

  # The registry file's store path changes with any setting, so this re-runs
  # exactly when the Nix configuration changed.
  if [ "$(cat "$(stamp_file registry)" 2>/dev/null)" != "$SETUP/settings.reg" ]; then
    say "applying Wine settings (theme=$THEME, renderer=$RENDERER)"
    wine regedit /S "$(wine winepath -w "$SETUP/settings.reg" 2>/dev/null)" >>"$LOG" 2>&1
    wineserver -w
    echo "$SETUP/settings.reg" >"$(stamp_file registry)"
  fi
}

ensure_renderer() {
  local marker
  marker=$(stamp_file dxvk)
  if [ "$RENDERER" = dxvk ]; then
    [ "$(cat "$marker" 2>/dev/null)" = "$DXVK" ] && return
    say "installing DXVK"
    local dll
    for dll in "$DXVK"/x64/*.dll; do
      install -m644 "$dll" "$WINEPREFIX/drive_c/windows/system32/"
    done
    for dll in "$DXVK"/x32/*.dll; do
      install -m644 "$dll" "$WINEPREFIX/drive_c/windows/syswow64/"
    done
    echo "$DXVK" >"$marker"
  elif [ -f "$marker" ]; then
    # Put Wine's own d3d*/dxgi DLLs back.
    say "removing DXVK"
    wine wineboot -u >>"$LOG" 2>&1
    wineserver -w
    rm -f "$marker"
  fi
}

# ── install / update ────────────────────────────────────────────────────────

download_msi() { # download_msi <version> -> prints path
  local version=$1
  local url="https://downloads.logoscdn.com/LBS10/Installer/$version/Logos-x64.msi"
  local msi=$CACHE_DIR/Logos_v$version-x64.msi
  local headers size etag

  headers=$(curl -fsSIL --max-time 30 "$url") || die "cannot reach $url"
  size=$(grep -i '^content-length:' <<<"$headers" | tail -n1 | tr -dc '0-9')
  etag=$(grep -i '^etag:' <<<"$headers" | tail -n1 | cut -d: -f2- | tr -dc '0-9a-f')

  if [ ! -f "$msi" ] || [ "$(stat -c %s "$msi")" != "$size" ]; then
    rm -f "$msi"
    # A complete .part would make the resume request fail with HTTP 416.
    [ -f "$msi.part" ] && [ "$(stat -c %s "$msi.part")" -ge "$size" ] && rm -f "$msi.part"
    say "downloading Logos $version ($((size / 1024 / 1024)) MiB)"
    with_progress "Downloading Logos $version ($((size / 1024 / 1024)) MiB)…" \
      curl -fL --retry 3 -C - -o "$msi.part" "$url" ||
      die "download failed: $url"
    mv "$msi.part" "$msi"
  fi

  [ "$(stat -c %s "$msi")" = "$size" ] || { rm -f "$msi"; die "size mismatch for $msi"; }
  # A single-part S3 upload's ETag is the MD5; multipart ones contain a '-'.
  if [ ${#etag} -eq 32 ]; then
    [ "$(md5sum "$msi" | cut -d' ' -f1)" = "$etag" ] || { rm -f "$msi"; die "checksum mismatch for $msi"; }
  fi
  echo "$msi"
}

install_logos() { # install_logos [version]
  local version=${1:-}
  is_running && die "Logos is running — close it first"

  if [ -z "$version" ]; then
    version=$(latest_version) || die "cannot read the release feed ($FEED)"
  fi
  [ -n "$version" ] || die "the release feed returned no version"

  if [ "$ACCEPT_EULA" != 1 ]; then
    confirm "Install Logos $version" \
      "This downloads the official Logos installer (about 480 MB) from Faithlife and installs it into a Wine prefix in $LOGOS_HOME.

By continuing you agree to Faithlife's terms of use: https://faithlife.com/terms" ||
      die "installation cancelled"
  fi

  ensure_prefix
  local msi mst
  msi=$(download_msi "$version")
  mst=$(wine winepath -w "$SETUP/LogosStubFailOK.mst" 2>/dev/null)

  say "installing Logos $version"
  wineserver -k 2>/dev/null || true
  # The transform lets the MSIX "LogosStub" component (which Wine cannot
  # install, WineHQ bug 57674) fail without failing the whole install.
  with_progress "Installing Logos $version…" \
    wine msiexec /i "$msi" /passive "TRANSFORMS=$mst" >>"$LOG" 2>&1 ||
    die "msiexec failed — see $LOG"
  wineserver -w

  is_installed || die "msiexec finished but $LOGOS_EXE is missing — see $LOG"
  extract_icon
  register_url_handler
  notify "Logos $version installed"
}

update_logos() {
  is_installed || { install_logos; return; }
  local latest current
  latest=$(latest_version) || die "cannot read the release feed ($FEED)"
  current=$(installed_version)
  if version_gt "$(normalize "$latest")" "$(normalize "${current:-0}")"; then
    install_logos "$latest"
  else
    say "Logos ${current:-?} is up to date (latest: $latest)"
  fi
}

extract_icon() {
  local tmp
  tmp=$(mktemp -d)
  if wrestool -x -t 14 "$LOGOS_EXE" >"$tmp/logos.ico" 2>/dev/null &&
    icotool -x -o "$tmp" "$tmp/logos.ico" 2>/dev/null; then
    local best
    best=$(find "$tmp" -name '*.png' -printf '%s %p\n' | sort -n | tail -n1 | cut -d' ' -f2-)
    if [ -n "$best" ]; then
      mkdir -p "$(dirname "$ICON")"
      cp "$best" "$ICON"
      gtk-update-icon-cache -q -t "$(dirname "$(dirname "$(dirname "$ICON")")")" 2>/dev/null || true
    fi
  fi
  rm -rf "$tmp"
}

# Logos signs in through the system browser, which hands the result back as
# a logos4: URL. Only claim the scheme if nothing (e.g. Home Manager) has.
register_url_handler() {
  local scheme
  for scheme in logos4 libronixdls; do
    if [ -z "$(xdg-mime query default "x-scheme-handler/$scheme" 2>/dev/null)" ]; then
      xdg-mime default logos.desktop "x-scheme-handler/$scheme" 2>/dev/null || true
    fi
  done
}

# ── runtime helpers ─────────────────────────────────────────────────────────

# In-app updates crash Logos under Wine (OuDedetai #275): strip application
# updates from Logos' update queue and keep automatic updating opted out while
# it runs. `logos update` installs new releases instead.
block_app_updates() {
  local app_sql='
DELETE FROM UpdateUrls WHERE UpdateId IN (SELECT UpdateId FROM Updates WHERE Source = '"'Application Update'"');
DELETE FROM Updates WHERE Source = '"'Application Update'"' OR UpdateId NOT IN (SELECT UpdateId FROM UpdateUrls);
UPDATE Resources SET Status = 1, UpdateId = NULL WHERE UpdateId IS NOT NULL AND UpdateId NOT IN (SELECT UpdateId FROM Updates);'
  local prefs='<data OptIn="false" StartDownloadHour="0" StopDownloadHour="0" MarkNewResourcesAsCloud="true" />'
  local pref_sql="UPDATE Preferences SET Data = '$prefs' WHERE Type = 'UpdateManagerPreferences' AND Data <> '$prefs';"

  sleep 20 # let Logos start (and create its databases on first run)
  while is_running; do
    local db dirs=()
    for db in "$APP_DIR"/Data/*/UpdateManager/Updates.db; do
      [ -f "$db" ] || continue
      sqlite3 -cmd '.timeout 5000' "$db" "$app_sql" 2>/dev/null || true
      dirs+=("$(dirname "$db")")
    done
    for db in "$APP_DIR"/Documents/*/LocalUserPreferences/PreferencesManager.db; do
      [ -f "$db" ] || continue
      sqlite3 -cmd '.timeout 5000' "$db" "$pref_sql" 2>/dev/null || true
      dirs+=("$(dirname "$db")")
    done
    if [ ${#dirs[@]} -gt 0 ]; then
      inotifywait -qq -t 60 -e close_write -e modify "${dirs[@]}" 2>/dev/null || true
    else
      sleep 10
    fi
  done
}

check_for_update() {
  local latest current
  latest=$(latest_version 10) || return 0
  current=$(installed_version)
  [ -n "$latest" ] && [ -n "$current" ] || return 0
  if version_gt "$(normalize "$latest")" "$(normalize "$current")"; then
    notify "Logos $latest is available (installed: $current). Close Logos and run 'logos update', or use 'Update Logos' in the app menu."
  fi
}

rotate_log() {
  mkdir -p "$STATE_DIR"
  [ -f "$LOG" ] && mv -f "$LOG" "$STATE_DIR/wine.1.log"
  : >"$LOG"
}

# Start a Windows program in the prefix, optionally capped by a systemd scope.
launch() {
  if [ -n "$MEMORY_HIGH" ] && systemd-run --user --quiet --scope true 2>/dev/null; then
    systemd-run --user --quiet --scope --unit="logos-$$" \
      -p MemoryHigh="$MEMORY_HIGH" -- wine "$@" >>"$LOG" 2>&1
  else
    wine "$@" >>"$LOG" 2>&1
  fi
}

run_logos() { # run_logos [url]
  local url=${1:-}
  # Only the scheme: a sign-in callback carries a one-time token.
  mkdir -p "$STATE_DIR"
  echo "$(date -Is) run${url:+ ${url%%:*}: URL} running=$(is_running && echo yes || echo no)" >>"$STATE_DIR/launcher.log"

  # A logos4:/libronixdls: callback (sign-in) goes to the running instance.
  if [ -n "$url" ] && is_running; then
    exec wine "$LOGOS_EXE_WIN" "$url" >>"$LOG" 2>&1
  fi

  if ! is_installed; then
    install_logos
  else
    ensure_prefix
  fi

  if is_running; then
    # Already open: asking it again just brings the window forward.
    exec wine "$LOGOS_EXE_WIN" ${url:+"$url"} >>"$LOG" 2>&1
  fi

  rotate_log
  register_url_handler
  [ -f "$ICON" ] || extract_icon
  [ "$UPDATE_CHECK" = 1 ] && (check_for_update &)

  # Leftover wineservers from a crash wedge the next start (OuDedetai #412).
  wineserver -k 2>/dev/null || true

  local watcher=
  if [ "$BLOCK_APP_UPDATES" = 1 ]; then
    block_app_updates &
    watcher=$!
  fi

  local rc=0
  launch "$LOGOS_EXE" ${url:+"$url"} || rc=$?
  # Logos.exe is a launcher: the app keeps running after it returns, so the
  # watcher lives on until the last Logos process is gone.
  if [ -n "$watcher" ]; then
    wait "$watcher" 2>/dev/null || true
  fi
  return "$rc"
}

run_indexer() {
  is_installed || die "Logos is not installed — run 'logos install'"
  is_running && die "Logos is running — close it before indexing"
  ensure_prefix
  rotate_log
  wineserver -k 2>/dev/null || true
  notify "Indexing your library — this can take a long time"
  with_progress "Indexing your Logos library…" launch "$INDEXER_WIN" || die "the indexer failed — see $LOG"
  wineserver -w
  notify "Indexing finished"
}

kill_logos() {
  local pids
  pids=$(logos_pids)
  # shellcheck disable=SC2086 # one PID per word
  [ -n "$pids" ] && kill $pids 2>/dev/null || true
  wineserver -k 2>/dev/null || true
  say "stopped"
}

backup() { # backup [dir]
  is_installed || die "Logos is not installed"
  is_running && die "Logos is running — close it first so its databases are consistent"
  local dest=${1:-$HOME}
  local file
  file=$dest/logos-backup-$(date +%Y%m%d-%H%M%S).tar.zst
  mkdir -p "$dest"
  say "backing up Data/ and Documents/ to $file"
  tar -C "$APP_DIR" -I 'zstd -T0' -cf "$file" Data Documents
  say "done ($(du -h "$file" | cut -f1))"
}

status() {
  local current latest
  current=$(installed_version)
  latest=$(latest_version 10 || echo "unknown (offline?)")
  cat <<EOF
prefix      $WINEPREFIX
wine        $(wine --version 2>/dev/null)
installed   ${current:-not installed}
latest      ${latest:-unknown}
running     $(is_running && echo yes || echo no)
theme       $THEME
renderer    $RENDERER
popup fix   $(want_shape_shim && echo "on (nowineshape)" || echo off)
log         $LOG
EOF
}

usage() {
  cat <<'EOF'
Usage: logos [command] [args]

  (none) | run [URL]   start Logos (installs it on first run); a logos4: or
                       libronixdls: URL is handed to the running instance
  install [VERSION]    download and install the latest (or given) release
  update               install the latest release if it is newer
  setup                create / refresh the Wine prefix only
  indexer              rebuild the library index (close Logos first)
  status               show versions, paths and settings
  kill                 stop Logos and its Wine processes
  backup [DIR]         archive your Logos Data/ and Documents/ (default: ~)
  log                  follow the Wine log
  winecfg | regedit    Wine configuration tools for the Logos prefix
  wine ARGS…           run any Wine command in the Logos prefix
  help                 this text

Environment: LOGOS_HOME (default ~/.local/share/logos), WINEDEBUG.
EOF
}

main() {
  local cmd=${1:-run}
  [ $# -gt 0 ] && shift
  case $cmd in
    run) run_logos "${1:-}" ;;
    logos4:* | libronixdls:*) run_logos "$cmd" ;;
    install) install_logos "${1:-}" ;;
    update) update_logos ;;
    setup) ensure_prefix && say "prefix ready: $WINEPREFIX" ;;
    indexer) run_indexer ;;
    status) status ;;
    kill | stop) kill_logos ;;
    backup) backup "${1:-}" ;;
    log | logs) mkdir -p "$STATE_DIR" && touch "$LOG" && exec tail -f "$LOG" ;;
    winecfg) ensure_prefix && exec wine winecfg ;;
    regedit) ensure_prefix && exec wine regedit ;;
    wine) ensure_prefix && exec wine "$@" ;;
    help | -h | --help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
