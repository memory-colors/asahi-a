#!/bin/bash
# rebuild.sh - recreate the "A" system (Fedora Asahi Remix 44 GNOME-ish) on top of a stock Remix 44 MINIMAL install,
#              and (publish) back the current system up for exactly that.
#
#   sudo ./rebuild.sh [phase ...] [--archive FILE.tar.zst] [--dry-run]       restore, on a fresh Minimal install
#   ./rebuild.sh publish [--dry-run]                                          backup, on the source system (run as the normal user)
#
# publish = 1 home archive -> external drive (verified)  2 installer files -> GitHub (asks first)  3 cleanup  4 restore README
# Phases (default = all, in this order; each one asks before it runs):
#   repos     rpm macro (no extra locales), RPM Fusion release, custom .repo files
#   packages  dnf install [install] list, then dnf remove [remove] list (capability-checked first)
#   files     system files (/etc, /usr, /var), dconf settings, SELinux relabel
#   services  enable / disable systemd units, default target
#   apps      LosslessCut + czkawka-gui from GitHub releases
#   archive   find <date>_asahi_home_full.tar.zst on a drive, unpack it (home, keys, Wi-Fi, icon themes, SF fonts)
#   verify    compare installed packages and units against the recorded system (read-only)
#
# Design rules (user policy): NO dnf -y (dnf shows its own prompts, so you review every package list),
# nothing automated that can go sideways silently (bleachbit, initramfs, bootloader are NOT touched).
set -u
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LISTS=$REPO_DIR/lists.txt
TARGET_USER=blank          # paths in the saved configs (gdm autologin, symlinks, .desktop files) assume this
TARGET_HOME=/home/$TARGET_USER
MEDIA_ROOT=${MEDIA_ROOT:-/run/media/$TARGET_USER}     # where external drives are mounted (override for tests)
TTY_IN=${TTY_IN:-/dev/tty}                            # where prompts read from (override for tests)
DRY=0; ARCHIVE=""; PHASES=(); PUBLISH=0

while [ $# -gt 0 ]; do
    case $1 in
        --dry-run) DRY=1 ;;
        --archive) ARCHIVE=${2:-}; shift ;;
        publish) PUBLISH=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) PHASES+=("$1") ;;
    esac
    shift
