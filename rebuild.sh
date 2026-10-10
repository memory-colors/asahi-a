#!/bin/bash
# rebuild.sh - recreate the "A" system (Fedora Asahi Remix 44 GNOME-ish) on top of a stock Remix 44 MINIMAL install.
#
#   sudo ./rebuild.sh [phase ...] [--archive FILE.tar.zst] [--dry-run]
#   sudo ./rebuild.sh make-archive DIR              (run on the SOURCE system: writes asahi-a-archive-private_<date>.tar.zst AND
#                                                    asahi-home-full_<date>.tar.zst into DIR; the date is added automatically)
#   ./rebuild.sh sync-repo                          (run on the SOURCE system as the normal user: live system -> this repo; never commits)
#
# Phases (default = all, in this order; each one asks before it runs):
#   repos     rpm macro (no extra locales), RPM Fusion release, custom .repo files
#   packages  dnf install [install] list, then dnf remove [remove] list (capability-checked first)
#   files     system files (/etc, /usr, /var), home dotfiles/themes, dconf settings, SELinux relabel
#   services  enable / disable systemd units, default target
#   apps      LosslessCut + czkawka-gui from GitHub releases
#   archive   (only with --archive FILE) unpack the private archive (secrets, personal data, modified icon themes, SF fonts)
#   verify    compare installed packages and units against the recorded system (read-only)
#
# Design rules (user policy): NO dnf -y (dnf shows its own prompts, so you review every package list),
# nothing automated that can go sideways silently (bleachbit, initramfs, bootloader are NOT touched).
set -u
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LISTS=$REPO_DIR/lists.txt
TARGET_USER=blank          # paths in the saved configs (gdm autologin, symlinks, .desktop files) assume this
TARGET_HOME=/home/$TARGET_USER
DRY=0; ARCHIVE=""; PHASES=(); MAKE_SET=""; MAKE=""; SYNC=0

while [ $# -gt 0 ]; do
    case $1 in
        --dry-run) DRY=1 ;;
        --archive) ARCHIVE=${2:-}; shift ;;
        make-archive) MAKE_SET=1; MAKE=${2:-}; shift ;;
        sync-repo) SYNC=1 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) PHASES+=("$1") ;;
    esac
    shift
