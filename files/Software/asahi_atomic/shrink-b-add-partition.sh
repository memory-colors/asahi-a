#!/usr/bin/env bash
# Shrinks B's btrfs root partition down to make room for a new persistent
# partition in the freed space. Runs from A (B must not be booted/mounted).
#
# Order matters: shrink the FILESYSTEM first, then the PARTITION TABLE entry,
# never the reverse (shrinking the partition before the filesystem risks
# truncating live data). A GPT backup is taken before any table change.
#
# Assumes B already has a real golden image on it (run rebuild-golden-b.sh
# first) - the shrink target is computed FROM that image's actual size, not
# a guessed constant, so there's nothing meaningful to shrink to yet on a
# freshly-reprovisioned-but-not-yet-imaged B.
#
# Usage: sudo bash shrink-b-add-partition.sh /dev/nvme0n1 /dev/nvme0n1p6
#
# Stages (script pauses for confirmation between the risky ones):
#   1. Preflight checks - measure the actual squashfs size (source of truth:
#      A's own /root/atomic-image-staging/squashfs.img, exactly what's on B
#      after the last successful rebuild-golden-b.sh run), force-reclaim any
#      stale btrfs space left over from that run's wipe step (subvolume
#      delete is asynchronous - a prior balance can complete before the
#      kernel's cleanup thread actually finishes, leaving phantom "used"
#      space behind), then compute the shrink target as squashfs size + a
#      fixed overhead margin - never a guessed/hardcoded constant. GPT backup
#      taken here too.
#   2. Shrink btrfs filesystem on p6 to the computed target      [pause]
#   3. Shrink the p6 partition table entry to match              [pause]
#   4. Grow btrfs to fill the (slightly larger) partition
#   5. Create + format new exFAT partition in freed space (label "persist")
set -euo pipefail

DISK="${1:-}"
B_ROOT="${2:-}"
[ -n "$DISK" ] && [ -n "$B_ROOT" ] || {
    echo "Usage: sudo bash $0 <disk e.g. /dev/nvme0n1> <B root partition e.g. /dev/nvme0n1p6>" >&2
    exit 1
}
[ "$(id -u)" -eq 0 ] || { echo "Must run as root (sudo)." >&2; exit 1; }

B_ROOT_NAME="$(basename "$B_ROOT")"
# 3GiB, not 1GiB - a tighter margin repeatedly failed with ENOSPC in practice
# (2026-09-17: 5245MiB target failed even with only 4221MiB actually used -
# btrfs's shrink needs real working room beyond raw metadata size to relocate
# chunks into during the operation, not just "data + a little metadata").
OVERHEAD_MIB=3072              # headroom above the squashfs itself, for btrfs metadata + shrink working-room + safety margin
PART_OVER_FS_MIB=400           # extra headroom the partition gets over the filesystem target (same ratio as the old fixed 8192->8600)

echo "== Stage 1: preflight =="

if findmnt -n "$B_ROOT" >/dev/null 2>&1; then
    echo "ABORT: $B_ROOT is currently mounted. Unmount it first (B's root should be idle while A is running)." >&2
    exit 1
fi

FSTYPE="$(lsblk -no FSTYPE "$B_ROOT")"
if [ "$FSTYPE" != "btrfs" ]; then
    echo "ABORT: $B_ROOT filesystem is '$FSTYPE', expected btrfs." >&2
    exit 1
fi

STAGING_SQUASHFS="/root/atomic-image-staging/squashfs.img"
if [ -f "$STAGING_SQUASHFS" ]; then
    SQUASHFS_BYTES="$(stat -c%s "$STAGING_SQUASHFS")"
    echo "Found A's staging squashfs: $STAGING_SQUASHFS ($(du -h "$STAGING_SQUASHFS" | cut -f1))"
else
    echo "No staging squashfs at $STAGING_SQUASHFS - falling back to measuring B's own LiveOS/squashfs.img directly."
    MNT_MEASURE="$(mktemp -d)"
    mount -o subvolid=5,ro "$B_ROOT" "$MNT_MEASURE"
    [ -f "$MNT_MEASURE/LiveOS/squashfs.img" ] || { echo "ABORT: no squashfs found on B or in A's staging dir - run rebuild-golden-b.sh first." >&2; umount "$MNT_MEASURE"; rmdir "$MNT_MEASURE"; exit 1; }
    SQUASHFS_BYTES="$(stat -c%s "$MNT_MEASURE/LiveOS/squashfs.img")"
    umount "$MNT_MEASURE"
    rmdir "$MNT_MEASURE"
    echo "Found B's squashfs: $((SQUASHFS_BYTES / 1024 / 1024))MiB"
