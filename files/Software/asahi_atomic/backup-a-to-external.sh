#!/usr/bin/env bash
# Backs up A ITSELF to an external drive, so a total-loss scenario (all Asahi partitions deleted, or
# a macOS update breaks the boot chain) is recoverable via a fresh Fedora
# Asahi Remix Workstation/GNOME install + restore-a-from-external.sh, without
# needing to remember what was installed/removed/configured.
#
# Home dir and icons are captured as tar.gz archives, NOT raw rsync trees -
# the destination is exFAT, which can't represent symlinks or unix
# permissions faithfully. tar sidesteps that entirely regardless of what
# filesystem it's written to or extracted onto.
#
# Package state is captured as a diff against Fedora's own comps-group
# definition of a minimal GNOME install (core + standard + gnome-desktop
# groups), NOT dnf history's Reason=User field. Switched 2026-09-28 after
# directly comparing both methods: `dnf repoquery --userinstalled` produced
# 138 false positives (bash, systemd, gdm, gnome-shell, and others) that are
# only marked Reason=User because they were explicitly listed in the
# original kickstart transaction, not anything actually chosen later - pure
# noise for "what makes A different from a fresh minimal GNOME install."
# The comps-group diff has no such false positives:
#   - install-packages.txt: packages A has that the baseline group doesn't.
#   - remove-packages.txt: baseline packages A doesn't have (e.g.
#     libreoffice, firefox, nautilus, several default GNOME apps).
# dnf-history-full.txt is still captured below as a raw audit trail/safety
# net, but is no longer what the manifests themselves are derived from.
#
# Also captures: the whole /etc/yum.repos.d directory as a tar (brave,
# veracrypt COPR, RPM Fusion, Asahi hotfixes/coprs - restoring it directly
# means no separate "enable RPM Fusion" command needs to be replayed either),
# the flatpak app list, a full dnf history export as a safety net in case
# history itself is ever pruned before a rebuild happens, and a small set of
# targeted system-level files identified 2026-09-28 (not a full-system scan -
# just the specific spots this project is known to have touched): the
# reboot-picker script+helper in /usr/local, the ydotool systemd override,
# zram-generator.conf, and a reference copy of /etc/fstab (its /persist line
# is real and worth reapplying manually on restore - the file as a whole
# isn't blindly restorable since UUIDs will differ on a fresh install).
#
# Usage: bash backup-a-to-external.sh /run/media/blank/X10_4TB
set -euo pipefail

DEST_ROOT="${1:-}"
[ -n "$DEST_ROOT" ] || { echo "Usage: bash $0 <external-drive-mountpoint>" >&2; exit 1; }
[ -d "$DEST_ROOT" ] || { echo "$DEST_ROOT is not a directory - is the drive mounted?" >&2; exit 1; }

DEST="$DEST_ROOT/Software/asahi-restore-a-from-backup"
mkdir -p "$DEST/manifests"

# Archive the WHOLE /etc/yum.repos.d directory as one tar, rather than
# cp-ing individual repo files by name. Two real problems this avoids, found
# the hard way 2026-09-15: (1) COPR's repo-file naming convention embeds
# colons (_copr:server:group:project.repo), which exFAT - the likely
# destination filesystem for an external backup drive - cannot store as a
# bare filename at all (cp silently failed to persist the file here, while
# still printing its normal -v success line; only reproduced against the
# real exFAT destination, never against /tmp during testing). tar sidesteps
# this completely since colons inside an archive's internal entries are
# fine, only bare filesystem paths are restricted. (2) This also captures
# RPM Fusion's own generated .repo files directly, so restore no longer
# needs to separately replay an "enable RPM Fusion" command at all - just
# extracting this tarball back into /etc/yum.repos.d/ brings every repo
# (brave, veracrypt, RPM Fusion, Asahi hotfixes/coprs) back exactly as
# configured.
echo "== /etc/yum.repos.d (all repos, not just third-party ones - see comment above) =="
tar -czf "$DEST/etc-yum-repos-d.tar.gz" -C /etc yum.repos.d
du -h "$DEST/etc-yum-repos-d.tar.gz"

