#!/bin/bash
# rebuild.sh - recreate the "A" system (Fedora Asahi Remix 44 GNOME-ish) on top of a stock Remix 44 MINIMAL install.
#
#   sudo ./rebuild.sh [phase ...] [--archive DIR] [--dry-run]
#
# Phases (default = all, in this order; each one asks before it runs):
#   repos     rpm macro (no extra locales), RPM Fusion release, custom .repo files
#   packages  dnf install [install] list, then dnf remove [remove] list (capability-checked first)
#   files     system files (/etc, /usr, /var), home dotfiles/themes, dconf settings, SELinux relabel
#   services  enable / disable systemd units, default target
#   apps      LosslessCut + czkawka-gui from GitHub releases
#   archive   (only with --archive DIR) restore secrets/personal/big-theme data from your external drive
#   verify    compare installed packages and units against the recorded system (read-only)
#
# Design rules (user policy): NO dnf -y (dnf shows its own prompts, so you review every package list),
# nothing automated that can go sideways silently (bleachbit, initramfs, bootloader are NOT touched).
set -u
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LISTS=$REPO_DIR/lists.txt
TARGET_USER=blank          # paths in the saved configs (gdm autologin, symlinks, .desktop files) assume this
TARGET_HOME=/home/$TARGET_USER
DRY=0; ARCHIVE=""; PHASES=()

while [ $# -gt 0 ]; do
    case $1 in
        --dry-run) DRY=1 ;;
        --archive) ARCHIVE=${2:-}; shift ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) PHASES+=("$1") ;;
    esac
    shift
done
[ ${#PHASES[@]} -eq 0 ] && PHASES=(repos packages files services apps verify)
[ -n "$ARCHIVE" ] && [[ " ${PHASES[*]} " != *" archive "* ]] && PHASES+=(archive)

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
    as_user curl -fL -o "$TARGET_HOME/Software/czkawka-gui/czkawka_gui" "$cz" || warn "czkawka download failed"
    as_user chmod +x "$TARGET_HOME/Software/czkawka-gui/czkawka_gui"
}

phase_archive() {
    say "archive restore from $ARCHIVE"
    [ -d "$ARCHIVE" ] || die "$ARCHIVE is not a directory"
    echo "Layout expected: \$ARCHIVE/home/ -> $TARGET_HOME   \$ARCHIVE/system/ -> /   (see README.md)"
    ask "Copy it over the system now?" || return 0
    [ -d "$ARCHIVE/home" ]   && run "${RS_HOME[@]}" "$ARCHIVE/home"/ "$TARGET_HOME"/
    [ -d "$ARCHIVE/system" ] && run rsync -rltE "$ARCHIVE/system"/ /   # keeps archive owners/modes (root-owned secrets)
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

preflight
for p in "${PHASES[@]}"; do
    case $p in
        repos|packages|files|services|apps|archive|verify)
            if [ "$p" = verify ] || ask "Run phase '$p'?"; then "phase_$p" || warn "phase $p reported problems"; fi ;;
        *) die "unknown phase: $p" ;;
    esac
done
say "finished - reboot, then run: sudo ./rebuild.sh verify"