fi
SQUASHFS_MIB=$(( (SQUASHFS_BYTES + 1048575) / 1048576 ))

echo
echo "Reclaiming any stale btrfs space on $B_ROOT before measuring/shrinking (subvolume deletion from the last"
echo "rebuild-golden-b.sh wipe is asynchronous - this makes sure that cleanup has actually finished first)..."
MNT_RECLAIM="$(mktemp -d)"
mount -o subvolid=5 "$B_ROOT" "$MNT_RECLAIM"
echo "-- before reclaim --"
df -h "$MNT_RECLAIM"
btrfs balance start "$MNT_RECLAIM" || true
echo "-- after reclaim --"
df -h "$MNT_RECLAIM"
umount "$MNT_RECLAIM"
rmdir "$MNT_RECLAIM"

NEW_FS_SIZE_MIB=$(( SQUASHFS_MIB + OVERHEAD_MIB ))
NEW_PART_SIZE_MIB=$(( NEW_FS_SIZE_MIB + PART_OVER_FS_MIB ))
echo
echo "Squashfs: ${SQUASHFS_MIB}MiB. Computed shrink target: ${NEW_FS_SIZE_MIB}MiB filesystem / ${NEW_PART_SIZE_MIB}MiB partition"
echo "(squashfs + ${OVERHEAD_MIB}MiB btrfs metadata/safety margin, partition gets a further ${PART_OVER_FS_MIB}MiB over that)."

B_START_SEC="$(cat "/sys/class/block/$B_ROOT_NAME/start")"
B_SIZE_SEC="$(cat "/sys/class/block/$B_ROOT_NAME/size")"
B_END_SEC=$(( B_START_SEC + B_SIZE_SEC - 1 ))
B_SIZE_MIB=$(( B_SIZE_SEC * 512 / 1048576 ))

# Find whichever partition on this disk starts nearest-after B_ROOT ends - NOT
# necessarily immediately adjacent. On a first-ever run B is genuinely
# touching the next partition (gap=0), but on a rerun after an earlier
# shrink+persist cycle, B is already small and deleting the old persist
# partition leaves a big gap of already-freed space between B's current end
# and whatever real partition comes next (e.g. A's own apfs stub) - that gap
# is exactly the space this run should reclaim, not a reason to abort.
# Confirmed hit for real 2026-09-19 redoing persist after a smaller
# rebuild-golden-b.sh image made further shrinking possible: exact-adjacency
# matching aborted here even though the actual layout was fine.
NEXT_PART=""
NEXT_PART_START=""
for p in /sys/class/block/${B_ROOT_NAME%%p[0-9]*}*p[0-9]*; do
    pn="$(basename "$p")"
    [ "$pn" = "$B_ROOT_NAME" ] && continue
    st="$(cat "$p/start" 2>/dev/null || echo 0)"
    if [ "$st" -gt "$B_END_SEC" ]; then
        if [ -z "$NEXT_PART_START" ] || [ "$st" -lt "$NEXT_PART_START" ]; then
            NEXT_PART="$pn"
            NEXT_PART_START="$st"
        fi
    fi
done

if [ -z "$NEXT_PART" ]; then
    echo "ABORT: could not find a partition immediately following $B_ROOT_NAME (expected contiguous layout). Re-check lsblk manually." >&2
    exit 1
fi

NEXT_START_SEC="$(cat "/sys/class/block/$NEXT_PART/start")"
echo "B root ($B_ROOT_NAME): start_sec=$B_START_SEC end_sec=$B_END_SEC (size $((B_SIZE_SEC*512/1024/1024))MiB)"
echo "Immediately followed by: $NEXT_PART (start_sec=$NEXT_START_SEC) -- will NOT be touched, new partition stops right before it."

