#!/usr/bin/env bash
# Restores A from a backup made by backup-a-to-external.sh, onto a FRESH
# Fedora Asahi Remix Workstation/GNOME install. Run this from a normal GNOME
# Terminal after getting through the graphical initial-setup wizard (create
# the same username, e.g. 'blank') - nothing in this whole recovery needs the
# tiny pre-boot console, only this one ordinary terminal command.
#
# Usage: sudo bash restore-a-from-external.sh /run/media/<you>/X10_4TB
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run this with sudo: sudo bash $0 <external-drive-mountpoint>" >&2; exit 1; }

SRC_ROOT="${1:-}"
[ -n "$SRC_ROOT" ] || { echo "Usage: sudo bash $0 <external-drive-mountpoint>" >&2; exit 1; }
SRC="$SRC_ROOT/Software/asahi-restore-a-from-backup"
[ -d "$SRC" ] || { echo "$SRC not found - wrong drive/path?" >&2; exit 1; }

TARGET_USER="${SUDO_USER:-blank}"
id "$TARGET_USER" >/dev/null 2>&1 || { echo "User '$TARGET_USER' doesn't exist yet - create it in initial-setup first, matching A's username." >&2; exit 1; }

echo "== Step 1: repos (brave, veracrypt COPR, RPM Fusion, Asahi hotfixes/coprs) =="
if [ -f "$SRC/etc-yum-repos-d.tar.gz" ]; then
    tar -xzf "$SRC/etc-yum-repos-d.tar.gz" -C /etc
    restorecon -R /etc/yum.repos.d
else
    echo "No etc-yum-repos-d.tar.gz found - repos will need enabling manually before Step 2's install can resolve everything." >&2
fi

echo
echo "== Step 2: install packages A had that this fresh install doesn't =="
if grep -qi '^rpmfusion-free-release-' "$SRC/manifests/install-packages.txt" && ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    echo "Bootstrapping rpmfusion-free-release first (its GPG key file must exist on disk before other rpmfusion packages in the same transaction can verify against it)."
    dnf install -y --nogpgcheck rpmfusion-free-release
fi
mapfile -t TO_INSTALL < "$SRC/manifests/install-packages.txt"
if [ "${#TO_INSTALL[@]}" -gt 0 ]; then
    dnf install -y --allowerasing --skip-unavailable "${TO_INSTALL[@]}"
fi

echo
echo "== Step 3: remove packages A explicitly removed that this fresh install has by default =="
mapfile -t TO_REMOVE < "$SRC/manifests/remove-packages.txt"
if [ "${#TO_REMOVE[@]}" -gt 0 ]; then
    dnf remove -y "${TO_REMOVE[@]}" || echo "Some removals failed/already absent - check output above, not necessarily a problem." >&2
fi
dnf autoremove -y

# gnome-software (removed above) runs its own background update check during
# Step 2's big install and can queue a PackageKit offline-update transaction
# before it gets removed here - that stale "download-complete" record then
# lingers in dnf5's offline-transaction state and gets re-flagged as
# invalidated on every future live dnf transaction. Clear it now so it doesn't
# nag on every subsequent dnf command for the life of this install.
dnf offline clean || true

# squashfs-tools is essential tooling for this project's own B-build workflow
# (rebuild-golden-b.sh runs mksquashfs FROM A) but isn't necessarily in
# install-packages.txt as an explicit "userinstalled" package - if it was only
# ever present on old A as a transitive dependency of something else, the
# autoremove above can sweep it right back out after this same restore
# reinstalls it. Guarantee it explicitly, and mark it userinstalled so a
# future backup-a-to-external.sh run captures it in the manifest going
# forward instead of relying on this guaranteed-install line indefinitely.
dnf install -y squashfs-tools
dnf mark user squashfs-tools 2>/dev/null || true

echo
echo "== Step 4: flatpaks =="
if [ -s "$SRC/manifests/flatpak-apps.txt" ]; then
    while read -r app; do
        [ -n "$app" ] || continue
        sudo -u "$TARGET_USER" flatpak install -y --user flathub "$app" \
            || flatpak install -y --system flathub "$app" \
            || echo "Could not install flatpak $app - check manually." >&2
    done < "$SRC/manifests/flatpak-apps.txt"
fi

echo
echo "== Step 5: restore /usr/share/icons =="
tar -xzf "$SRC/usr-share-icons.tar.gz" -C /usr/share
restorecon -R /usr/share/icons

echo
echo "== Step 6: restore home directory =="
tar -xzf "$SRC/home-blank.tar.gz" -C /home
chown -R "${TARGET_USER}:${TARGET_USER}" "/home/$TARGET_USER"
restorecon -R "/home/$TARGET_USER"

# If this script is run inside a live graphical session (as opposed to a bare
# TTY before first login), that session's already-running dconf-service has
# its own fresh-install-era database cached in memory and doesn't watch its
# file for external changes - it'll flush that stale in-memory copy back over
# the ~/.config/dconf/user we just restored, typically at the next logout,
# silently wiping wallpaper/theme/enabled-extensions. Kill it now so it starts
# fresh and picks up the restored file instead.
pkill -u "$TARGET_USER" dconf-service || true

echo
echo "== Step 7: targeted system-level files (reboot-picker, ydotool override, zram-generator.conf) =="
if [ -d "$SRC/system-files" ]; then
    for f in usr/local/bin/reboot-picker \
             usr/local/libexec/reboot-picker-helper \
             etc/sudoers.d/reboot-picker \
             etc/systemd/system/ydotool.service.d/override.conf \
             etc/systemd/zram-generator.conf; do
        if [ -f "$SRC/system-files/$f" ]; then
            mkdir -p "/$(dirname "$f")"
            cp "$SRC/system-files/$f" "/$f"
            chmod --reference="$SRC/system-files/$f" "/$f" 2>/dev/null || true
            echo "  restored: /$f"
        fi
    done
    chmod +x /usr/local/bin/reboot-picker /usr/local/libexec/reboot-picker-helper 2>/dev/null || true
    if [ -f /etc/sudoers.d/reboot-picker ]; then
        chmod 0440 /etc/sudoers.d/reboot-picker
        visudo -cf /etc/sudoers.d/reboot-picker || { echo "  WARNING: restored sudoers file failed validation - removing it rather than risk locking out sudo. Recreate manually." >&2; rm -f /etc/sudoers.d/reboot-picker; }
    fi
    systemctl daemon-reload
    echo
    echo "  NOTE: fstab.reference-only-do-not-blind-restore was captured but NOT"
    echo "  restored automatically - its UUIDs are specific to the old install."
    echo "  Check $SRC/system-files/fstab.reference-only-do-not-blind-restore"
    echo "  manually and re-add the /persist line (or others) with THIS"
    echo "  install's actual UUIDs/labels, not the old ones."
else
    echo "No system-files directory in backup - skipping."
fi

echo
echo "== Done. Reboot now so GNOME/icons/dconf all pick up cleanly. =="
echo "Sanity-check afterward: icon theme applied correctly, browser/apps present,"
echo "libreoffice/firefox/etc still correctly absent, flatpak app(s) present,"
echo "reboot-picker present and executable, ydotool socket override in place."