# Build archives in a scratch dir OUTSIDE /home first, then move into place -
# if DEST ever resolves to somewhere under /home (as it can - the destination
# is caller-supplied), taring /home/blank straight into a file that lives
# inside /home/blank makes tar try to read its own growing output file
# mid-write ("file changed as we read it", a real incident 2026-09-15,
# producing a corrupt archive that recursively contained itself). Building
# elsewhere and moving in afterward sidesteps this regardless of where DEST
# points.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# tar exits 1 for "some files changed as we read them" - expected on a live,
# actively-used home directory (something touching a dotfile, a lockfile, a
# recently-used entry, mid-scan), not a real failure. Only treat exit codes
# >1 as fatal.
tar_tolerant() {
    local rc=0
    tar "$@" || rc=$?
    if [ "$rc" -eq 1 ]; then
        echo "(note: tar reported files changed mid-read - normal for a live home dir, archive is still usable)" >&2
    elif [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
    return 0
}

echo "== Archiving /home/blank (excl. .cache) =="
tar_tolerant -czf "$SCRATCH/home-blank.tar.gz" --exclude='.cache' -C /home blank
mv "$SCRATCH/home-blank.tar.gz" "$DEST/home-blank.tar.gz"
du -h "$DEST/home-blank.tar.gz"

echo
echo "== Archiving /usr/share/icons (~1G, custom icon/cursor themes) =="
tar_tolerant -czf "$SCRATCH/usr-share-icons.tar.gz" -C /usr/share icons
mv "$SCRATCH/usr-share-icons.tar.gz" "$DEST/usr-share-icons.tar.gz"
du -h "$DEST/usr-share-icons.tar.gz"

echo
echo "== Package manifests (diff against core+standard+gnome-desktop baseline) =="
dnf group info core standard gnome-desktop 2>/dev/null | grep -E "^\s*:" | sed -E 's/^\s*:\s*//' | sort -u > "$DEST/manifests/.baseline-packages.txt"
rpm -qa --qf '%{NAME}\n' | sort -u > "$DEST/manifests/.current-packages.txt"
comm -23 "$DEST/manifests/.current-packages.txt" "$DEST/manifests/.baseline-packages.txt" > "$DEST/manifests/install-packages.txt"
comm -13 "$DEST/manifests/.current-packages.txt" "$DEST/manifests/.baseline-packages.txt" > "$DEST/manifests/remove-packages.txt"
rm -f "$DEST/manifests/.baseline-packages.txt" "$DEST/manifests/.current-packages.txt"
echo "$(wc -l < "$DEST/manifests/install-packages.txt") packages to install"
echo "$(wc -l < "$DEST/manifests/remove-packages.txt") packages to remove"

echo
echo "== Flatpak app list =="
flatpak list --app --columns=application 2>/dev/null > "$DEST/manifests/flatpak-apps.txt" || : > "$DEST/manifests/flatpak-apps.txt"
cat "$DEST/manifests/flatpak-apps.txt"

echo
echo "== Full dnf history export (safety net if history is ever pruned) =="
LAST_ID="$(dnf history list 2>/dev/null | awk 'NR==2{print $1}')"
dnf history list 2>/dev/null > "$DEST/manifests/dnf-history-list.txt"
: > "$DEST/manifests/dnf-history-full.txt"
for id in $(seq 1 "$LAST_ID"); do
    dnf history info "$id" 2>/dev/null >> "$DEST/manifests/dnf-history-full.txt"
    echo >> "$DEST/manifests/dnf-history-full.txt"
done

echo
echo "== Targeted system-level files (not a full scan - known-touched spots only) =="
mkdir -p "$DEST/system-files"
cp /etc/fstab "$DEST/system-files/fstab.reference-only-do-not-blind-restore"
for f in /usr/local/bin/reboot-picker \
         /usr/local/libexec/reboot-picker-helper \
         /etc/systemd/system/ydotool.service.d/override.conf \
         /etc/systemd/zram-generator.conf; do
    if [ -f "$f" ]; then
        rel="${f#/}"
        mkdir -p "$DEST/system-files/$(dirname "$rel")"
        cp "$f" "$DEST/system-files/$rel"
        echo "  captured: $f"
    else
        echo "  not present, skipped: $f"
    fi
done

# /etc/sudoers.d/reboot-picker is root:root mode 0440 - unreadable by this
# non-root script. Its content is static and already tracked as a plain
# user-readable source file, so grab that copy instead of the deployed one.
if [ -f "$HOME/Software/asahi_atomic/reboot-picker-sudoers" ]; then
    mkdir -p "$DEST/system-files/etc/sudoers.d"
    cp "$HOME/Software/asahi_atomic/reboot-picker-sudoers" "$DEST/system-files/etc/sudoers.d/reboot-picker"
    echo "  captured: /etc/sudoers.d/reboot-picker (from local source copy, not the 0440 deployed file)"
fi

echo
echo "== Done. Backed up to $DEST =="
du -sh "$DEST"
