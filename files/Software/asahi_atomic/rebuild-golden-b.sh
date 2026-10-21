#!/usr/bin/env bash
# ==========================================================================
# rebuild-golden-b.sh - THE sole B-provisioning script for this project.
# NOT the real disaster-recovery concern: B has no persistent state of its
# own (it's read-only/amnesiac by design) and can be regenerated from A at
# any time by just running this script again - a broken B is a non-issue.
# The actual disaster scenario is losing A itself, since A is the only copy
# of every real config/tweak/app-state this project has produced; that's
# covered by backup-a-to-external.sh / restore-a-from-external.sh instead.
# What THIS script does: rebuilds B's golden (read-only/amnesiac) OS from
# scratch, straight from A's own live filesystem.
#
# ARCHITECTURE: A is the tuned, mutable "golden source" (apps, dotfiles,
# config all live and get tweaked there - see asahi_atomic_build memory
# item 27). This script squashes A's own live root/home, builds a matching
# live-boot initramfs, and flashes both directly onto B's already-existing
# partitions (B's ESP/bootloader chain must already be provisioned via the
# macOS Recovery + asahi-installer flow - that registration step is an
# Apple-firmware-level thing that can only be done from Recovery, not from
# here; see memory item 13). There is NO separate "provision a desktop on B"
# step anymore - A already has everything, so just image A and flash it.
#
# POLICY: every run of this script WIPES whatever is currently on B (any
# prior golden image AND any leftover pre-golden conventional install) and
# replaces it with a fresh image, unconditionally, with no confirmation
# prompt and no separate flag to opt into it. There is deliberately no
# "keep the old one as a fallback until I've verified this boot" mode - if
# you want that safety net, don't run this script until you're actually
# ready to commit. Consequence: if a run's golden image somehow fails to
# boot, B has nothing else to fall back to until you rerun this script
# successfully. A is never touched by any of this and is always safe.
#
# WHAT THIS DOES, IN ORDER:
#   1. Build a squashfs of A's own live / (with /etc/fstab replaced by a
#      stripped placeholder - THE fix that took 5 debugging sessions to
#      find, see asahi_atomic_build memory items 29-33. Without this, every
#      write under /home silently persists across reboots because systemd
#      real-mounts /home straight off B's disk, live-boot or not. The exact
#      mksquashfs flag ORDERING matters too - see the comment at Step 1.)
#   2. VERIFY the squashfs's /etc/fstab is actually the stripped placeholder
#      BEFORE touching B at all - cheap, no-reboot-needed sanity check that
#      would have caught 3 of the last 4 failed fix attempts immediately.
#   3. Wipe B's root+boot partitions of everything except (nothing - this
#      deletes ALL of it: any prior golden BLS entry/kernel/initrd/squashfs,
#      and any leftover pre-golden conventionally-installed root/home
#      subvolumes). Then check the just-built squashfs will actually fit in
#      the now-empty partition BEFORE spending time building an initramfs -
#      fail fast instead of discovering a too-small partition at the very
#      last copy step.
#   4. Build a live-capable initramfs (dracut --add dmsquash-live) against
#      A's own running kernel.
#   5. Flash kernel+initrd+a static BLS entry onto B's /boot partition, and
#      the squashfs onto B's root partition's top-level subvolume (id 5).
#      B's root partition's current LABEL (not UUID - see 2026-09-19 note at
#      Step 6 for why) is read fresh and baked into the entry's
#      root=live:LABEL=... - never hardcode/reuse an old value.
#      No grubby involved at all here (a hand-written static .conf file) -
#      this sidesteps essentially all of the grubby/grub2-mkconfig
#      clone-on-existing-version and BLS-reconciliation gotchas that plagued
#      the old shared-install pipeline (memory items 3/4/5/9/11).
#   6. VERIFY the written BLS entry's options actually contain
#      root=live:LABEL=... before declaring success.
#
# On "making it immutable": there is no separate immutability step. It's an
# emergent property of two things this script already does: (a) the
# fstab-strip during imaging (Step 1) so nothing tries to real-mount a
# writable partition over the live root, and (b) booting with the right
# root=live:LABEL=...+rd.live.squashimg=... args (Step 5) so dracut's
# dmsquash-live module puts a tmpfs overlay on top of the read-only
# squashfs. Get those two right and "immutable" falls out automatically -
# there's nothing else to flip on.
#
# CAVEAT - the static-BLS-entry-writing mechanism in Step 5 (no grubby) is
# NEW, assembled from a previously-authored-but-never-actually-boot-tested
# script (flash-to-b.sh) in this same directory. The fstab-strip/mksquashfs
# logic in Steps 1-2 IS proven (real boot test passed earlier today). Treat
# the first real run of THIS script the same as every other change in this
# project's history: verify with an actual create-file/reboot/confirm-gone
# test before trusting it, don't assume success from this script exiting 0.
#
# GRUB READABILITY: this script never touches B's grub.cfg or /etc/default/
# grub - only /boot/loader/entries/asahi-golden.conf and grubenv (Step 5).
# The GRUB menu text-size fix lives entirely on B's own boot partition
# (fresh_boot_grub_readable_patch, in the APPENDIX at the bottom of THIS
# file - run once via chroot) and survives any number of reruns of THIS
# script untouched. Only re-run it if B's boot partition itself is ever
# wiped/reprovisioned from scratch via asahi-installer (see
# asahi_atomic_build memory item 42) - not needed on a routine "redo the
# image" rebuild.
#
# SCOPE LIMIT: this script only refreshes B's OS content. It assumes B's
# partition table + ESP + GRUB-in-ESP chain already exist from a prior
# asahi-installer run. If B's partitions don't exist at all (e.g. disk
# wiped), you must first go through macOS Recovery -> asahi-installer
# "install alongside" (any flavor - its root/boot content gets fully
# overwritten by this script anyway) to get partitions + firmware boot-icon
# registration in place - that part cannot be scripted from Linux at all
# (see asahi_atomic_build memory item 13). THEN run this script.
#
# USAGE:
#   sudo bash rebuild-golden-b.sh                                  (interactive)
#   sudo bash rebuild-golden-b.sh <B-root-partition> <B-boot-partition>  (scripted)
#
# Run with no arguments and it lists the current partition layout, suggests
# a target (preferring whatever partitions were used on the last successful
# run - that's the existing golden B - falling back to a filesystem-type
# heuristic otherwise), and requires a typed "YES" before touching anything.
# Partition numbers have shifted before, so don't hardcode old ones - pass
# both partitions on the command line only for scripted/automated reruns
# where you already know they're correct; that path skips the prompts.
#
# Manual check, if you want to sanity-check the suggestion yourself:
#   lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT
# B's root = the btrfs partition NOT currently mounted at / or /home.
# B's boot = the ~1G ext4 partition NOT currently mounted at /boot.
#
# AFTER RUNNING: reboot via the Apple firmware picker into B's icon, confirm
# it boots straight into the golden entry, create a throwaway file anywhere
# (e.g. `date > ~/test.txt`), reboot into the SAME entry again, and confirm
# the file is gone. There is nothing left to "reclaim" afterward - the wipe
# already happened up front, before this run's image was even written.
# ==========================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo: sudo bash $0 [B-root-partition] [B-boot-partition]" >&2
    exit 1