done
[ ${#PHASES[@]} -eq 0 ] && PHASES=(repos packages files services apps archive verify)
[ -n "$ARCHIVE" ] && [[ " ${PHASES[*]} " != *" archive "* ]] && PHASES+=(archive)

# ---------------------------------------------------------------------------------------------------------------
# WHAT GOES WHERE
#   archive (publish step 1): ALL of $TARGET_HOME except ARCHIVE_EXCLUDES, plus the ARCHIVE_SYSTEM paths (root-only files).
#   GitHub  (publish step 2): installer + lists.txt + files/system (system files) + files/dconf-user.ini + files/Software/asahi_atomic.
#                             No home files: they come back from the archive.
# ---------------------------------------------------------------------------------------------------------------
ARCHIVE_EXCLUDES=(Downloads Screenshots Screencasts Pictures Photo Video Music Audio Movies .index .cache .local/share/Trash
    Software/asahi-a Software/czkawka-gui .local/share/LosslessCut            # last three: re-created by the repo / apps phase
    .config/Claude/claude-code .config/Claude/Cache ".config/Claude/Code Cache" .config/Claude/GPUCache
    .config/Claude/DawnGraphiteCache .config/Claude/DawnWebGPUCache)           # Claude Desktop caches
ARCHIVE_SYSTEM=(etc/NetworkManager/system-connections etc/mullvad-vpn var/lib/AccountsService/users/$TARGET_USER var/lib/AccountsService/icons/$TARGET_USER
    usr/share/icons/{MacTahoe-nord,MacTahoe-nord-dark,WhiteSur-grey,Bibata-Modern-Ice,breeze_cursors})

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [ $DRY -eq 1 ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }
as_user() { run runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"; }
# rsync flavours: never touch existing directory modes/owners (home is 700, /var/lib/gdm has its own modes)
RS_SYS=(rsync -rltE --no-owner --no-group)
section() { awk -v s="[$1]" '$0==s{f=1;next} /^\[/{f=0} f&&NF' "$LISTS"; }
ask() {   # ask "question" ; reads from the terminal even when launched through a pipe
    [ $DRY -eq 1 ] && return 0
    local a; read -r -p "$1 [y/N] " a < "$TTY_IN"; [ "$a" = y ] || [ "$a" = Y ]
}
confirm() {   # confirm "question" ; y/n, asks again on anything else; no input (EOF) counts as n. Also asks in --dry-run.
    local a
    while :; do read -r -p "$1 y/n: " a < "$TTY_IN" || return 1; case $a in y|Y) return 0 ;; n|N) return 1 ;; esac; done
}
pause() { local a; read -r -p "$1" a < "$TTY_IN" || die "no input available"; }

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
    local S=$REPO_DIR/files/system A=$REPO_DIR/files/Software/asahi_atomic
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
    run dconf update
    # --- home: comes back from the archive (archive phase); only the permissions are set here
    run chmod 700 "$TARGET_HOME"
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

# =================================================================================================================
# PUBLISH (source system, as the normal user; sudo only for the archive)
# =================================================================================================================
letter() { printf "\\$(printf '%03o' $((97 + $1)))"; }      # 0 -> a, 1 -> b ...
DEST=""; ARCHIVE_PATH=""; COMMIT=""; WORK=""

pub_pick_dest() {   # sets DEST to <drive>/Software after you confirm; no drive -> wait and rescan; n -> abort
    local d dests lbl i pick ok
    while :; do
        dests=(); for d in "$MEDIA_ROOT"/*/Software; do [ -d "$d" ] && dests+=("$d"); done
        if [ ${#dests[@]} -eq 0 ]; then pause "Please attach external drive and press enter when ready. "; continue; fi
        if [ ${#dests[@]} -eq 1 ]; then
            d=${dests[0]}; lbl=$(basename "$(dirname "$d")")/Software
            confirm "found $lbl - create archive here?" && { DEST=$d; return 0; }
            die "aborted"
        fi
        echo "found:"; for i in "${!dests[@]}"; do printf '  %s. %s/Software\n' "$(letter "$i")" "$(basename "$(dirname "${dests[i]}")")"; done
        read -r -p "enter letter to select (Enter = rescan, q = abort): " pick < "$TTY_IN" || die "no input available"
        [ "$pick" = q ] && die "aborted"
        [ -z "$pick" ] && continue
        ok=0; for i in "${!dests[@]}"; do [ "$pick" = "$(letter "$i")" ] && { DEST=${dests[i]}; ok=1; }; done
        [ $ok -eq 1 ] && return 0
    done
}

pub_archive() {
    say "1/4 archive"
    pub_pick_dest
    local real; real=$(realpath "$DEST")
    case $real/ in "$TARGET_HOME"/*) die "$real is inside $TARGET_HOME - the archive would contain itself" ;; esac
    local stamp name H x m f p
    stamp=$(date +%F); name=${stamp}_asahi_home_full.tar.zst; H=${TARGET_HOME#/}
    ARCHIVE_PATH=$DEST/$name
    if [ -e "$ARCHIVE_PATH" ]; then confirm "$name already exists here - replace it?" || die "aborted"; fi
    # space: du of home (basename excludes, so an upper bound) against free space on the drive
    local ud=() est avail
    for x in "${ARCHIVE_EXCLUDES[@]}"; do ud+=("--exclude=${x##*/}"); done
    est=$(du -sk "${ud[@]}" "$TARGET_HOME" 2>/dev/null | cut -f1); avail=$(df -Pk "$DEST" | awk 'NR==2{print $4}')
    echo "home ~$((est/1024/1024)) GiB before compression, $((avail/1024/1024)) GiB free on the drive."
    if [ "$avail" -lt "$est" ]; then confirm "Free space is below the uncompressed size (the archive is usually about half). Continue?" || die "aborted"; fi
    # tar arguments
    local ex=(--no-anchored "--exclude=*_asahi_home_full*" --anchored) paths=("$H")
    for x in "${ARCHIVE_EXCLUDES[@]}"; do ex+=("--exclude=$H/$x"); done
    while read -r m; do ex+=("--exclude=${m#/}"); done < <(findmnt -rn -o TARGET | grep "^$TARGET_HOME/")     # drives mounted inside home
    for p in "${ARCHIVE_SYSTEM[@]}"; do if [ -e "/$p" ]; then paths+=("$p"); else warn "missing, skipped: /$p"; fi; done
    if [ $DRY -eq 1 ]; then
        echo "[dry-run] would write $ARCHIVE_PATH"
        echo "[dry-run] tar paths: ${paths[*]}"; echo "[dry-run] excluded: ${ARCHIVE_EXCLUDES[*]} (+ any *_asahi_home_full*, mounts inside home)"
        return 0
    fi
    pause "Close all open applications and press Enter when done. "
    sudo -v || die "sudo failed"
    local partial=$ARCHIVE_PATH.partial rc ticker
    ( while :; do printf '\r  %s written ' "$(numfmt --to=iec "$(stat -c%s "$partial" 2>/dev/null || echo 0)")"; sleep 3; done ) & ticker=$!
    sudo tar -C / -I 'zstd -T0' -cpf "$partial" --numeric-owner "${ex[@]}" "${paths[@]}"; rc=$?
    kill "$ticker" 2>/dev/null; wait "$ticker" 2>/dev/null; echo
    # tar exits 1 when a file changed while being read (a browser, say): the archive is still good
    [ $rc -le 1 ] || { sudo rm -f "$partial"; die "tar failed (exit $rc), nothing written"; }
    [ $rc -eq 0 ] || warn "some files changed while being archived (normal for a live session)"
    echo "Verifying (full read-back)..."
    sudo tar -I 'zstd -T0' -tf "$partial" > "$WORK/list" || { sudo rm -f "$partial"; die "archive does not read back cleanly, nothing kept"; }
    local bad=0
    for p in .bashrc .ssh .claude; do [ -e "$TARGET_HOME/$p" ] && ! grep -q "^$H/$p" "$WORK/list" && { warn "missing from archive: ~/$p"; bad=1; }; done
    for p in "${ARCHIVE_SYSTEM[@]}"; do [ -e "/$p" ] && ! grep -q "^$p" "$WORK/list" && { warn "missing from archive: /$p"; bad=1; }; done
    grep -E "^$H/(Downloads|Screenshots|\.index)(/|$)" "$WORK/list" | head -3 | grep . && { warn "excluded folder found in archive"; bad=1; }
    [ $bad -eq 0 ] || { sudo rm -f "$partial"; die "archive check failed, nothing kept"; }
    sudo mv -f "$partial" "$ARCHIVE_PATH"
    echo "Archive OK: $ARCHIVE_PATH  $(du -h "$ARCHIVE_PATH" | cut -f1)  $(wc -l < "$WORK/list") entries"
}