B_START_MIB=$(( B_START_SEC * 512 / 1048576 ))
NEXT_START_MIB=$(( NEXT_START_SEC * 512 / 1048576 ))
NEW_P6_END_MIB=$(( B_START_MIB + NEW_PART_SIZE_MIB ))
NEW_PART_START_MIB=$(( NEW_P6_END_MIB + 1 ))
NEW_PART_END_MIB=$(( NEXT_START_MIB - 1 ))
FREED_MIB=$(( NEW_PART_END_MIB - NEW_PART_START_MIB ))

echo
echo "Plan:"
echo "  $B_ROOT_NAME shrinks to ${NEW_PART_SIZE_MIB}MiB (partition), filesystem shrunk to ${NEW_FS_SIZE_MIB}MiB then grown to fill it"
echo "  New partition: ${NEW_PART_START_MIB}MiB -> ${NEW_PART_END_MIB}MiB (~$(( FREED_MIB / 1024 ))GiB), exFAT, label 'persist'"
echo

BACKUP="/root/gpt-backup-$(date +%Y%m%d-%H%M%S).sfdisk"
sfdisk -d "$DISK" > "$BACKUP"
echo "GPT table backed up to $BACKUP (restore with: sfdisk $DISK < $BACKUP)"

echo
echo "== Stage 2: shrink btrfs filesystem on $B_ROOT to ${NEW_FS_SIZE_MIB}MiB =="
MNT="$(mktemp -d)"
# Without this, a failed/aborted resize (set -e exits immediately) leaves B
# mounted and the mountpoint dir lingering under /tmp indefinitely - hit this
# for real 2026-09-17 (twice), and the stale mount then confused an unrelated
# `du` disk-usage check into thinking A's own /tmp held several GB it didn't.
cleanup() { umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
mount -o subvolid=5 "$B_ROOT" "$MNT"

# A single big resize jump can fail with ENOSPC even when the target is
# comfortably larger than actual usage - btrfs needs free, already-usable
# space WITHIN the target boundary to relocate chunks into during the shrink,
# and one huge jump doesn't give it that room. Shrink incrementally instead,
# tapering to smaller steps as the target approaches (2026-09-17: 65GiB down
# to 10GiB in 5GiB steps worked fine, but that same 5GiB step size for the
# final 10GiB -> 5.12GiB jump failed - the tight end needs gentler steps).
CURRENT_MIB="$B_SIZE_MIB"
BIG_STEP_MIB=5120
SMALL_STEP_MIB=512
TAPER_THRESHOLD_MIB=$(( NEW_FS_SIZE_MIB + 10240 ))  # switch to small steps once within 10GiB of the target
while [ "$CURRENT_MIB" -gt "$NEW_FS_SIZE_MIB" ]; do
    if [ "$CURRENT_MIB" -le "$TAPER_THRESHOLD_MIB" ]; then
        STEP_MIB="$SMALL_STEP_MIB"
    else
        STEP_MIB="$BIG_STEP_MIB"
    fi
    NEXT_MIB=$(( CURRENT_MIB - STEP_MIB ))
    [ "$NEXT_MIB" -lt "$NEW_FS_SIZE_MIB" ] && NEXT_MIB="$NEW_FS_SIZE_MIB"
    echo "  resizing to ${NEXT_MIB}MiB..."
    btrfs filesystem resize "${NEXT_MIB}M" "$MNT"
    CURRENT_MIB="$NEXT_MIB"
done
df -h "$MNT"
btrfs filesystem usage "$MNT"
umount "$MNT"

read -rp $'\nFilesystem shrink looks correct above? Proceed to the PARTITION TABLE resize (harder to casually undo) [y/N] ' CONFIRM1
case "$CONFIRM1" in
    [Yy]*) ;;
    *) echo "Aborted before touching the partition table. Filesystem is already shrunk; partition size is untouched, nothing else changed."; exit 1 ;;
esac

echo
echo "== Stage 3: shrink partition table entry for $B_ROOT_NAME =="
echo "size=${NEW_PART_SIZE_MIB}MiB" | sfdisk --no-reread -N "${B_ROOT_NAME##*p}" "$DISK"
partprobe "$DISK" || true
udevadm settle
lsblk "$DISK"