fi

# Moved up from its old spot near the marker-file logic further down - needed
# early now too, for the not-atomic-marker cleanup right below.
BUILD_USER="$(basename "$(ls -d /home/*/ 2>/dev/null | head -1)")"

# WiFi/Bluetooth-off-by-default-on-B, take 3. The two prior attempts (a
# `Before=`-ordered systemd unit trying to block the radios ahead of
# NetworkManager/bluetooth, then an `After=`-ordered one trying to block them
# once those services had settled) both failed a real boot test - radios
# were still on. Rather than keep guessing at ordering against services
# whose exact startup-state-restoration behavior isn't fully known, just
# disable the radios on A directly, right here, before A's own filesystem
# ever gets walked by mksquashfs - whatever state gets squashed IS the state
# B boots with, no service race to lose. Re-enabled on A immediately after
# the squash step finishes (see Step 2), so A's own daily-use WiFi/Bluetooth
# are only offline for the few minutes the squash itself takes.
echo "disconnecting wifi and bluetooth"
rfkill block wifi
rfkill block bluetooth

# Leftover from a PREVIOUS run's post-squash marker (see Step 2) - if this
# still exists on A, mksquashfs would squash it straight into THIS run's B
# image too, wrongly telling B "this is not atomic". Delete it before it can
# be walked; a fresh one gets written back onto A after this run's squash
# finishes, same as always.
NOT_ATOMIC_MARKER="/home/${BUILD_USER}/this_is_not_atomic.txt"
rm -f "$NOT_ATOMIC_MARKER"

STAGING="/root/atomic-image-staging"
mkdir -p "$STAGING"
STATE_FILE="${STAGING}/last-b-partitions"

ROOT_PART="${1:-}"
BOOT_PART="${2:-}"

CURRENT_ROOT_SRC="$(findmnt -no SOURCE / | sed 's/\[.*\]//')"
CURRENT_BOOT_SRC="$(findmnt -no SOURCE /boot | sed 's/\[.*\]//')"

# Pull one KEY="value" field out of an `lsblk -P` line without eval (eval
# would clobber $PATH itself, since that's also the lsblk column name).
lsblk_field() { echo "$1" | grep -oP "(?<=$2=\")[^\"]*"; }

# ---------------------------------------------------------------------------
# Interactive partition selection - only runs if the partitions weren't
# given on the command line. Lists the current layout, suggests a target,
# and makes the user explicitly confirm before anything destructive happens.
# Pass both partitions on the command line to skip this (scripted reruns).
# ---------------------------------------------------------------------------
if [ -z "$ROOT_PART" ] || [ -z "$BOOT_PART" ]; then
    echo "== No partitions given on the command line - entering interactive mode =="
    echo
    echo "Current partition layout:"
    lsblk -o NAME,PATH,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT
    echo
    echo "A's own root (never pick this): $CURRENT_ROOT_SRC"
    echo "A's own boot (never pick this): $CURRENT_BOOT_SRC"
    echo

    SUGGESTED_ROOT=""
    SUGGESTED_BOOT=""
    SUGGESTED_WHY=""

    # Prefer the exact partitions used on the last successful run - that IS
    # B, no guessing needed, and it survives partition numbers shifting
    # because it's keyed on PARTUUID, not /dev/nvme0n1pN.
    if [ -f "$STATE_FILE" ]; then
        LAST_ROOT_PARTUUID=""
        LAST_BOOT_PARTUUID=""
        LAST_RUN_DATE=""
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        CAND_ROOT=""
        CAND_BOOT=""
        [ -n "$LAST_ROOT_PARTUUID" ] && CAND_ROOT="$(blkid -t "PARTUUID=$LAST_ROOT_PARTUUID" -o device 2>/dev/null || true)"
        [ -n "$LAST_BOOT_PARTUUID" ] && CAND_BOOT="$(blkid -t "PARTUUID=$LAST_BOOT_PARTUUID" -o device 2>/dev/null || true)"
        if [ -n "$CAND_ROOT" ] && [ -n "$CAND_BOOT" ] \
            && [ "$CAND_ROOT" != "$CURRENT_ROOT_SRC" ] && [ "$CAND_BOOT" != "$CURRENT_BOOT_SRC" ]; then
            SUGGESTED_ROOT="$CAND_ROOT"
            SUGGESTED_BOOT="$CAND_BOOT"
            SUGGESTED_WHY="same partitions used on the last successful run (${LAST_RUN_DATE:-unknown date}) - this is the existing golden B"
        fi
    fi

    # Fall back to a heuristic: an unmounted btrfs partition (root) / an
    # unmounted ext4 partition (boot), neither of which is A's own.
    if [ -z "$SUGGESTED_ROOT" ]; then
        while IFS= read -r line; do
            p="$(lsblk_field "$line" PATH)"
            mp="$(lsblk_field "$line" MOUNTPOINT)"
            [ "$p" = "$CURRENT_ROOT_SRC" ] && continue
            [ "$mp" = "/" ] && continue
            [ "$mp" = "/home" ] && continue
            SUGGESTED_ROOT="$p"
            break
        done < <(lsblk -P -o PATH,FSTYPE,MOUNTPOINT | grep 'FSTYPE="btrfs"')
    fi
    if [ -z "$SUGGESTED_BOOT" ]; then
        while IFS= read -r line; do
            p="$(lsblk_field "$line" PATH)"
            mp="$(lsblk_field "$line" MOUNTPOINT)"
            [ "$p" = "$CURRENT_BOOT_SRC" ] && continue
            [ "$mp" = "/boot" ] && continue
            SUGGESTED_BOOT="$p"
            break
        done < <(lsblk -P -o PATH,FSTYPE,MOUNTPOINT | grep 'FSTYPE="ext4"')
    fi
    [ -z "$SUGGESTED_WHY" ] && [ -n "$SUGGESTED_ROOT" ] && [ -n "$SUGGESTED_BOOT" ] \
        && SUGGESTED_WHY="best guess: an unmounted btrfs/ext4 partition that isn't A's own - VERIFY against the listing above"

    if [ -n "$SUGGESTED_ROOT" ] && [ -n "$SUGGESTED_BOOT" ]; then
        echo "Suggested B root partition: $SUGGESTED_ROOT"
        echo "Suggested B boot partition: $SUGGESTED_BOOT"
        echo "  ($SUGGESTED_WHY)"
        echo
        read -rp "Use these? [Y/n] " ans
        case "$ans" in
            ""|[Yy]*)
                ROOT_PART="$SUGGESTED_ROOT"
                BOOT_PART="$SUGGESTED_BOOT"
                ;;
            *)
                read -rp "B root partition device: " ROOT_PART
                read -rp "B boot partition device: " BOOT_PART
                ;;
        esac
    else
        echo "Could not confidently suggest a target - enter B's partitions manually."
        read -rp "B root partition device: " ROOT_PART
        read -rp "B boot partition device: " BOOT_PART
    fi

    echo
    echo "About to WIPE and rebuild:"
    echo "  root: $ROOT_PART"
    echo "  boot: $BOOT_PART"
    read -rp "Proceed? [y/N] " confirm
    case "$confirm" in
        [Yy]*) ;;
        *) echo "Aborted, nothing touched." >&2; exit 1 ;;
    esac
    echo
fi

[ -n "$ROOT_PART" ] && [ -n "$BOOT_PART" ] || {
    echo "Usage: sudo bash $0 <B-root-partition> <B-boot-partition>" >&2
    echo "Find them with a fresh: lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT" >&2
    exit 1
}
[ -b "$ROOT_PART" ] || { echo "$ROOT_PART is not a block device" >&2; exit 1; }
[ -b "$BOOT_PART" ] || { echo "$BOOT_PART is not a block device" >&2; exit 1; }

if [ "$ROOT_PART" = "$CURRENT_ROOT_SRC" ] || [ "$BOOT_PART" = "$CURRENT_BOOT_SRC" ]; then
    echo "Refusing: that partition looks like Asahi A's own root/boot, not B's." >&2
    exit 1
fi
if [ "$ROOT_PART" = "$BOOT_PART" ]; then
    echo "Refusing: root and boot partition arguments are identical." >&2
    exit 1
fi

SQUASH_IMG="${STAGING}/squashfs.img"
NEW_INITRD="${STAGING}/initramfs-golden.img"
KVER="$(uname -r)"
VMLINUZ="/boot/vmlinuz-${KVER}"
[ -f "$VMLINUZ" ] || { echo "Kernel $VMLINUZ missing" >&2; exit 1; }

echo "Kernel version : $KVER"
echo "B root part    : $ROOT_PART"
echo "B boot part    : $BOOT_PART"
echo "This WILL wipe everything currently on both of those partitions."
echo

echo "== Step 1: ensure dracut-live and squashfs-tools are installed =="
rpm -q dracut-live >/dev/null 2>&1 || dnf install -y dracut-live
rpm -q squashfs-tools >/dev/null 2>&1 || dnf install -y squashfs-tools

echo
echo "== Step 2: build squashfs of A's live / (with fstab stripped) =="
rm -f "$SQUASH_IMG"

EXCLUDES=(
    "etc/fstab"
    "proc/*" "sys/*" "dev/*" "run/*" "tmp/*" "var/tmp/*"
    "boot/*"
    "persist/*"
    "var/swap/*"
    "LiveOS" "LiveOS/*"
    "mnt/*" "media/*"
    "var/cache/*" "var/log/journal/*" "var/lib/systemd/coredump/*"
    "lost+found"
    "root/atomic-image-staging/*"
)
for homedir in /home/*/; do
    user="$(basename "$homedir")"
    # Claude Code (.claude config/session + .local/share/claude + .local/bin/claude) is
    # kept in the image on purpose (policy since 2026-10-11: useful for live diagnosis on B).
    # Do not re-add those paths here.
    EXCLUDES+=("home/${user}/.cache/*" "home/${user}/Software/asahi_atomic/*.log" "home/${user}/Software/asahi_atomic/backups/*")
    # Brave stores its own regenerable browser cache under ~/.config instead of
    # respecting ~/.cache - found via a real ~184MB hit in a squash build (2026-09-21).
    # Cache only, never profile/bookmarks/history/passwords - safe to exclude entirely.
    BRAVE_DIR="home/${user}/.config/BraveSoftware/Brave-Browser"
    EXCLUDES+=(
        "${BRAVE_DIR}/Default/Service Worker/CacheStorage/*"
        "${BRAVE_DIR}/Default/Service Worker/ScriptCache/*"
        "${BRAVE_DIR}/component_crx_cache/*"
        "${BRAVE_DIR}/extensions_crx_cache/*"
        "${BRAVE_DIR}/GrShaderCache/*"
        "${BRAVE_DIR}/ShaderCache/*"
        "${BRAVE_DIR}/GraphiteDawnCache/*"
        "${BRAVE_DIR}/GPUPersistentCache/*"
        "${BRAVE_DIR}/Default/adblock_cache/*"
        "${BRAVE_DIR}/Default/DawnCache/*"
        "${BRAVE_DIR}/Default/DawnWebGPUCache/*"
        "${BRAVE_DIR}/Default/DawnGraphiteCache/*"
        "${BRAVE_DIR}/Default/GPUCache/*"
        "${BRAVE_DIR}/Default/Shared Dictionary/cache/*"
    )
    # Belt-and-suspenders alongside the excludes above: actively clear Brave's cache
    # on A itself too (not just keep it out of the squash), rather than relying only on
    # the named-subdir exclude list catching every cache dir Brave might ever create.
    # Cache only, safe with Brave still running (Chromium recreates these on demand) -
    # user confirmed no cache needs to persist on A at all.
    ABS_BRAVE_DIR="/home/${user}/.config/BraveSoftware/Brave-Browser"
    if [ -d "$ABS_BRAVE_DIR" ]; then
        echo "clearing Brave cache for ${user}"
        rm -rf \
            "${ABS_BRAVE_DIR}/Default/Service Worker/CacheStorage" \
            "${ABS_BRAVE_DIR}/Default/Service Worker/ScriptCache" \
            "${ABS_BRAVE_DIR}/component_crx_cache" \
            "${ABS_BRAVE_DIR}/extensions_crx_cache" \
            "${ABS_BRAVE_DIR}/GrShaderCache" \
            "${ABS_BRAVE_DIR}/ShaderCache" \
            "${ABS_BRAVE_DIR}/GraphiteDawnCache" \
            "${ABS_BRAVE_DIR}/GPUPersistentCache" \
            "${ABS_BRAVE_DIR}/Default/adblock_cache" \
            "${ABS_BRAVE_DIR}/Default/DawnCache" \
            "${ABS_BRAVE_DIR}/Default/DawnWebGPUCache" \
            "${ABS_BRAVE_DIR}/Default/DawnGraphiteCache" \
            "${ABS_BRAVE_DIR}/Default/GPUCache" \
            "${ABS_BRAVE_DIR}/Default/Shared Dictionary/cache"
    fi
done
echo "Exclude patterns: ${EXCLUDES[*]}"

FREE_GB="$(df --output=avail -BG / | tail -1 | tr -dc '0-9')"
echo "Free space on / before build: ${FREE_GB}G"

# SIZE WARNING (added 2026-10-10; silent unless flagged): the wipe of B happens BEFORE the old post-wipe fit check, so a build that is too big (e.g. big
# files on A that were meant to be deleted first) used to leave B empty. Rough early warning from A's raw used space: the last good image
# was ~35% of the walked data and A carries excluded caches, so raw used > ~2.8x B's root size means this build will probably not fit.
# (The exact check is right after the squash, still BEFORE B is touched: "Step 2b".)
ROOT_BYTES="$(blockdev --getsize64 "$ROOT_PART" 2>/dev/null || echo 0)"
A_USED_KB="$(df --output=used / | tail -1 | tr -dc '0-9')"
if [ "$ROOT_BYTES" -gt 0 ] && [ $((A_USED_KB * 1024 * 10)) -gt $((ROOT_BYTES * 28)) ]; then
    echo >&2
    echo "WARNING: A uses $((A_USED_KB/1024/1024))G but B's root partition is only $((ROOT_BYTES/1024/1024/1024))G; this build will probably not fit once squashed." >&2
    if [ -t 0 ]; then
        read -rp "Continue anyway? [y/N] " big_ok
        case "$big_ok" in [Yy]*) ;; *) echo "Aborted before building; B untouched." >&2; exit 1 ;; esac
    fi