pub_sync() {   # live system -> $STAGE/files + $STAGE/lists.txt (in --dry-run $STAGE is a scratch copy, the repo is untouched)
    local F=$STAGE/files f rel k t base
    rsync -rltE --delete --safe-links --exclude=__pycache__ --exclude='*.bak*' --exclude='*.pyc' "$TARGET_HOME/Software/asahi_atomic"/ "$F/Software/asahi_atomic"/ || warn "rsync failed: asahi_atomic"
    while IFS= read -r -d '' f; do          # system files already tracked in files/system
        rel=${f#"$F/system/"}
        [ "$rel" = etc/rpm/macros.image-language-conf ] && continue      # repo-only: installed by the repos phase, absent on A
        if [ -r "/$rel" ]; then rsync -ltE "/$rel" "$f"; else warn "tracked system file unreadable/missing: /$rel"; fi
    done < <(find "$F/system" -type f -print0)
    for f in /etc/yum.repos.d/*.repo; do    # unowned repo files are picked up automatically
        rpm -qf "$f" >/dev/null 2>&1 || { [ -e "$F/system${f}" ] || echo "new unowned repo file: $f"; rsync -ltE "$f" "$F/system/etc/yum.repos.d/"; }
    done
    # package lists: install/remove/closure regenerated against the Minimal baseline; enable/disable kept as they are
    base=$(ls "$TARGET_HOME"/Software/asahi_atomic/baseline-remix44-minimal-packages_*.txt 2>/dev/null | tail -1)
    [ -n "$base" ] || die "no baseline-remix44-minimal-packages_*.txt in ~/Software/asahi_atomic"
    t=$WORK/lists; mkdir -p "$t"
    sort -u "$base" > "$t/minimal"
    rpm -qa --qf '%{NAME}.%{ARCH}\n' | sort -u > "$t/have"
    dnf repoquery --userinstalled --qf '%{name}.%{arch}\n' 2>/dev/null | sort -u > "$t/user"
    [ -s "$t/user" ] || die "dnf repoquery --userinstalled returned nothing"
    comm -23 "$t/user" "$t/minimal" > "$t/install"
    comm -23 "$t/minimal" "$t/have" > "$t/remove"
    {
        echo "# Machine-readable lists for rebuild.sh. Regenerated by 'rebuild.sh publish' on $(date +%F) against $(basename "$base") (F44 Asahi Remix)."
        for k in install remove; do echo "[$k]"; cat "$t/$k"; done
        for k in enable disable; do echo "[$k]"; section "$k"; done
        echo "[closure]"; cat "$t/have"
    } > "$STAGE/lists.txt"
    # GNOME settings (volatile history/path keys and per-connection nm-applet sections dropped)
    dconf dump / | awk '
        /^\[/ { skip = ($0 ~ /^\[org\/gnome\/nm-applet\//) }
        skip { next }
        /^(last-save-directory|last-folder-path|command-history|looking-glass-history)=/ { next }
        { print }' > "$F/dconf-user.ini"
}

pub_gh_ready() {   # push rights on the repo, or explain how to log in and retry
    local slug
    slug=$(git -C "$REPO_DIR" remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')
    while ! [ "$(gh api "repos/$slug" --jq .permissions.push 2>/dev/null)" = true ]; do
        echo "GitHub login unsuccessful (or no push access to $slug)."
        echo "  To log in, run this in the terminal:   gh auth login      (GitHub.com > HTTPS > log in with a web browser)"
        echo "  then:                                  gh auth setup-git"
        pause "Press Enter to try again (Ctrl+C to quit). "
    done
}

pub_github() {
    say "2/4 GitHub"
    local STAGE=$REPO_DIR
    if [ $DRY -eq 1 ]; then      # work on a scratch copy of the repo files so nothing real changes
        STAGE=$WORK/preview; mkdir -p "$STAGE"; cp -a "$REPO_DIR/files" "$REPO_DIR/lists.txt" "$STAGE"/
    fi
    pub_gh_ready
    pub_sync
    # --- secrets scan: every hit is shown; "skip? y" keeps that file out of the commit, "n" includes it
    local hits=() skip=() line file p
    mapfile -t hits < <(grep -rIEn -e '-----BEGIN [A-Z ]*PRIVATE KEY' -e 'gh[pousr]_[A-Za-z0-9]{30,}' -e 'github_pat_' -e 'sk-ant-[A-Za-z0-9]' \
        -e 'AKIA[0-9A-Z]{16}' -e '(password|passwd|psk|secret|api[_-]?key|token)[[:space:]]*[=:][[:space:]]*[^[:space:]]{6,}' \
        "$STAGE/files" "$STAGE/lists.txt" 2>/dev/null)
    for p in "${ARCHIVE_SYSTEM[@]}"; do [ -e "$STAGE/files/system/$p" ] && hits+=("$STAGE/files/system/$p:0:private path that belongs in the archive only"); done
    for line in "${hits[@]}"; do
        file=${line%%:*}
        [[ " ${skip[*]:-} " == *" $file "* ]] && continue
        printf '\n  %s\n' "${line/#$STAGE\//}" | cut -c1-200
        confirm "  skip?" && skip+=("$file")
    done
    # --- what would change
    local rel_skip=() n ahead
    for file in "${skip[@]}"; do rel_skip+=("${file#"$STAGE"/}"); done
    git -C "$REPO_DIR" fetch -q origin 2>/dev/null
    ahead=$(git -C "$REPO_DIR" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    if [ $DRY -eq 1 ]; then
        n=$(diff -rq "$REPO_DIR/files" "$STAGE/files" 2>/dev/null | wc -l); diff -q "$REPO_DIR/lists.txt" "$STAGE/lists.txt" >/dev/null || n=$((n+1))
        echo "[dry-run] $n repo file(s) would change, ${#rel_skip[@]} skipped, $ahead unpushed commit(s). Nothing committed or pushed."
        COMMIT=$(git -C "$REPO_DIR" rev-parse --short HEAD)
        return 0
    fi
    n=$(git -C "$REPO_DIR" status --porcelain | wc -l)
    if [ "$n" -eq 0 ] && [ "$ahead" -eq 0 ]; then echo "GitHub repo is already up to date."
    else
        confirm "Push to Github? ($n changed file(s), ${#rel_skip[@]} skipped)" || die "aborted"
        git -C "$REPO_DIR" add -A
        [ ${#rel_skip[@]} -gt 0 ] && git -C "$REPO_DIR" reset -q -- "${rel_skip[@]}"
        git -C "$REPO_DIR" diff --cached --quiet || git -C "$REPO_DIR" commit -q -m "sync $(date +%F)"
        git -C "$REPO_DIR" push -q origin main || die "push failed"
    fi
    COMMIT=$(git -C "$REPO_DIR" rev-parse --short HEAD)
    echo "Verifying GitHub..."
    git -C "$REPO_DIR" fetch -q origin
    [ "$(git -C "$REPO_DIR" rev-parse HEAD)" = "$(git -C "$REPO_DIR" rev-parse origin/main)" ] || die "origin/main does not match the local commit"
    echo "origin/main = local commit $COMMIT."
    curl -fsSL https://raw.githubusercontent.com/memory-colors/asahi-a/main/bootstrap.sh 2>/dev/null | cmp -s - "$REPO_DIR/bootstrap.sh" \
        && echo "bootstrap.sh is downloadable from raw.githubusercontent.com." \
        || warn "could not confirm bootstrap.sh via raw.githubusercontent.com (GitHub's cache can lag a few minutes)"
}

pub_cleanup() {
    say "3/4 cleanup"
    local items=() f
    for f in "$DEST"/*.partial; do [ -e "$f" ] && items+=("$f"); done
    case $WORK in /tmp/asahi-publish.*) items+=("$WORK") ;; esac
    if [ ${#items[@]} -eq 0 ]; then echo "Nothing to clean up."; return 0; fi
    echo "Left over from this run:"; for f in "${items[@]}"; do printf '  %s  (%s)\n' "$f" "$(du -sh "$f" 2>/dev/null | cut -f1)"; done
    if confirm "Delete these?"; then for f in "${items[@]}"; do rm -rf -- "$f"; done; echo "Deleted."; fi
}

pub_readme() {
    say "4/4 restore README"
    local out; out=$DEST/$(date +%F)_asahi_restore_README.txt
    [ $DRY -eq 1 ] && out=$WORK/$(date +%F)_asahi_restore_README.txt
    cat > "$out" <<TXT
Restore Fedora Asahi Remix 44 ("A") from scratch - written $(date +%F) by rebuild.sh publish

Archive: $(basename "$ARCHIVE_PATH")  (in this folder; unencrypted: it holds keys, history and Wi-Fi passwords, keep it on this drive only)
GitHub:  https://github.com/memory-colors/asahi-a  (commit ${COMMIT:-?})

1. From macOS run the Asahi installer and install Fedora Asahi Remix 44 MINIMAL. Create the user "$TARGET_USER". Boot, log in, connect to the network.
2. Plug in the drive that holds this file.
3. Run:
     curl -fsSL https://raw.githubusercontent.com/memory-colors/asahi-a/main/bootstrap.sh | sudo bash
   It clones the repo to /root/asahi-a and runs rebuild.sh. Every phase asks first (repos, packages, files, services, apps, archive, verify);
   dnf shows its own prompts, there is no -y. In the "archive" phase it lists every *_asahi_home_full.tar.zst it can find - enter the letter
   of the one you want. If the drive is not mounted it offers to mount it read-only.
4. Reboot, then:  sudo /root/asahi-a/rebuild.sh verify

Not automated (do by hand if wanted): bleachbit locale cleanup; dracut/plymouth initramfs rebuild; bootloader / m1n1;
Claude Code install:  curl -fsSL https://claude.ai/install.sh | bash   (as $TARGET_USER)

Not in the archive: ~/Downloads, ~/Screenshots, ~/Screencasts, ~/Pictures, ~/Photo, ~/Video, ~/Music, ~/Audio, ~/Movies, ~/.index, caches, Trash, LosslessCut and czkawka-gui (the "apps" phase downloads those).
TXT
    echo "Wrote $out"
    [ $DRY -eq 1 ] && cat "$out"
    return 0
}

publish() {
    [ "$(id -u)" -ne 0 ] || die "run as $TARGET_USER, not root (publish uses sudo itself, only for the archive)"
    [ "$(id -un)" = "$TARGET_USER" ] || die "run as $TARGET_USER"
    local c; for c in rsync zstd git gh tar sudo curl numfmt dnf; do command -v "$c" >/dev/null || die "$c missing"; done
    WORK=$(mktemp -d /tmp/asahi-publish.XXXXXX)
    [ $DRY -eq 1 ] && echo "(dry-run: asks the same questions, writes nothing to the drive, the repo or GitHub)"
    pub_archive
    pub_github
    pub_cleanup
    pub_readme
    pause "Done. Press Enter to close. "
}

# =================================================================================================================
# RESTORE: archive phase
# =================================================================================================================

mountable_parts() {   # NAME|FSTYPE|SIZE|LABEL of unmounted partitions with a filesystem we can read
    local l
    lsblk -P -o NAME,TYPE,FSTYPE,SIZE,LABEL,MOUNTPOINT 2>/dev/null | while read -r l; do
        ( eval "$l"
          [ "$TYPE" = part ] && [ -z "$MOUNTPOINT" ] || exit 0
          case $FSTYPE in exfat|ext4|btrfs|xfs|vfat|ntfs) echo "$NAME|$FSTYPE|$SIZE|$LABEL" ;; esac )
    done
}

phase_archive() {
    say "archive"
    local opts=() mounted=() i pick kind val name fs size label
    if [ -n "$ARCHIVE" ]; then
        [ -f "$ARCHIVE" ] || die "$ARCHIVE is not a file"
    else
        while :; do
            opts=()
            while IFS= read -r val; do [ -n "$val" ] && opts+=("A|$val"); done < <(find /run/media /mnt /persist -maxdepth 4 -type f -name '*_asahi_home_full.tar.zst' 2>/dev/null | sort -r)
            [ ${#opts[@]} -gt 0 ] && echo "found:" || echo "no *_asahi_home_full.tar.zst found on a mounted drive."
            while IFS= read -r val; do [ -n "$val" ] && opts+=("M|$val"); done < <(mountable_parts)
            [ ${#opts[@]} -eq 0 ] && echo "(no drives to mount either)"
            for i in "${!opts[@]}"; do
                kind=${opts[i]%%|*}; val=${opts[i]#*|}
                if [ "$kind" = A ]; then printf '  %s. %s\n' "$(letter "$i")" "$val"
                else IFS='|' read -r name fs size label <<<"$val"; printf '  %s. mount /dev/%s (%s, %s, "%s") and look inside\n' "$(letter "$i")" "$name" "$fs" "$size" "$label"; fi
            done
            [ $DRY -eq 1 ] && { echo "[dry-run] would ask for a letter here"; return 0; }
            read -r -p "enter letter to select (Enter = rescan, q = skip this phase): " pick < "$TTY_IN" || return 0
            [ "$pick" = q ] && return 0
            for i in "${!opts[@]}"; do
                [ "$pick" = "$(letter "$i")" ] || continue
                kind=${opts[i]%%|*}; val=${opts[i]#*|}
                if [ "$kind" = A ]; then ARCHIVE=$val; break 2; fi
                name=${val%%|*}
                mkdir -p "/mnt/restore-$name" && mount -o ro "/dev/$name" "/mnt/restore-$name" && mounted+=("/mnt/restore-$name") || warn "mount of /dev/$name failed"
            done
        done
    fi
    echo "Using $ARCHIVE"
    echo "Unpacks over / with the original owners and modes (expects $TARGET_USER = uid 1000)."
    tar -I zstd -tf "$ARCHIVE" | sed -n '1,12p'; echo "..."
    ask "Unpack it over the system now?" || return 0
    run tar -I zstd -xpf "$ARCHIVE" -C / --numeric-owner
    # the SF fonts are stored once (user copy); root GUI apps (pkexec) need them system-wide too
    local d
    for d in "$TARGET_HOME"/.local/share/fonts/SF-*; do [ -d "$d" ] && run cp -a "$d" /usr/share/fonts/; done
    run chmod 600 /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null
    run restorecon -RF /etc/NetworkManager /etc/mullvad-vpn /usr/share/icons /usr/share/fonts /var/lib/AccountsService "$TARGET_HOME" 2>/dev/null
    run fc-cache -f
    as_user fc-cache -f
    run gtk-update-icon-cache -f -q /usr/share/icons/MacTahoe-nord-dark 2>/dev/null
    run nmcli connection reload 2>/dev/null
    for d in "${mounted[@]}"; do umount "$d" 2>/dev/null && rmdir "$d"; done
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

if [ $PUBLISH -eq 1 ]; then publish; exit $?; fi
preflight
for p in "${PHASES[@]}"; do
    case $p in
        repos|packages|files|services|apps|archive|verify)
            if [ "$p" = verify ] || ask "Run phase '$p'?"; then "phase_$p" || warn "phase $p reported problems"; fi ;;
        *) die "unknown phase: $p" ;;
    esac
done
say "finished - reboot, then run: sudo ./rebuild.sh verify"
