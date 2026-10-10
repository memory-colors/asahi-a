#!/usr/bin/env bash
# b-tools.sh - maintenance/diagnostic helpers for Asahi A <-> B (merged 2026-10-05 from check-a-leftovers.sh,
# diagnose-b-boot.sh, diagnose-b-space.sh and chroot-into-b.sh; logic copied unchanged, one file instead of four).
#
#   sudo bash b-tools.sh leftovers [--clean]                      report (or remove) root-owned build leftovers on A and
#                                                                 check A has no stray Plan-A/live-boot remnants
#   sudo bash b-tools.sh diagnose-boot <B-boot-part> <B-root-part>  READ-ONLY: what is in B's boot partition (why GRUB shows no OS entries)
#   sudo bash b-tools.sh diagnose-space <B-root-part>               READ-ONLY: where space is going on B's root (subvolid=5)
#   bash b-tools.sh amnesia-write                                  (run ONCE on B's golden entry, then reboot into the same entry)
#   bash b-tools.sh amnesia-check                                  (after that reboot: PASS/FAIL that nothing persisted - the test that matters)
#   sudo bash b-tools.sh chroot <B-root-part> [-- command...]       mount B under /mnt/asahi-b and chroot (interactive, or one command).
#                                                                 Remaining routine use: the two one-time grub.cfg patches in the APPENDIX of
#                                                                 rebuild-golden-b.sh after a fresh asahi-installer provision; also ad-hoc inspection.
#                                                                 Find B's root: lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT
# (amnesia-write/-check merged 2026-10-05 from b-amnesia-selftest-write.sh / -check.sh.)
# Each subcommand runs in its own subshell so its traps/cleanup stay local.