fi

# One deliberate exception to the full-strip policy: if a partition labeled
# "persist" exists, mount it RW in B too (see asahi_atomic memory item 51 -
# this is an intentional, narrowly-scoped real mount, NOT a regression of
# items 29-33's bug, which was about accidentally real-mounting a path that's
# SUPPOSED to go through the tmpfs overlay, like /home. /persist is a wholly
# separate, dedicated partition that was never part of the overlay-protected
# tree to begin with.) Mounted by LABEL, not UUID (changed 2026-09-19) -
# persist gets reformatted (mkfs) every time it's recreated via
# shrink-b-add-partition.sh, which assigns it a fresh UUID each time but
# always the SAME label ("persist", set at mkfs time and never changed) -
# LABEL=persist means this fstab line, once baked into B, stays correct
# across a persist recreation WITHOUT needing a rebuild just to pick up a new
# UUID (confirmed real, hit twice: 2026-09-17 and 2026-09-19). The label
# itself is looked up fresh every build regardless (never hardcode/assume).
PERSIST_DEV="$(blkid -L persist 2>/dev/null || true)"
PERSIST_FSTYPE=""
[ -n "$PERSIST_DEV" ] && PERSIST_FSTYPE="$(blkid -s TYPE -o value "$PERSIST_DEV" 2>/dev/null || true)"