read -rp $'\nPartition resize looks correct above? Proceed to creating the new partition [y/N] ' CONFIRM2
case "$CONFIRM2" in
    [Yy]*) ;;
    *) echo "Aborted before creating the new partition. GPT backup is at $BACKUP if you need to revert."; exit 1 ;;
esac

echo
echo "== Stage 4: grow btrfs to fill the resized partition =="
mount -o subvolid=5 "$B_ROOT" "$MNT"
btrfs filesystem resize max "$MNT"
df -h "$MNT"
umount "$MNT"
rmdir "$MNT"

echo
echo "== Stage 5: create + format new partition in freed space =="
NEW_PART_SPAN_MIB=$(( NEW_PART_END_MIB - NEW_PART_START_MIB + 1 ))
# GPT type "Microsoft basic data" (not the generic "Linux filesystem data"
# type) - matters for macOS interop specifically: Finder/Disk Utility key off
# partition type as well as content when deciding whether to offer an
# auto-mount, and this is a one-time-at-creation choice that's annoying to
# change later without recreating the partition.
MS_BASIC_DATA_GUID="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
echo "start=${NEW_PART_START_MIB}MiB, size=${NEW_PART_SPAN_MIB}MiB, type=${MS_BASIC_DATA_GUID}" | sfdisk --no-reread --append "$DISK"
partprobe "$DISK" || true
udevadm settle
sleep 1

NEW_PART="$(lsblk -lno NAME,TYPE "$DISK" | awk '$2=="part"{print $1}' | sort -V | tail -1)"
NEW_PART_DEV="/dev/${NEW_PART}"
echo "New partition device: $NEW_PART_DEV"
# exFAT, not ext4 - deliberate choice 2026-09-17 for macOS interop (media
# files + a possible VeraCrypt container only, nothing needing real Unix
# permissions/symlinks/SELinux xattrs - see asahi_a_restore_gotchas memory).
mkfs.exfat -L persist "$NEW_PART_DEV"

echo
echo "== Stage 6: wire up auto-mount on A =="
NEW_PART_UUID="$(blkid -s UUID -o value "$NEW_PART_DEV")"
mkdir -p /persist

# exFAT has no native ownership/permissions - uid=/gid=/umask= mount options
# are the only way to control access, there's nothing for a later `chown` to
# act on (unlike ext4). Look up the target user the same way
# rebuild-golden-b.sh's exFAT branch does, for consistency.
PERSIST_OWNER="${SUDO_USER:-blank}"
PERSIST_UID="$(id -u "$PERSIST_OWNER" 2>/dev/null || echo 1000)"
PERSIST_GID="$(id -g "$PERSIST_OWNER" 2>/dev/null || echo 1000)"

# Mounted by LABEL, not UUID (changed 2026-09-19) - every mkfs.exfat run
# (including this script's own Stage 5, a few lines above) assigns a fresh
# UUID but keeps the same "persist" label, so LABEL=persist survives a future
# persist recreation without needing A's fstab (or B's, in
# rebuild-golden-b.sh) touched again at all.
if grep -q '^LABEL=persist ' /etc/fstab 2>/dev/null; then
    echo "fstab already has a LABEL=persist entry, leaving it alone."
else
    cp -a /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
    echo "LABEL=persist /persist exfat rw,nofail,uid=${PERSIST_UID},gid=${PERSIST_GID},umask=022,x-systemd.device-timeout=5s 0 0" >> /etc/fstab
    echo "Added /persist to /etc/fstab (backup taken alongside it)."
fi

mount /persist
echo "Mounted now: $(findmnt -no SOURCE,TARGET,OPTIONS /persist)"
echo "Ownership/permissions on exFAT come entirely from the uid=${PERSIST_UID},gid=${PERSIST_GID},umask=022 mount options above - already in effect, no chown needed or possible."

echo
echo "== Done =="
lsblk "$DISK" -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
echo
echo "/persist is mounted RW on A now and will auto-mount on every future boot of A."
echo "It will ALSO auto-mount (RW) inside B, but only starting from the NEXT run of"
echo "rebuild-golden-b.sh -- that script looks up this partition's UUID fresh each"
echo "build and bakes a matching fstab line into B's image. Until you rerun it, B's"
echo "current golden image predates this partition and won't mount it."