cmd_leftovers() (
  set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo: sudo bash $0 leftovers [--clean]" >&2
    exit 1
fi

CLEAN=0
[ "${1:-}" = "--clean" ] && CLEAN=1

echo "== Staging dir from build-atomic-image.sh / rebuild-golden-b.sh runs =="
STAGING="/root/atomic-image-staging"
if [ -d "$STAGING" ]; then
    du -sh "$STAGING" 2>/dev/null
    ls -la "$STAGING"
    if [ "$CLEAN" -eq 1 ]; then
        echo "Removing $STAGING"
        rm -rf "$STAGING"
    fi
else
    echo "None found - clean."
fi

echo
echo "== Stray LiveOS/squashfs.img at A's own top-level btrfs subvol (id 5) =="
TMPCHK="$(mktemp -d)"
CURRENT_ROOT_SRC="$(findmnt -no SOURCE / | sed 's/\[.*\]//')"
mount -o subvolid=5 "$CURRENT_ROOT_SRC" "$TMPCHK"
if [ -e "$TMPCHK/LiveOS/squashfs.img" ]; then
    du -sh "$TMPCHK/LiveOS/squashfs.img"
    if [ "$CLEAN" -eq 1 ]; then
        echo "Removing $TMPCHK/LiveOS/squashfs.img"
        rm -f "$TMPCHK/LiveOS/squashfs.img"
    fi
else
    echo "None found - clean (expected, per memory item 18's earlier cleanup)."
fi
ls -la "$TMPCHK"
umount "$TMPCHK"
rmdir "$TMPCHK"

echo
echo "== A's own BLS entries (should be exactly the normal kernel entries, no atomic/golden ones) =="
ls -la /boot/loader/entries/
echo
grep -H 'root=live' /boot/loader/entries/*.conf 2>/dev/null && echo "^^ UNEXPECTED: A has a live-boot BLS entry, investigate before removing anything." || echo "None found - clean (A should never have a root=live: entry, only B does)."

echo
if [ "$CLEAN" -eq 0 ]; then
    echo "Report-only run. Re-run with --clean to actually remove anything found above."
fi

)

cmd_diagnose_boot() (
  set -euo pipefail

BOOT_PART="${1:-}"
ROOT_PART="${2:-}"
[ -n "$BOOT_PART" ] && [ -n "$ROOT_PART" ] || {
    echo "Usage: sudo bash $0 diagnose-boot <B-boot-partition> <B-root-partition>" >&2
    exit 1
}

TMPBOOT="$(mktemp -d)"
TMPROOT="$(mktemp -d)"
cleanup() {
    umount "$TMPBOOT" 2>/dev/null || true
    umount "$TMPROOT" 2>/dev/null || true
    rmdir "$TMPBOOT" "$TMPROOT" 2>/dev/null || true
}
trap cleanup EXIT

echo "== Mounting $BOOT_PART read-only =="
mount -o ro "$BOOT_PART" "$TMPBOOT"

echo
echo "== $TMPBOOT/loader/entries/ =="
ls -la "$TMPBOOT/loader/entries/" 2>&1 || echo "(directory missing entirely!)"

echo
echo "== Contents of each .conf found =="
for f in "$TMPBOOT"/loader/entries/*.conf; do
    [ -e "$f" ] || { echo "(no .conf files at all)"; break; }
    echo "--- $f ---"
    cat "$f"
    echo
done

echo
echo "== vmlinuz-* / initramfs-* present on boot partition =="
ls -la "$TMPBOOT"/vmlinuz-* "$TMPBOOT"/initramfs-* 2>&1 || echo "(none found)"

echo
echo "== grubenv =="
grub2-editenv "$TMPBOOT/grub2/grubenv" list 2>&1 || echo "(could not read grubenv)"

echo
echo "== grub.cfg: does it actually invoke blscfg? =="
CFG="$TMPBOOT/grub2/grub.cfg"
if [ -f "$CFG" ]; then
    grep -nE 'blscfg|insmod blscfg' "$CFG" || echo "NO blscfg CALL FOUND IN grub.cfg - this alone would explain zero BLS entries showing"
else
    echo "grub.cfg missing entirely at $CFG"
fi

echo
echo "== grub.cfg: terminal/gfx lines (context from the readability fix) =="
grep -nE 'gfxmode|terminal_output|terminal_input|gfxterm|loadfont' "$CFG" 2>/dev/null || true

echo
echo "== Any .bak files from the fresh_boot_grub_readable_patch step (see rebuild-golden-b.sh appendix) =="
ls -la "$TMPBOOT"/grub2/grub.cfg.bak-* 2>&1 || echo "(none)"

umount "$TMPBOOT"

echo
echo "== Mounting $ROOT_PART (subvolid=5) read-only, checking /LiveOS =="
mount -o ro,subvolid=5 "$ROOT_PART" "$TMPROOT"
ls -la "$TMPROOT/LiveOS/" 2>&1 || echo "(LiveOS dir missing)"

echo
echo "== Done. Paste this whole output back. =="

)

cmd_diagnose_space() (
  set -euo pipefail

ROOT_PART="${1:-}"
[ -n "$ROOT_PART" ] || { echo "Usage: sudo bash $0 diagnose-space <B-root-partition>" >&2; exit 1; }

TMPROOT="$(mktemp -d)"
cleanup() { umount "$TMPROOT" 2>/dev/null || true; rmdir "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

mount -o ro,subvolid=5 "$ROOT_PART" "$TMPROOT"

echo "== ls -la (top level, including hidden entries the wipe loop's glob could miss) =="
ls -la "$TMPROOT"

echo
echo "== df -h =="
df -h "$TMPROOT"

echo
echo "== btrfs subvolume list (catches subvolumes even if hidden/dotfiles) =="
btrfs subvolume list "$TMPROOT" || true

echo
echo "== btrfs filesystem usage =="
btrfs filesystem usage "$TMPROOT" || true

echo
echo "== btrfs filesystem df =="
btrfs filesystem df "$TMPROOT" || true

echo
echo "== qgroups (can cause misleading free-space accounting if enabled) =="
btrfs qgroup show "$TMPROOT" 2>&1 || true

echo
echo "== du -sh of each top-level entry (actual space used, if readable) =="
for entry in "$TMPROOT"/* "$TMPROOT"/.*; do
    name="$(basename "$entry")"
    [ "$name" = "." ] || [ "$name" = ".." ] && continue
    [ -e "$entry" ] || continue
    du -sh --apparent-size "$entry" 2>/dev/null || echo "(could not du $entry)"
done

echo
echo "== Done. Paste this whole output back. =="

)

cmd_chroot_b() (
  set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo: sudo bash $0 chroot <root-partition> [-- command...]" >&2
    exit 1
fi

ROOT_PART="${1:-}"
[ -n "$ROOT_PART" ] || { echo "Usage: sudo bash $0 chroot <root-partition> [-- command...]" >&2; exit 1; }
[ -b "$ROOT_PART" ] || { echo "$ROOT_PART is not a block device" >&2; exit 1; }
shift || true
if [ "${1:-}" = "--" ]; then shift; fi
CMD=("$@")

MNT="/mnt/asahi-b"
mkdir -p "$MNT"

CURRENT_ROOT_SRC="$(findmnt -no SOURCE / | sed 's/\[.*\]//')"
if [ "$ROOT_PART" = "$CURRENT_ROOT_SRC" ]; then
    echo "Refusing: $ROOT_PART looks like Asahi A's own root device, not B's." >&2
    exit 1
fi

cleanup() {
    echo "== Cleaning up mounts under $MNT =="
    if [ -n "${RESOLV_BACKED_UP:-}" ]; then
        if [ -e "$MNT/etc/resolv.conf.asahi-b-orig" ]; then
            mv -f "$MNT/etc/resolv.conf.asahi-b-orig" "$MNT/etc/resolv.conf"
        fi
    fi
    for m in dev/pts dev sys proc run boot/efi boot home; do
        mountpoint -q "$MNT/$m" 2>/dev/null && umount -R "$MNT/$m" 2>/dev/null || true
    done
    mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "== Mounting B's root ($ROOT_PART) at $MNT =="
mount -o subvol=root "$ROOT_PART" "$MNT"

FSTAB="$MNT/etc/fstab"
[ -f "$FSTAB" ] || { echo "No fstab found at $FSTAB - is this really B's root?" >&2; exit 1; }

# B's fstab mounts /home as a SEPARATE subvolume (subvol=home) of the same
# device, not part of the root subvolume tree - mount it explicitly with the
# right subvol= option (the generic fstab-driven mount_from_fstab helper below
# doesn't parse mount options, so it can't be trusted for this one).
if grep -qE '^\S+\s+/home\s' "$FSTAB"; then
    echo "== Mounting B's home subvolume at $MNT/home =="
    mkdir -p "$MNT/home"
    mount -o subvol=home "$ROOT_PART" "$MNT/home"
fi

mount_from_fstab() {
    local target="$1" mountpoint_in_b="$2"
    local src fstype
    src="$(awk -v t="$mountpoint_in_b" '$2 == t {print $1; exit}' "$FSTAB")"
    fstype="$(awk -v t="$mountpoint_in_b" '$2 == t {print $3; exit}' "$FSTAB")"
    [ -n "$src" ] || { echo "No fstab entry for $mountpoint_in_b - skipping" >&2; return 0; }
    local dev="$src"
    case "$src" in
        UUID=*)     dev="/dev/disk/by-uuid/${src#UUID=}" ;;
        PARTUUID=*) dev="/dev/disk/by-partuuid/${src#PARTUUID=}" ;;
    esac
    echo "Mounting $mountpoint_in_b from $src ($dev, $fstype)"
    mkdir -p "$target"
    mount -t "$fstype" "$dev" "$target"
}

mount_from_fstab "$MNT/boot" "/boot"
mount_from_fstab "$MNT/boot/efi" "/boot/efi"

echo "== Bind-mounting proc/sys/dev/run =="
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /run "$MNT/run"

echo "== Wiring up DNS for dnf inside the chroot =="
if [ -e "$MNT/etc/resolv.conf" ] || [ -L "$MNT/etc/resolv.conf" ]; then
    mv -f "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.asahi-b-orig"
fi
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
RESOLV_BACKED_UP=1

if [ "${#CMD[@]}" -eq 0 ]; then
    echo "== Dropping into interactive chroot shell =="
    chroot "$MNT" /bin/bash
else
    echo "== Running: ${CMD[*]} =="
    chroot "$MNT" "${CMD[@]}"
fi

)

cmd_amnesia_write() (
  # run ONCE on B's golden/amnesiac entry (paste or run from a USB stick; B won't keep this file)
set -x

echo "=== FULL MOUNT TABLE (look for ANY writable real-disk source - none should exist) ==="
findmnt

echo
echo "=== Writing test files across every subsystem that's ever been a suspect in this project ==="
echo "test-home" | sudo tee /home/blank/AMNESIA_TEST_home.txt
echo "test-etc"  | sudo tee /etc/AMNESIA_TEST_etc.txt
echo "test-var"  | sudo tee /var/AMNESIA_TEST_var.txt
echo "test-root" | sudo tee /root/AMNESIA_TEST_root.txt
echo "test-boot" | sudo tee /boot/AMNESIA_TEST_boot.txt
echo "test-opt"  | sudo tee /opt/AMNESIA_TEST_opt.txt

echo
echo "=== Installing a real package (exercises /var/lib/rpm + /usr writes, not just plain files) ==="
sudo dnf install -y cowsay

echo
echo "=== Creating a test user (exercises /etc/passwd, /etc/shadow, and /home creation) ==="
sudo useradd -m amnesiatest

echo
echo "=== Changing a GNOME/dconf setting (exercises the dconf database, not just flat files) ==="
gsettings set org.gnome.desktop.interface clock-show-seconds true
gsettings get org.gnome.desktop.interface clock-show-seconds

echo
echo "=== WRITE PHASE DONE. Reboot into this SAME entry now, then run the check script. ==="

)

cmd_amnesia_check() (
  # run after rebooting into the SAME golden entry; prints PASS/FAIL per item
set +x

echo "=== FULL MOUNT TABLE (compare against what you noted before reboot) ==="
findmnt

FAIL=0

echo
echo "=== Test files (all should be gone) ==="
for f in /home/blank/AMNESIA_TEST_home.txt /etc/AMNESIA_TEST_etc.txt \
         /var/AMNESIA_TEST_var.txt /root/AMNESIA_TEST_root.txt \
         /boot/AMNESIA_TEST_boot.txt /opt/AMNESIA_TEST_opt.txt; do
    if sudo test -e "$f"; then
        echo "FAIL: $f STILL EXISTS"
        FAIL=1
    else
        echo "PASS: $f is gone"
    fi
done

echo
echo "=== Test package (should NOT be installed) ==="
if rpm -q cowsay >/dev/null 2>&1; then
    echo "FAIL: cowsay is still installed"
    FAIL=1
else
    echo "PASS: cowsay is gone"
fi

echo
echo "=== Test user (should NOT exist) ==="
if id amnesiatest >/dev/null 2>&1; then
    echo "FAIL: amnesiatest user still exists"
    FAIL=1
else
    echo "PASS: amnesiatest user is gone"
fi

echo
echo "=== dconf setting (should be back to default, i.e. NOT true) ==="
VAL="$(gsettings get org.gnome.desktop.interface clock-show-seconds)"
echo "Current value: $VAL"
if [ "$VAL" = "true" ]; then
    echo "FAIL: setting change persisted"
    FAIL=1
else
    echo "PASS: setting reverted to default"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "===== ALL CHECKS PASSED - B is amnesiac across every subsystem tested ====="
else
    echo "===== AT LEAST ONE CHECK FAILED - report exactly which one(s) above ====="
fi

)

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in
    leftovers)       shift; cmd_leftovers "$@" ;;
    diagnose-boot)   shift; cmd_diagnose_boot "$@" ;;
    diagnose-space)  shift; cmd_diagnose_space "$@" ;;
    chroot)          shift; cmd_chroot_b "$@" ;;
    amnesia-write)   shift; cmd_amnesia_write "$@" ;;
    amnesia-check)   shift; cmd_amnesia_check "$@" ;;
    -h|--help|"")    usage ;;
    *)               echo "Unknown subcommand: $1" >&2; usage >&2; exit 1 ;;
esac