FSTAB_TMP="$(mktemp)"
echo "# stripped for live/amnesiac boot - see asahi_atomic memory item 31" > "$FSTAB_TMP"
if [ -n "$PERSIST_DEV" ]; then
    case "$PERSIST_FSTYPE" in
        exfat)
            # exFAT has no native permissions/ownership, so the whole
            # partition mounts as one fixed uid/gid/umask - fine for
            # media/VeraCrypt-container use (deliberately chosen 2026-09-17
            # for macOS interop), never for anything needing real per-file
            # permissions, symlinks, or SELinux xattrs.
            PERSIST_UID="$(id -u "$BUILD_USER" 2>/dev/null || echo 1000)"
            PERSIST_GID="$(id -g "$BUILD_USER" 2>/dev/null || echo 1000)"
            echo "LABEL=persist /persist exfat rw,nofail,uid=${PERSIST_UID},gid=${PERSIST_GID},umask=022,x-systemd.device-timeout=5s 0 0" >> "$FSTAB_TMP"
            ;;
        ""|ext4)
            echo "LABEL=persist /persist ext4 rw,nofail,x-systemd.device-timeout=5s 0 0" >> "$FSTAB_TMP"
            ;;
        *)
            echo "LABEL=persist /persist $PERSIST_FSTYPE rw,nofail,x-systemd.device-timeout=5s 0 0" >> "$FSTAB_TMP"
            echo "Note: persist partition filesystem '$PERSIST_FSTYPE' isn't ext4 or exfat - using generic mount options, verify these are appropriate for it." >&2
            ;;
    esac
    echo "Persist partition found ($PERSIST_DEV, fstype=${PERSIST_FSTYPE:-unknown}) - will be mounted RW at /persist in B via LABEL=persist."
else
    echo "No 'persist'-labeled partition found - B's fstab stays fully stripped, no persist mount."
fi

mkdir -p /persist

# Marker file baked into B only, never left sitting on A - visible proof
# when logged into B that it's actually the golden/amnesiac image, not A.
# Created for real just long enough for mksquashfs to walk over it, then
# removed immediately after - A itself never keeps a copy.
MARKER_FILE="/home/${BUILD_USER}/this_is_atomic.txt"
echo "Built $(date -Iseconds) from A's live filesystem by rebuild-golden-b.sh" > "$MARKER_FILE"
chown "${BUILD_USER}:${BUILD_USER}" "$MARKER_FILE"

# WiFi/Bluetooth-off-by-default handling itself moved to the very top of the
# script (disable) and right after mksquashfs below (re-enable + write
# this_is_not_atomic.txt) - see the comment up there for why the two
# systemd-unit-based attempts that used to live here were abandoned.

# Plymouth watermark (Fedora logo) and SMPlayer window geometry both used to
# be handled here as build-time-only mksquashfs pseudo-file overrides -
# removed 2026-09-18, both superseded by better fixes applied directly and
# permanently on A instead, which then just squash into B normally like any
# other file, no override needed:
#   - Plymouth watermark: A's real /usr/share/plymouth/themes/spinner/
#     watermark.png replaced with a 1x1 transparent PNG directly + A's own
#     initramfs regenerated (plymouth-set-default-theme -R), original
#     backed up to /root/watermark.png.orig-*.
#   - SMPlayer geometry: editing smplayer.ini's pos=/size= never actually
#     worked at all, on A or B - native Wayland does not let client apps set
#     their own absolute window position, confirmed via screenshot showing
#     the window landing wherever Mutter felt like regardless of the saved
#     value. Real fix is a ~/.local/bin/smplayer wrapper (shadows the real
#     /usr/bin/smplayer via PATH) that launches it and then fires a real
#     simulated Super+Right key event via ydotool, triggering GNOME's own
#     native tiling - the only thing that actually works. That wrapper lives
#     in the user's home directory, so it's already part of what gets
#     squashed here with no special-casing needed. (ydotoold itself - the
#     daemon ydotool talks to - runs as a system service, not part of A's
#     squashed filesystem at all, so B needs its own `sudo dnf install -y
#     ydotool` + the same systemd override once, not yet done as of this
#     comment - see asahi_atomic_build memory for the exact setup.)