done
[ ${#PHASES[@]} -eq 0 ] && PHASES=(repos packages files services apps verify)
[ -n "$ARCHIVE" ] && [[ " ${PHASES[*]} " != *" archive "* ]] && PHASES+=(archive)

# ---------------------------------------------------------------------------------------------------------------
# CLASSIFICATION - the one list shared by `make-archive` and `sync-repo`. Paths are relative to $TARGET_HOME.
#   PUBLIC_*   copied into this (public) repo under files/home/ by sync-repo. NEVER put anything secret here.
#   PRIVATE_*  packed by make-archive (secrets, history, personal data).
#   SKIP_*     neither (caches, runtime state, things downloaded/derived by rebuild.sh).
# Anything else is picked up automatically (loose files in ~ and unpublished ~/Software items go to the archive)
# or reported as UNCLASSIFIED (new top-level dirs in ~, ~/.config, ~/.local/share): add it to a list below.
# ---------------------------------------------------------------------------------------------------------------
PUBLIC_DIRS=(.bashrc.d .themes .local/bin
    .local/share/applications .local/share/dolphin .local/share/fonts .local/share/gnome-shell .local/share/icons .local/share/konsole
    .config/{autostart,bleachbit,czkawka,dhruva@blank.local,environment.d,gtk-3.0,gtk-4.0,ibus,ksnip,menus,plasma-workspace}
    .config/{qView,qt5ct,qt6ct,ristretto,smplayer,VeraCrypt,viewnior,xdg-desktop-portal,xfce4})
PUBLIC_FILES=(.bashrc
    .config/{.gsd-keyboard.settings-ported,baloofileinformationrc,dnfdragora.yaml,dnfui.conf,dolphinrc,gnome-initial-setup-done}
    .config/{kdeglobals,kglobalshortcutsrc,khotkeysrc,kiorc,konsole.kmessagebox,konsolerc,kservicemenurc,ktrashrc}
    .config/{mimeapps.list,monitors.xml,qwhitesurgtkdecorations.conf,user-dirs.dirs,user-dirs.locale}
    ".config/Mullvad VPN/gui_settings.json" .config/LosslessCut/config.json)
PUBLIC_SOFTWARE=(asahi_atomic "Toggl_*" "lt_grey*")      # globs inside ~/Software; everything else there is PRIVATE
SKIP_SOFTWARE=(czkawka-gui asahi-a)                             # downloaded by the apps phase
# excluded from the rsync of PUBLIC_DIRS (patterns match at any depth): private, absolute symlinks are dropped by --safe-links
SYNC_EXCLUDES=(.git original-upstream-extensions __pycache__ '*.bak*' '*.pyc' rEFInd-install.desktop view_properties extensions-bak extension-updates 'SF-*' claude losslesscut)
PRIVATE_PATHS=(.ssh .claude Downloads Screenshots
    .local/share/keyrings .local/share/pki .local/share/evolution .local/share/applications/rEFInd-install.desktop
    ".config/Mullvad VPN" .config/transmission .config/evolution .config/BraveSoftware .config/Claude .config/gh .config/konsolesshconfig
    .local/share/fonts/SF-Compact-static .local/share/fonts/SF-Pro-static)       # + loose files in ~ (except .bashrc, .index)
PRIVATE_SYSTEM=(etc/NetworkManager/system-connections etc/mullvad-vpn var/lib/AccountsService/users/$TARGET_USER var/lib/AccountsService/icons/$TARGET_USER
    usr/share/icons/{MacTahoe-nord,MacTahoe-nord-dark,WhiteSur-grey,Bibata-Modern-Ice,breeze_cursors})
SKIP_PATHS=(.cache .var .index .local/share/{LosslessCut,claude,Trash,baloo,flatpak,folks,glib-2.0,gnome-settings-daemon,gnome-software}
    .local/share/{gvfs-metadata,icc,kio,locale,metainfo,nautilus,org.gnome.TextEditor,recently-used.xbel,user-places.xbel}
    .local/share/{backgrounds,color-schemes,desktop-directories,gtksourceview-5,kservices5,kxmlgui5,pixmaps,sounds}
    .config/{dconf,enchant,goa-1.0,imsettings,mpv,pulse,LosslessCut} .local/bin/claude)
# archive: the Claude Desktop caches are not worth packing
FULL_EXCLUDES=(.cache .local/share/Trash)   # full home backup: everything else is included
ARCHIVE_EXCLUDES=(.config/Claude/claude-code .config/Claude/Cache ".config/Claude/Code Cache" .config/Claude/GPUCache
                  .config/Claude/DawnGraphiteCache .config/Claude/DawnWebGPUCache)

classified() {   # classified REL: true if REL (or a path beneath it) appears in any list, or is a backup/cache artefact
    local rel=$1 k
    case $rel in *.bak*|*.tbcache|user-places.xbel.*) return 0 ;; esac
    for k in "${PUBLIC_DIRS[@]}" "${PUBLIC_FILES[@]}" "${PRIVATE_PATHS[@]}" "${SKIP_PATHS[@]}"; do
        [ "$rel" = "$k" ] || [[ $k == "$rel"/* ]] && return 0
    done
    return 1
}
unclassified_scan() {   # warn about new entries nobody has classified yet
    local d e rel n=0
    for d in "" .config .local/share; do
        for e in "$TARGET_HOME/${d:+$d/}"* "$TARGET_HOME/${d:+$d/}".[!.]*; do
            [ -e "$e" ] || [ -L "$e" ] || continue
            rel=${e#"$TARGET_HOME"/}
            [ -z "$d" ] && [ ! -d "$e" ] && continue          # loose files in ~ are auto-archived
            [ -z "$d" ] && case $rel in .config|.local|Software) continue ;; esac   # Software is classified per item (PUBLIC_SOFTWARE)
            classified "$rel" || { warn "UNCLASSIFIED: ~/$rel  (add it to PUBLIC_*/PRIVATE_*/SKIP_* at the top of rebuild.sh)"; n=$((n+1)); }
        done
    done
    [ $n -eq 0 ] && echo "No unclassified entries."
    return 0
}

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [ $DRY -eq 1 ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }
as_user() { run runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"; }
# rsync flavours: never touch existing directory modes/owners (home is 700, /var/lib/gdm has its own modes)
RS_SYS=(rsync -rltE --no-owner --no-group)
RS_HOME=(rsync -rltE "--chown=$TARGET_USER:$TARGET_USER")
section() { awk -v s="[$1]" '$0==s{f=1;next} /^\[/{f=0} f&&NF' "$LISTS"; }
ask() {   # ask "question" ; reads from the terminal even when launched through a pipe
    [ $DRY -eq 1 ] && return 0
    local a; read -r -p "$1 [y/N] " a < /dev/tty; [ "$a" = y ] || [ "$a" = Y ]
}

preflight() {
    [ "$(id -u)" -eq 0 ] || [ $DRY -eq 1 ] || die "run as root: sudo ./rebuild.sh"
    [ -r "$LISTS" ] || die "missing $LISTS"
    . /etc/os-release
    [ "$ID" = fedora-asahi-remix ] && [ "$VERSION_ID" = 44 ] || die "expected Fedora Asahi Remix 44, found $ID $VERSION_ID"
    [ "$(uname -m)" = aarch64 ] || die "expected aarch64"
    id "$TARGET_USER" >/dev/null 2>&1 || die "user '$TARGET_USER' does not exist - create it first (saved configs assume it)"
    [ "$(id -u "$TARGET_USER")" -eq 1000 ] || warn "$TARGET_USER is not uid 1000 (ydotool override pins 1000:1000)"
    getent hosts github.com >/dev/null || die "no network"
}

phase_repos() {
    say "repos"
    # New packages skip non-English locales. Minimal's own locales stay; run bleachbit yourself afterwards.
    run install -D -m 0644 "$REPO_DIR/files/system/etc/rpm/macros.image-language-conf" /etc/rpm/macros.image-language-conf
    if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
        run dnf install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
    fi
    run install -m 0644 "$REPO_DIR"/files/system/etc/yum.repos.d/*.repo /etc/yum.repos.d/
    run install -D -m 0644 "$REPO_DIR/files/system/etc/dnf/repos.override.d/99-config_manager.repo" /etc/dnf/repos.override.d/99-config_manager.repo
    echo "Repos installed. dnf will ask to import each vendor GPG key on first use - check the fingerprints you expect."
}

removal_blockers() {   # capability-level check: who still needs what we are about to remove?
    local want=" $* " pkg cap req
    for pkg in "$@"; do
        rpm -q --provides "$pkg" 2>/dev/null | sed 's/ .*//' | sort -u | while read -r cap; do
            rpm -q --whatrequires "$cap" 2>/dev/null | grep -v '^no package' | while read -r req; do
                n=$(rpm -q --qf '%{NAME}.%{ARCH}' "$req" 2>/dev/null)
                case "$want" in *" $n "*) ;; *) echo "$pkg  <-  $n  (via $cap)";; esac
            done
        done
    done | sort -u
}

phase_packages() {
    say "packages"
    mapfile -t INST < <(section install)
    echo "${#INST[@]} packages to install. dnf may propose ERASING Minimal packages it conflicts with"
    echo "(expected: fedora-asahi-remix-release / -identity-basic swap for the -workstation flavour)."
    ask "Run dnf install?" && run dnf install --allowerasing "${INST[@]}"

    mapfile -t REM < <(section remove)
    local present=() p
    for p in "${REM[@]}"; do rpm -q "$p" >/dev/null 2>&1 && present+=("$p"); done
    echo; echo "${#present[@]} of ${#REM[@]} removal candidates are installed."
    [ ${#present[@]} -eq 0 ] && return 0
    echo "Checking what still depends on them (capability level)..."
    local blockers; blockers=$(removal_blockers "${present[@]}")
    if [ -n "$blockers" ]; then
        printf '%s\n' "$blockers"
        warn "something outside the remove list still needs the packages above - NOT removing. Resolve by hand."
        return 1
    fi
    echo "No blockers. dnf will now show its own removal list: if it contains anything NOT in [remove]"
    echo "(dnf5, gnome-shell, systemd, kernel...) answer N."
    ask "Run dnf remove?" && run dnf remove "${present[@]}"
}

phase_files() {
    say "files"
    local H=$REPO_DIR/files/home S=$REPO_DIR/files/system A=$REPO_DIR/files/Software/asahi_atomic
    # --- system files (everything under files/system mirrors /). The patched shell theme only fits the
    #     gnome-shell build it was generated from (50.5); on any other build keep the stock file.
    local excl=()
    if ! rpm -q gnome-shell | grep -q '^gnome-shell-50\.5-'; then
        warn "gnome-shell is $(rpm -q gnome-shell); saved theme gresource is for 50.5 - keeping the STOCK file."
        warn "Re-run your ~/.themes/machine-setup/set-shell-*.sh scripts to regenerate it."
        excl=(--exclude=usr/share/gnome-shell/gnome-shell-theme.gresource)
    fi
    run "${RS_SYS[@]}" "${excl[@]}" --exclude='etc/rpm/macros.image-language-conf' "$S"/ /
    # reboot-picker: install from the project copies (one source of truth)
    run install -D -m 0755 "$A/reboot-picker" /usr/local/bin/reboot-picker
    run install -D -m 0755 "$A/reboot-picker-helper" /usr/local/libexec/reboot-picker-helper
    run install -D -m 0440 "$A/reboot-picker-sudoers" /etc/sudoers.d/reboot-picker
    run visudo -cf /etc/sudoers.d/reboot-picker
    # GDM single-user extension + adw-gtk3 copy for root GUI apps (pkexec) come from the home copies
    run "${RS_SYS[@]}" "$H/.themes/machine-setup/gdm-single-user@blank.local/" "/usr/share/gnome-shell/extensions/gdm-single-user@blank.local/"
    run "${RS_SYS[@]}" "$H/.themes/adw-gtk3-dark/" /usr/share/themes/adw-gtk3-dark/
    run dconf update
    # --- home: dotfiles, themes, launchers, configs, fonts, ~/Software scripts (never --delete)
    run "${RS_HOME[@]}" "$H"/ "$TARGET_HOME"/
    run "${RS_HOME[@]}" "$REPO_DIR/files/Software"/ "$TARGET_HOME/Software"/
    run chmod 700 "$TARGET_HOME"
    as_user fc-cache -f
    # --- GNOME settings (text dump -> user dconf db, on a private bus since no session is running)
    [ -r "$REPO_DIR/files/dconf-user.ini" ] && as_user dbus-run-session -- sh -c "dconf load / < '$REPO_DIR/files/dconf-user.ini'"
    # --- SELinux labels for everything we dropped in
    run restorecon -RF /etc /usr/local /usr/share/gnome-shell /usr/share/themes /var/lib/gdm "$TARGET_HOME" 2>/dev/null
    echo "Done. NOT run (do by hand if wanted): bleachbit locale cleanup, dracut/plymouth initramfs rebuild,"
    echo "Claude Code install (curl -fsSL https://claude.ai/install.sh | bash, as $TARGET_USER)."
}

phase_services() {
    say "services"
    local u
    while read -r u; do
        if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then run systemctl enable "$u"; else warn "unit $u not found, skipped"; fi
    done < <(section enable)
    while read -r u; do
        systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u" && run systemctl disable "$u"
    done < <(section disable)
    run systemctl set-default graphical.target
    echo "Not touched on purpose: asahi-*-firstboot and initial-setup (one-shot, remove themselves)."
}

phase_apps() {
    say "apps (GitHub release binaries, installed as $TARGET_USER)"
    local lc=https://github.com/mifi/lossless-cut/releases/download/v3.69.0/LosslessCut-linux-arm64.tar.bz2
    local cz=https://github.com/qarmin/czkawka/releases/download/12.0.2/linux_czkawka_gui_heif_raw_avif_arm64
    local d=$TARGET_HOME/.local/share/LosslessCut
    as_user mkdir -p "$d" "$TARGET_HOME/.local/bin" "$TARGET_HOME/Software/czkawka-gui"
    if [ $DRY -eq 1 ]; then echo "[dry-run] download $lc -> $d"; else
        runuser -u "$TARGET_USER" -- sh -c "curl -fL '$lc' | tar xj -C '$d' --strip-components=1" || warn "LosslessCut download failed"
    fi
    as_user ln -sfn "$d/losslesscut" "$TARGET_HOME/.local/bin/losslesscut"
    # the arm64 release ships no ffmpeg; the installed copy points at the system (RPM Fusion) binaries
    as_user ln -sfn /usr/bin/ffmpeg  "$d/resources/ffmpeg"
    as_user ln -sfn /usr/bin/ffprobe "$d/resources/ffprobe"
    as_user curl -fL -o "$TARGET_HOME/Software/czkawka-gui/czkawka_gui" "$cz" || warn "czkawka download failed"
    as_user chmod +x "$TARGET_HOME/Software/czkawka-gui/czkawka_gui"
}

make_archive() {   # run on the source system; needs root for the root-only files
    local out=$1 paths=() p f e k
    [ -n "$out" ] || die "usage: rebuild.sh make-archive DIR   (an existing directory, e.g. the external drive)"
    [ "$(id -u)" -eq 0 ] || [ $DRY -eq 1 ] || die "run as root (reads root-only files such as Wi-Fi profiles)"
    [ -d "$out" ] || die "$out is not a directory"
    local dir=${out%/} stamp; stamp=$(date +%F)
    local priv=$dir/asahi-a-archive-private_$stamp.tar.zst full=$dir/asahi-home-full_$stamp.tar.zst
    [ ! -e "$priv" ] || die "$priv already exists - refusing to overwrite (delete the old one first)"
    [ ! -e "$full" ] || die "$full already exists - refusing to overwrite (delete the old one first)"
    cd / || exit 1
    local H=${TARGET_HOME#/}
    add() { for p in "$@"; do if [ -e "/$p" ]; then paths+=("$p"); else warn "missing, skipped: /$p"; fi; done; }
    # 1. everything listed as PRIVATE (home-relative) and the private system files
    for p in "${PRIVATE_PATHS[@]}"; do add "$H/$p"; done
    add "${PRIVATE_SYSTEM[@]}"
    # 2. every loose file in ~ except .bashrc (public) and .index
    shopt -s nullglob dotglob
    for f in "$TARGET_HOME"/*; do
        [ -d "$f" ] && [ ! -L "$f" ] && continue
        case ${f##*/} in .bashrc|.index) continue ;; esac
        paths+=("${f#/}")
    done
    # 3. everything in ~/Software that is neither published nor skipped (new items are PRIVATE by default)
    for f in "$TARGET_HOME"/Software/*; do
        e=${f##*/}; k=0
        for p in "${PUBLIC_SOFTWARE[@]}" "${SKIP_SOFTWARE[@]}"; do [[ $e == $p ]] && k=1; done
        [ $k -eq 0 ] && paths+=("${f#/}")
    done
    shopt -u nullglob dotglob
    unclassified_scan
    local ex=(--anchored) x
    for x in "${ARCHIVE_EXCLUDES[@]}"; do ex+=("--exclude=$H/$x"); done
    say "private archive: ${#paths[@]} items -> $priv"
    if [ $DRY -eq 1 ]; then
        printf '  /%s\n' "${paths[@]}"
        say "full home backup -> $full  (all of /$H except: ${FULL_EXCLUDES[*]})"
        return 0
    fi
    tar --zstd -cpf "$priv.partial" --numeric-owner "${ex[@]}" "${paths[@]}" || { rm -f "$priv.partial"; die "private tar failed, nothing written"; }
    mv "$priv.partial" "$priv"
    echo "Written: $priv  $(ls -lh "$priv" | awk '{print $5}')  entries: $(tar --zstd -tf "$priv" | wc -l)"
    say "full home backup -> $full"
    local fx=(--anchored); for x in "${FULL_EXCLUDES[@]}"; do fx+=("--exclude=$H/$x"); done
    tar --zstd -cpf "$full.partial" --numeric-owner "${fx[@]}" "$H" || { rm -f "$full.partial"; die "full tar failed, nothing written"; }
    mv "$full.partial" "$full"
    echo "Written: $full  $(ls -lh "$full" | awk '{print $5}')  entries: $(tar --zstd -tf "$full" | wc -l)"
    echo "Both files are UNENCRYPTED and contain keys/passwords/history: keep them on the external drive only."
    echo "Restore either one with: rebuild.sh archive --archive FILE   (the full backup also overwrites configs: use only for a complete restore)."
}

sync_repo() {   # live system -> this repo. Run as the normal user. Never commits or pushes.
    [ "$(id -u)" -ne 0 ] || die "run as $TARGET_USER, not root (files in the repo must stay owned by you)"
    [ "$(id -un)" = "$TARGET_USER" ] || die "run as $TARGET_USER"
    command -v rsync >/dev/null || die "rsync missing"
    local F=$REPO_DIR/files rel f n k ex=() x d
    for x in "${SYNC_EXCLUDES[@]}"; do ex+=("--exclude=$x"); done
    # --- home: public dirs (mirrored, deletions included), public files, public ~/Software items
    say "sync: home"
    for rel in "${PUBLIC_DIRS[@]}"; do
        if [ -d "$TARGET_HOME/$rel" ]; then
            mkdir -p "$F/home/$rel"
            rsync -rltE --delete --safe-links "${ex[@]}" "$TARGET_HOME/$rel"/ "$F/home/$rel"/ || warn "rsync failed: $rel"
        else warn "public dir missing on this system: ~/$rel"; fi
    done
    for rel in "${PUBLIC_FILES[@]}"; do
        if [ -e "$TARGET_HOME/$rel" ]; then mkdir -p "$(dirname "$F/home/$rel")"; rsync -ltE "$TARGET_HOME/$rel" "$F/home/$rel"
        else warn "public file missing on this system: ~/$rel"; fi
    done
    mkdir -p "$F/Software"
    shopt -s nullglob
    for k in "${PUBLIC_SOFTWARE[@]}"; do
        for f in "$TARGET_HOME"/Software/$k; do
            if [ -d "$f" ]; then rsync -rltE --delete --safe-links "${ex[@]}" "$f"/ "$F/Software/${f##*/}"/
            else rsync -ltE "$f" "$F/Software/"; fi
        done
    done
    # files that were published earlier but no longer exist live (loose items only; dirs are mirrored above)
    for f in "$F"/Software/*; do
        [ -d "$f" ] && continue
        [ -e "$TARGET_HOME/Software/${f##*/}" ] || { echo "removed from repo (gone live): Software/${f##*/}"; rm -f "$f"; }
    done
    shopt -u nullglob
    # --- system: files already tracked in files/system, plus unowned .repo files
    say "sync: system files"
    while IFS= read -r -d '' f; do
        rel=${f#"$F/system/"}
        [ "$rel" = etc/rpm/macros.image-language-conf ] && continue      # repo-only: installed by the repos phase, absent on A
        if [ -r "/$rel" ]; then rsync -ltE "/$rel" "$f"; else warn "tracked system file unreadable/missing: /$rel"; fi
    done < <(find "$F/system" -type f -print0)
    for f in /etc/yum.repos.d/*.repo; do
        rpm -qf "$f" >/dev/null 2>&1 || { [ -e "$F/system${f}" ] || echo "new unowned repo file: $f"; rsync -ltE "$f" "$F/system/etc/yum.repos.d/"; }
    done
    # --- package lists: install/remove/closure regenerated against the Minimal baseline; enable/disable kept as they are
    say "sync: lists.txt"
    local base; base=$(ls "$TARGET_HOME"/Software/asahi_atomic/baseline-remix44-minimal-packages_*.txt 2>/dev/null | tail -1)
    [ -n "$base" ] || die "no baseline-remix44-minimal-packages_*.txt in ~/Software/asahi_atomic"
    local t; t=$(mktemp -d)
    sort -u "$base" > "$t/minimal"
    rpm -qa --qf '%{NAME}.%{ARCH}\n' | sort -u > "$t/have"
    dnf repoquery --userinstalled --qf '%{name}.%{arch}\n' 2>/dev/null | sort -u > "$t/user"
    [ -s "$t/user" ] || die "dnf repoquery --userinstalled returned nothing"
    comm -23 "$t/user" "$t/minimal" > "$t/install"
    comm -23 "$t/minimal" "$t/have" > "$t/remove"
    cp "$t/have" "$t/closure"   # verify compares against the FULL package set
    {
        echo "# Machine-readable lists for rebuild.sh. Regenerated by 'rebuild.sh sync-repo' on $(date +%F) against $(basename "$base") (F44 Asahi Remix)."
        for k in install remove; do echo "[$k]"; cat "$t/$k"; done
        for k in enable disable; do echo "[$k]"; section "$k"; done
        echo "[closure]"; cat "$t/closure"
    } > "$t/lists.new"
    mv "$t/lists.new" "$LISTS"
    echo "install $(wc -l < "$t/install")  remove $(wc -l < "$t/remove")  closure $(wc -l < "$t/closure")   ([enable]/[disable] kept - edit by hand if services changed)"
    rm -rf "$t"
    # --- GNOME settings (volatile history/path keys and per-connection nm-applet sections dropped)
    say "sync: dconf"
    dconf dump / | awk '
        /^\[/ { skip = ($0 ~ /^\[org\/gnome\/nm-applet\//) }
        skip { next }
        /^(last-save-directory|last-folder-path|command-history|looking-glass-history)=/ { next }
        { print }' > "$F/dconf-user.ini"
    # --- secrets scan: content patterns + any PRIVATE path that leaked into files/
    say "secrets scan"
    local hits=0
    if grep -rIEn -e '-----BEGIN [A-Z ]*PRIVATE KEY' -e 'gh[pousr]_[A-Za-z0-9]{30,}' -e 'github_pat_' -e 'sk-ant-[A-Za-z0-9]' \
            -e 'AKIA[0-9A-Z]{16}' -e '(password|passwd|psk|secret|api[_-]?key|token)[[:space:]]*[=:][[:space:]]*[^[:space:]]{6,}' \
            --exclude-dir=.git "$REPO_DIR/files" "$LISTS"; then hits=1; fi
    for rel in "${PRIVATE_PATHS[@]}"; do
        [[ " ${PUBLIC_FILES[*]} " == *" $rel/"* || " ${PUBLIC_FILES[*]} " == *\"$rel/* ]] && continue   # only single public files inside
        [ -e "$F/home/$rel" ] && { echo "PRIVATE path present in repo: files/home/$rel"; hits=1; }
    done
    for rel in "${PRIVATE_SYSTEM[@]}"; do
        [ -e "$F/system/$rel" ] && { echo "PRIVATE path present in repo: files/system/$rel"; hits=1; }
    done
    if [ $hits -eq 1 ]; then warn "secrets scan has hits (above): review before any push"; else echo "clean."; fi
    say "unclassified entries"
    unclassified_scan
    say "git status / diff stat (nothing is committed or pushed)"
    git -C "$REPO_DIR" status --short | head -60
    git -C "$REPO_DIR" diff --stat | tail -25
    echo "Review with: git -C $REPO_DIR diff   - then commit/push yourself."
}

phase_archive() {
    say "archive restore from $ARCHIVE"
    [ -f "$ARCHIVE" ] || die "$ARCHIVE is not a file (make it with: sudo ./rebuild.sh make-archive DIR)"
    echo "Unpacks over / with the original owners and modes (expects $TARGET_USER = uid 1000)."
    tar --zstd -tf "$ARCHIVE" | sed -n '1,12p'; echo "..."
    ask "Unpack it over the system now?" || return 0
    run tar --zstd -xpf "$ARCHIVE" -C / --numeric-owner
    # the SF fonts are stored once (user copy); root GUI apps (pkexec) need them system-wide too
    local d
    for d in "$TARGET_HOME"/.local/share/fonts/SF-*; do [ -d "$d" ] && run cp -a "$d" /usr/share/fonts/; done
    run chmod 600 /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null
    run restorecon -RF /etc/NetworkManager /etc/mullvad-vpn /usr/share/icons /usr/share/fonts /var/lib/AccountsService "$TARGET_HOME" 2>/dev/null
    run fc-cache -f
    run gtk-update-icon-cache -f -q /usr/share/icons/MacTahoe-nord-dark 2>/dev/null
    run nmcli connection reload 2>/dev/null
}

phase_verify() {
    say "verify (read-only)"
    local tmp; tmp=$(mktemp -d)
    section closure | sort -u > "$tmp/want"
    rpm -qa --qf '%{NAME}.%{ARCH}\n' | sort -u > "$tmp/have"
    echo "Packages missing vs recorded system:"; comm -23 "$tmp/want" "$tmp/have" | sed 's/^/  - /'
    echo "Packages extra vs recorded system:";   comm -13 "$tmp/want" "$tmp/have" | sed 's/^/  + /'
    echo "Units that should be enabled but are not:"
    section enable | while read -r u; do systemctl is-enabled "$u" >/dev/null 2>&1 || echo "  - $u"; done
    echo "Units that should be disabled but are enabled:"
    section disable | while read -r u; do systemctl is-enabled "$u" >/dev/null 2>&1 && echo "  + $u"; done
    echo "(Missing locale/man/help FILES are expected - lean install; run bleachbit yourself.)"
    rm -rf "$tmp"
}

if [ -n "$MAKE_SET" ]; then make_archive "$MAKE"; exit $?; fi
if [ $SYNC -eq 1 ]; then sync_repo; exit $?; fi
preflight
for p in "${PHASES[@]}"; do
    case $p in
        repos|packages|files|services|apps|archive|verify)
            if [ "$p" = verify ] || ask "Run phase '$p'?"; then "phase_$p" || warn "phase $p reported problems"; fi ;;
        *) die "unknown phase: $p" ;;
    esac
done
say "finished - reboot, then run: sudo ./rebuild.sh verify"