# CRITICAL: -p (pseudo-file override) MUST appear before -wildcards/-e on
# the command line, AND the overridden path MUST also be listed in -e - miss
# either half and mksquashfs silently keeps (or silently drops entirely) the
# REAL /etc/fstab instead of this placeholder. Verified the hard way in an
# isolated /tmp sandbox before ever touching B - see memory item 33. Do not
# reorder these flags without re-reading that item first. Same rule applies
# to any other -p override added in the future - each one's path must also
# appear in -e.
PSEUDO_FILES=(
    "etc/fstab f 444 0 0 cat $FSTAB_TMP"
)
PSEUDO_EXCLUDES=("etc/fstab")

MKSQUASHFS_P_ARGS=()
for pf in "${PSEUDO_FILES[@]}"; do
    MKSQUASHFS_P_ARGS+=(-p "$pf")
done

# Without -noappend, mksquashfs MERGES into an existing destination file
# instead of replacing it - fatal if a prior run left a complete-but-unverified
# squashfs.img in STAGING (e.g. aborted later in Step 3). Force a clean start.
rm -f "$SQUASH_IMG"

# mksquashfs -wildcards uses fnmatch with FNM_PERIOD: "dir/*" does NOT match dot-entries, so hidden items under an excluded dir (e.g. /persist/.index, 6 GB of
# videos, found 2026-10-19 when the image came out 8.1G instead of ~3.5G) were squashed anyway. Add the dotted twin of every "dir/*" exclusion.
for _p in "${EXCLUDES[@]}"; do case "$_p" in */\*) EXCLUDES+=("${_p%\*}.*") ;; esac; done

mksquashfs / "$SQUASH_IMG" \
    -noappend \
    -comp zstd -Xcompression-level 3 \
    -processors "$(nproc)" \
    "${MKSQUASHFS_P_ARGS[@]}" \
    -wildcards \
    -e "${EXCLUDES[@]}" "${PSEUDO_EXCLUDES[@]}"

rm -f "$FSTAB_TMP" "$MARKER_FILE"

# Squash is done and A's own filesystem has already been walked - safe to
# bring A's own WiFi/Bluetooth back now (see the disable + explanation at
# the top of this script). Also write this run's "you're on A, not B" marker
# fresh - it's created AFTER the squash so it can never end up inside this
# run's image; the top of this script deletes any leftover copy from a PRIOR
# run before the NEXT squash ever walks A's filesystem again.
echo "reconnecting wifi and bluetooth"
rfkill unblock wifi
rfkill unblock bluetooth
NOT_ATOMIC_MARKER="/home/${BUILD_USER}/this_is_not_atomic.txt"
echo "Built $(date -Iseconds) - this is A (the mutable source), not the golden Asahi Atomic image." > "$NOT_ATOMIC_MARKER"
chown "${BUILD_USER}:${BUILD_USER}" "$NOT_ATOMIC_MARKER"

echo "Squashfs image built: $(du -h "$SQUASH_IMG" | cut -f1)"
NEED_KB="$(du -k "$SQUASH_IMG" | cut -f1)"

# Step 2b (added 2026-10-10): exact fit check BEFORE B is wiped. Btrfs needs some headroom for metadata, so allow 95% of the partition.
if [ "$ROOT_BYTES" -gt 0 ] && [ $((NEED_KB * 1024 * 100)) -gt $((ROOT_BYTES * 95)) ]; then
    echo "ABORTING before touching B: the squashfs ($((NEED_KB/1024))M) will not fit B's root partition ($((ROOT_BYTES/1024/1024))M, ~95% usable)." >&2
    echo "Free up space on A or grow B, then re-run." >&2
    exit 1
fi

echo
echo "== Step 3: verify the stripped fstab actually landed (before touching B) =="
CHECK_DIR="$(mktemp -d)"
unsquashfs -d "$CHECK_DIR/x" -f "$SQUASH_IMG" etc/fstab >/dev/null
if grep -q 'stripped for live' "$CHECK_DIR/x/etc/fstab" 2>/dev/null; then
    echo "OK - squashfs's etc/fstab is the stripped placeholder."
else
    echo "ABORTING: squashfs's etc/fstab still looks like a real fstab - the amnesia" >&2
    echo "bug (asahi_atomic_build memory items 29-33) would recur. Not touching B." >&2
    cat "$CHECK_DIR/x/etc/fstab" >&2 || true
    rm -rf "$CHECK_DIR"
    exit 1
fi
if [ -n "$PERSIST_DEV" ]; then
    if grep -q "LABEL=persist /persist " "$CHECK_DIR/x/etc/fstab" 2>/dev/null; then
        echo "OK - persist mount line for LABEL=persist landed correctly."
    else
        echo "ABORTING: expected a persist mount line for LABEL=persist but it's missing" >&2
        echo "from the built squashfs's etc/fstab. Not touching B." >&2
        cat "$CHECK_DIR/x/etc/fstab" >&2 || true
        rm -rf "$CHECK_DIR"
        exit 1
    fi
fi
rm -rf "$CHECK_DIR"

echo
echo "== Step 4: wipe B clean (unconditional - no prior image is kept) =="
TMPROOT="$(mktemp -d)"
TMPBOOT="$(mktemp -d)"
cleanup() {
    umount "$TMPBOOT" 2>/dev/null || true
    umount "$TMPROOT" 2>/dev/null || true
    rmdir "$TMPBOOT" "$TMPROOT" 2>/dev/null || true
}
trap cleanup EXIT

mount "$BOOT_PART" "$TMPBOOT"
[ -d "$TMPBOOT/loader/entries" ] || { echo "$TMPBOOT has no loader/entries - wrong partition?" >&2; exit 1; }
for f in "$TMPBOOT"/loader/entries/*.conf; do
    [ -e "$f" ] || continue
    echo "Removing $f"; rm -f "$f"
done
for f in "$TMPBOOT"/vmlinuz-* "$TMPBOOT"/initramfs-*; do
    [ -e "$f" ] || continue
    echo "Removing $f"; rm -f "$f"
done
umount "$TMPBOOT"

mount -o subvolid=5 "$ROOT_PART" "$TMPROOT"

# btrfs refuses to delete a subvolume that still has OTHER subvolumes nested
# inside it (e.g. systemd auto-creates /var/lib/machines and/or
# /var/lib/portables as real nested subvolumes whenever nspawn/portabled
# support is present, even if never used - "Directory not empty" is the
# real-world symptom, hit for real 2026-09-13). Delete every subvolume on
# this filesystem deepest-path-first BEFORE the top-level loop below, so any
# such nesting (at any depth, not just the one case seen so far) is already
# gone by the time we try to delete root/home/whatever contained it.
mapfile -t NESTED_SUBVOLS < <(btrfs subvolume list "$TMPROOT" 2>/dev/null | awk '{print $NF}' | awk -F'/' '{print (NF-1)"\t"$0}' | sort -t$'\t' -k1,1rn | cut -f2)
for relpath in "${NESTED_SUBVOLS[@]}"; do
    [ -n "$relpath" ] || continue
    [ -e "$TMPROOT/$relpath" ] || continue
    echo "Deleting nested subvolume: $relpath"
    btrfs subvolume delete "$TMPROOT/$relpath"
done

for entry in "$TMPROOT"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    if btrfs subvolume show "$entry" >/dev/null 2>&1; then
        echo "Deleting subvolume: $name"
        btrfs subvolume delete "$entry"
    else
        echo "Deleting: $name"
        rm -rf "$entry"
    fi
done
mkdir -p "$TMPROOT/LiveOS"

# The delete loop above frees a lot of space (the old golden image), but
# btrfs doesn't return an emptied data block group to "unallocated" on its
# own - df's avail figure right after a bulk delete can still reflect only
# whatever was ALREADY unallocated before the delete, undercounting real
# free space until something reclaims the now-empty block group. A targeted
# balance with usage=0 only rewrites block groups that are genuinely empty
# (nothing to relocate), so it's fast regardless of how much data is on the
# filesystem - not a real rebalance. See asahi_atomic memory item 58.
btrfs balance start -dusage=0 -musage=0 "$TMPROOT" || true

AVAIL_KB="$(df --output=avail "$TMPROOT" | tail -1 | tr -dc '0-9')"
echo "B root partition free space after wipe: $((AVAIL_KB/1024))M (squashfs needs $((NEED_KB/1024))M)"
if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
    echo "ABORTING: even after wiping everything else on B, its root partition only" >&2
    echo "has $((AVAIL_KB/1024))M free but the squashfs needs $((NEED_KB/1024))M. The" >&2
    echo "partition itself is too small for this image - shrink/grow partitions before" >&2
    echo "retrying. Nothing further has been written to B's boot partition yet." >&2
    exit 1
fi
umount "$TMPROOT"

echo
echo "== Step 5: build a live-capable initramfs (adds dmsquash-live) =="
dracut --force --no-hostonly --add "dmsquash-live" --kver "$KVER" "$NEW_INITRD"
echo "Initramfs built: $NEW_INITRD"
cp -f "$VMLINUZ" "${STAGING}/vmlinuz-golden"

echo
echo "== Step 6: flash onto B =="
# Mounted by LABEL, not UUID (changed 2026-09-19, after B's root was given a
# permanent unique label - "asahi_atomic" - specifically so it'd never
# collide with A's own root, which shares the SAME default "fedora" label
# asahi-installer assigns both). A btrfs resize (shrink-b-add-partition.sh)
# preserves the UUID, so this wasn't actually churning on every build the
# way persist's UUID was - but it's still looked up fresh each time, same
# "never hardcode" philosophy as everything else here, in case it's ever
# relabeled again.
ROOT_LABEL="$(blkid -s LABEL -o value "$ROOT_PART")"
[ -n "$ROOT_LABEL" ] || { echo "Could not read LABEL of $ROOT_PART - B's root must be labeled (currently expected: asahi_atomic)" >&2; exit 1; }
echo "B root partition LABEL: $ROOT_LABEL"

echo "Mounting B's boot partition..."
mount "$BOOT_PART" "$TMPBOOT"

cp -f "${STAGING}/vmlinuz-golden" "$TMPBOOT/vmlinuz-golden"
cp -f "$NEW_INITRD" "$TMPBOOT/initramfs-golden.img"

cat > "$TMPBOOT/loader/entries/asahi-golden.conf" <<EOF
title asahi_atomic
version golden
linux /vmlinuz-golden
initrd /initramfs-golden.img
options root=live:LABEL=${ROOT_LABEL} rd.live.dir=LiveOS rd.live.squashimg=squashfs.img rhgb quiet
id asahi-golden
grub_users \$grub_users
grub_arg --unrestricted
grub_class kernel-16k-atomic
EOF

if ! grep -q 'root=live:LABEL=' "$TMPBOOT/loader/entries/asahi-golden.conf"; then
    echo "ABORTING: written BLS entry doesn't contain root=live:LABEL= - something's wrong." >&2
    exit 1
fi
echo "BLS entry written and verified:"
cat "$TMPBOOT/loader/entries/asahi-golden.conf"

grub2-editenv "$TMPBOOT/grub2/grubenv" set saved_entry=asahi-golden
# menu_auto_hide is Fedora's standard grub.cfg mechanism (confirmed present
# in B's actual grub.cfg, /etc/grub.d/10_reset_boot_success +
# 12_menu_auto_hide) for hiding the boot menu without ever touching
# grub.cfg/GRUB_TIMEOUT_STYLE directly - not something this project's policy
# allows (see the GRUB READABILITY section above).
#
# CORRECTED 2026-09-20: the boot_success=1/boot_indeterminate=0 writes below
# (added 2026-09-19 to fix the menu reappearing) turned out to only ever fix
# the FIRST boot after a rebuild, not every boot. Real mechanism: grub.cfg's
# 10_reset_boot_success fragment computes menu_hide_ok from these two values
# on the way IN, then unconditionally resets boot_success back to 0 on disk
# before the OS even loads - by design, on the assumption that a systemd
# unit running INSIDE the booted OS will reconfirm success later and write
# boot_success=1 back. B never does that (amnesiac/live-booted, no such
# confirmation service runs), so: this script bakes boot_success=1 -> first
# boot post-rebuild reads it, correctly hides the menu, then resets it to 0
# on disk (normal Fedora behavior, not a bug) -> every boot after that reads
# boot_success=0/boot_indeterminate=0 -> menu_hide_ok=0 -> menu shows again.
# These two grub2-editenv lines are kept below because they're harmless and
# still correctly seed the FIRST post-rebuild boot, but **the actual fix
# lives on B's boot partition itself, in grub.cfg, not here**: see
# fresh_boot_grub_hide_menu_patch, in the APPENDIX at the bottom of THIS
# file - a one-time patch (same lifecycle as fresh_boot_grub_readable_patch
# - survives every rebuild since this script never touches grub.cfg, only
# needs redoing if B's boot partition is ever wiped and reprovisioned from
# scratch) that hardcodes menu_hide_ok=1 unconditionally, since B only ever
# has one entry and no real "pick a different kernel" recovery use case for
# the menu to protect anyway.
grub2-editenv "$TMPBOOT/grub2/grubenv" set menu_auto_hide=1
grub2-editenv "$TMPBOOT/grub2/grubenv" set boot_success=1
grub2-editenv "$TMPBOOT/grub2/grubenv" set boot_indeterminate=0
grub2-editenv "$TMPBOOT/grub2/grubenv" list

umount "$TMPBOOT"

echo "Mounting B's root partition at its top-level subvolume (id 5)..."
mount -o subvolid=5 "$ROOT_PART" "$TMPROOT"
mkdir -p "$TMPROOT/LiveOS"
cp -f "$SQUASH_IMG" "$TMPROOT/LiveOS/squashfs.img"
umount "$TMPROOT"

# Step 7: refresh B's own ESP firmware blob (m1n1+devicetree+u-boot) to match
# whatever kernel A is currently running. B's ESP is never reformatted (PARTUUID
# is permanent, see gotcha #11) but its firmware blob IS safe to rewrite in place -
# update-m1n1 does that, same as the kernel-install hook does for A's own ESP on
# every kernel change. Without this, B's devicetree-derived audio topology can go
# stale relative to the kernel actually running (confirmed real: snd-soc-macaudio
# failed to probe -22, TAS2764 woofer amp never appeared, because B's ESP still had
# the DTB from its original asahi-installer provisioning - audio-specific case of
# the firmware/kernel co-versioning risk in gotcha #19; fixed manually once
# 2026-10-11, now done automatically here on every rebuild).
# atomic-esp is the vfat FILESYSTEM label (the GPT PARTLABEL is empty on this machine), so look it up by label first, PARTLABEL as a fallback
ESP_PART="$(blkid -L atomic-esp 2>/dev/null || lsblk -rno PATH,PARTLABEL | awk '$2=="atomic-esp"{print $1; exit}')"
if [ -n "$ESP_PART" ]; then
    echo "Refreshing B's ESP firmware (update-m1n1) on $ESP_PART..."
    TMPESP="$(mktemp -d)"
    mount "$ESP_PART" "$TMPESP"
    update-m1n1 "$TMPESP/m1n1/boot.bin"
    umount "$TMPESP"
    rmdir "$TMPESP"
else
    echo "WARNING: could not find B's ESP (label atomic-esp) - skipping m1n1 firmware refresh. Audio (and possibly other devicetree-dependent hardware) may be stale on B after this rebuild if A's kernel has changed since B's ESP was last refreshed." >&2
fi

# Remember which partitions this run targeted (by PARTUUID, so it still
# resolves correctly even if /dev/nvme0n1pN numbers shift later) so the next
# no-argument run can suggest this exact target as "the existing golden B"
# instead of falling back to a heuristic guess.
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || true)"
BOOT_PARTUUID="$(blkid -s PARTUUID -o value "$BOOT_PART" 2>/dev/null || true)"
if [ -n "$ROOT_PARTUUID" ] && [ -n "$BOOT_PARTUUID" ]; then
    cat > "$STATE_FILE" <<EOF
LAST_ROOT_PARTUUID="$ROOT_PARTUUID"
LAST_BOOT_PARTUUID="$BOOT_PARTUUID"
LAST_RUN_DATE="$(date -Iseconds)"
EOF
fi

echo
echo "== Done building and flashing. =="
echo "B's default (and only) boot entry is now 'asahi_atomic' (read-only/amnesiac)."
echo "Everything that was previously on B has been wiped."
echo
echo ">>> REBOOT INTO B NOW AND VERIFY. <<<"
echo "    1. Reboot via the Apple firmware picker into B's icon."
echo "    2. Confirm it boots straight to a working desktop."
echo "    3. Create a throwaway file (e.g. date > ~/test.txt), reboot into the"
echo "       SAME entry again, and confirm the file is gone."

exit 0

# ==========================================================================
# APPENDIX: one-time B boot-partition patches (NOT part of the flow above)
# ==========================================================================
# Everything below this line is inert reference material, never executed by
# a normal run of this script (the `exit 0` above stops execution first).
# These two patches used to live as separate files (set-b-grub-readable.sh,
# set-b-grub-hide-menu-unconditionally.sh) - folded in here so the
# "GRUB READABILITY" comment above and the menu_auto_hide comment near
# Step 5/6 keep pointing at something that actually exists, instead of an
# external file that could get deleted/lost independently of this one.
#
# Both patch B's ALREADY-GENERATED grub.cfg directly, in place, on B's boot
# partition - never via grub2-mkconfig (see the real 2026-09-13 incident,
# asahi_atomic_build memory item 41: grub2-mkconfig run inside B's chroot
# reconciles /boot/loader/entries against installed kernels and garbage-
# collects the golden entry + its kernel/initrd as "unrecognized").
#
# Lifecycle: run ONCE per fresh asahi-installer provision of B's boot
# partition - NOT part of the routine "redo the image" rebuild cycle above,
# and never re-run on a routine rebuild. Only needs redoing if B's boot
# partition itself is ever wiped and reprovisioned from scratch.
#
# To use: extract the function you need into its own file and run it inside
# B's chroot, e.g.:
#   sudo bash ~/Software/asahi_atomic/b-tools.sh chroot /dev/nvme0n1pN -- bash -c '
#     '"$(declare -f fresh_boot_grub_readable_patch)"'
#     fresh_boot_grub_readable_patch
#   '
# (or just paste the function body directly into a root shell inside the
# chroot - these were always meant to be run interactively, once, not
# wired into automation.)

fresh_boot_grub_readable_patch() {
    # Makes B's own GRUB menu text match A's - which is the one that's
    # actually readable on this hardware.
    #
    # HISTORY: earlier versions of this fix switched B to
    # GRUB_TERMINAL_OUTPUT="gfxterm" with various forced GRUB_GFXMODE values,
    # theorizing plain "console" output used the raw EFI framebuffer at
    # native (Retina) resolution with no scaling, hence microscopic text.
    # That theory was WRONG - confirmed 2026-09-13 by diffing A's actual
    # generated grub.cfg against B's: A uses plain
    # GRUB_TERMINAL_OUTPUT="console" and its grub.cfg header has NO
    # font-loading/gfxterm block at all, and A's menu is the one that's
    # readable. B's gfxterm+forced-gfxmode setup is almost certainly what
    # was actually causing tiny text: Apple Silicon's GOP doesn't support
    # real video mode switching, so gfxterm's fixed-size bitmap font was
    # very likely being rendered at native panel resolution regardless of
    # the requested GRUB_GFXMODE, while plain "console" writes into
    # whatever framebuffer m1n1/U-Boot already set up, which renders fine.
    # This reverts B to match A exactly instead of forcing another
    # resolution number.
    set -euo pipefail
    local GRUB_DEFAULT_FILE=/etc/default/grub

    set_kv() {
        local key="$1" val="$2"
        if grep -q "^${key}=" "$GRUB_DEFAULT_FILE"; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$GRUB_DEFAULT_FILE"
        else
            echo "${key}=${val}" >> "$GRUB_DEFAULT_FILE"
        fi
    }

    set_kv GRUB_TERMINAL_OUTPUT '"console"'
    set_kv GRUB_GFXMODE auto

    echo "== /etc/default/grub after edit (now matches A) =="
    grep -E '^GRUB_(TERMINAL_OUTPUT|GFXMODE)=' "$GRUB_DEFAULT_FILE"

    # DO NOT call grub2-mkconfig here - see the appendix header above.
    # Hand-patch the already-generated grub.cfg in place instead.
    local CFG_TARGET
    CFG_TARGET="$(readlink -f /etc/grub2-efi.cfg 2>/dev/null || readlink -f /etc/grub2.cfg)"
    echo
    echo "== Patching $CFG_TARGET in place (no grub2-mkconfig) =="

    if grep -qxF 'terminal_output console' "$CFG_TARGET"; then
        echo "OK - $CFG_TARGET already uses plain 'terminal_output console', nothing to do."
    elif grep -qxF 'terminal_output gfxterm' "$CFG_TARGET"; then
        # Removes the whole font-loading/gfxterm block that grub2-mkconfig
        # only emits when GRUB_TERMINAL_OUTPUT=gfxterm at generation time,
        # replacing it with the plain two lines A's config has in that same
        # spot (confirmed by diffing both files' 00_header section
        # byte-for-byte, 2026-09-13).
        local TMP
        TMP="$(mktemp)"
        awk '
            $0 == "if [ x$feature_default_font_path = xy ] ; then" { skip=1 }
            skip {
                if ($0 == "terminal_output gfxterm") {
                    print "terminal_input console"
                    print "terminal_output console"
                    skip=0
                }
                next
            }
            { print }
        ' "$CFG_TARGET" > "$TMP"
        if ! grep -qxF 'terminal_output console' "$TMP" || grep -q 'gfxterm' "$TMP"; then
            echo "ABORTING: patch didn't produce the expected result, not overwriting $CFG_TARGET." >&2
            echo "Left the attempted patch at $TMP for inspection." >&2
            return 1
        fi
        cp "$CFG_TARGET" "${CFG_TARGET}.bak-$(date +%s)"
        mv "$TMP" "$CFG_TARGET"
        echo "Patched (backup of the pre-patch file saved alongside it)."
    else
        echo "ABORTING: $CFG_TARGET has neither 'terminal_output console' nor" >&2
        echo "'terminal_output gfxterm' - unexpected/unknown state, not touching it blind." >&2
        return 1
    fi

    echo
    echo "== Resulting terminal/gfx lines =="
    grep -nE 'gfxmode|terminal_output|terminal_input|gfxterm|loadfont' "$CFG_TARGET" || true

    echo
    echo "== Verifying the golden entry is untouched (this never touches loader/entries) =="
    if ! grep -rl 'root=live:UUID=' /boot/loader/entries/*.conf >/dev/null 2>&1; then
        echo "WARNING: no BLS entry with root=live:UUID= found - unrelated to this patch" >&2
        echo "(which doesn't touch loader/entries at all), but worth knowing." >&2
        return 1
    fi
    echo "OK - golden entry intact, grub.cfg reverted to match A's readable console output."
}

fresh_boot_grub_hide_menu_patch() {
    # Makes B's GRUB menu stay hidden on EVERY boot, not just the first one
    # after a rebuild.
    #
    # ROOT CAUSE (found 2026-09-20, after the boot_success/boot_indeterminate
    # grubenv fix in the main rebuild flow above turned out incomplete):
    # Fedora's /etc/grub.d/10_reset_boot_success fragment (baked into
    # grub.cfg at whatever point it was originally generated) computes
    # menu_hide_ok from boot_success/boot_indeterminate, THEN unconditionally
    # resets boot_success=0 for the current boot attempt - by design, on the
    # assumption that a systemd unit running INSIDE the booted OS will later
    # confirm success and write boot_success=1 back to the real grubenv. B
    # never does that (it's amnesiac/live-booted, no such confirmation
    # service runs), so: rebuild bakes boot_success=1 -> first boot
    # post-rebuild correctly hides the menu -> GRUB immediately resets
    # boot_success back to 0 on disk (normal Fedora behavior) -> every boot
    # after that reads boot_success=0/boot_indeterminate=0 -> menu_hide_ok=0
    # -> menu shows, forever, until the next rebuild. Baking grubenv values
    # at rebuild time can only ever fix the FIRST boot after a rebuild - it
    # was never going to survive a second one.
    #
    # FIX: B only ever has one boot entry and no real "pick a different
    # kernel" recovery use case (recovery goes through A, not B's menu -
    # confirmed with the user when the hide-the-menu request was first
    # made). So there's no reason to keep the conditional at all - hardcode
    # menu_hide_ok=1 unconditionally, once, directly in the already-
    # generated grub.cfg.
    set -euo pipefail
    local CFG_TARGET
    CFG_TARGET="$(readlink -f /etc/grub2-efi.cfg 2>/dev/null || readlink -f /etc/grub2.cfg)"
    echo "== Target: $CFG_TARGET =="

    if grep -qxF 'set menu_hide_ok=1' "$CFG_TARGET" \
        && ! grep -q 'boot_success}" = "1" -o "\${boot_indeterminate}"' "$CFG_TARGET"; then
        echo "OK - already patched, nothing to do."
        return 0
    fi

    local MATCHES
    MATCHES="$(grep -c 'boot_success}" = "1" -o "\${boot_indeterminate}"' "$CFG_TARGET" || true)"
    if [ "$MATCHES" -ne 1 ]; then
        echo "ABORTING: expected exactly 1 match of the boot_success/boot_indeterminate" >&2
        echo "condition in $CFG_TARGET, found $MATCHES - not patching blind." >&2
        return 1
    fi

    cp "$CFG_TARGET" "${CFG_TARGET}.orig-backup-$(date +%s)"

    sed -i '/if \[ "\${boot_success}" = "1" -o "\${boot_indeterminate}" = "1" \]; then/,/^fi *$/c\
set menu_hide_ok=1' "$CFG_TARGET"

    echo
    echo "== Resulting block =="
    grep -n -B1 -A1 'menu_hide_ok=1' "$CFG_TARGET"

    if ! grep -qxF 'set menu_hide_ok=1' "$CFG_TARGET" \
        || grep -q 'boot_success}" = "1" -o "\${boot_indeterminate}"' "$CFG_TARGET"; then
        echo "ABORTING: patch didn't produce the expected result." >&2
        return 1
    fi
    echo
    echo "OK - menu_hide_ok is now unconditional. Menu should stay hidden on every boot."
}
