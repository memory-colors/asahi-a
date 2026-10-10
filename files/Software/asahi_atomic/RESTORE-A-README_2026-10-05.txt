DISASTER RECOVERY: RESTORING A, THEN REBUILDING B + /PERSIST
================================================================
Last updated 2026-09-28; edited 2026-10-05 (see KNOWN STALE below).

KNOWN STALE / CHECK BEFORE TRUSTING (found by a 2026-10-05 review):
- The backup snapshot this describes was taken 2026-09-28. Everything done since is NOT in it: the ~/.themes
  consolidation (theme/config dirs now live in ~/.themes with symlinks at ~/.config and ~/.local/share), the
  patched Breeze/Dolphin build, Extension Manager (built into ~/.local), Knomadic changes, package changes (e.g.
  Gwenview removed). The full-home tarball restores ~/.themes and its symlinks intact, but a restore from the
  09-28 snapshot will bring back 09-28-era theming. Re-run backup-a-to-external.sh while the drive is connected
  if you want a current recovery point (not done automatically - the user asked for minimal archives).
- The package counts below (1484 / 34) are as of 2026-09-28.
- Drive paths VERIFIED 2026-10-05 against the mounted drive: A scripts + snapshot = Software/asahi-restore-a-from-backup/,
  B scripts = Software/Claude/asahi-clone-a-to-b/. This file's paths are correct (older memory notes that said
  Software/Claude/asahi-restore-a-from-backup/ were wrong).
- chroot-into-b.sh, check-a-leftovers.sh, diagnose-b-boot.sh, diagnose-b-space.sh and b-amnesia-selftest-write/check.sh were
  merged into ONE script, b-tools.sh (subcommands: chroot, leftovers, diagnose-boot, diagnose-space, amnesia-write,
  amnesia-check - the amnesia pair is the Step 5 test, run `bash b-tools.sh amnesia-write` on B's golden entry, reboot, then
  `bash b-tools.sh amnesia-check`). The drive's
  asahi-clone-a-to-b/ folder still holds the old four scripts + delete-persist-partition.sh and an older rebuild-golden-b.sh;
  copy b-tools.sh and the current rebuild-golden-b.sh there manually when you want the drive current (nothing syncs automatically).
- delete-persist-partition.sh was removed from the project (easy to redo); shrink-b-add-partition.sh is kept.

WHAT THIS ARCHIVE IS
-----------------------
Everything at Software/asahi-restore-a-from-backup/ on this drive is a full
disaster-recovery snapshot of "A" (the everyday Fedora Asahi Remix
Workstation/GNOME install) taken 2026-09-28, PLUS the scripts needed to
rebuild "B" (the read-only/amnesiac live-boot install) and /persist from
scratch afterward. Use this if all Asahi partitions are wiped out (e.g. by
a macOS update gone wrong) and you're starting from nothing but a Mac in
Recovery mode.

Contents of this folder:
  backup-a-to-external.sh, restore-a-from-external.sh  - the two scripts
  manifests/install-packages.txt                        - 1484 packages A
                                                            has beyond a
                                                            fresh minimal
                                                            GNOME install
  manifests/remove-packages.txt                          - 34 packages a
                                                            fresh minimal
                                                            GNOME install
                                                            has that A
                                                            deliberately
                                                            doesn't (e.g.
                                                            Nautilus,
                                                            LibreOffice-
                                                            adjacent apps,
                                                            GNOME Maps/
                                                            Weather/Boxes,
                                                            Ptyxis, Loupe)
  manifests/dnf-history-*.txt                            - raw audit trail
  manifests/flatpak-apps.txt                              - Flatpak apps
  etc-yum-repos-d.tar.gz                                  - Brave, RPM
                                                            Fusion,
                                                            VeraCrypt COPR,
                                                            Asahi hotfixes
  usr-share-icons.tar.gz                                  - custom icon/
                                                            cursor themes
  home-blank.tar.gz                                       - full home dir
                                                            (minus .cache)
  system-files/                                           - targeted
                                                            non-package
                                                            system files:
                                                            reboot-picker +
                                                            helper +
                                                            sudoers rule,
                                                            ydotool systemd
                                                            override,
                                                            zram-generator.
                                                            conf, and a
                                                            REFERENCE copy
                                                            of fstab (do
                                                            not blind-
                                                            restore it -
                                                            see below)

The package manifests are a DIFF AGAINST FEDORA'S OWN "core + standard +
gnome-desktop" comps groups (the real definition of a minimal GNOME
install), not a guess. This method was chosen deliberately 2026-09-28 after
finding the previous method (dnf history's Reason=User field) produced 138
false positives - stock packages like bash/systemd/gdm/gnome-shell that
were only flagged "user installed" because they'd been explicitly listed in
the original kickstart transaction, not anything actually chosen later.

Software/Claude/asahi-clone-a-to-b/ on this drive holds the SEPARATE set of
scripts for the B-rebuild pipeline (see PART 2 below) - rebuild-golden-b.sh,
b-tools.sh (chroot + diagnostics), shrink-b-add-partition.sh.

This project's Claude Code memory is NOT kept as a separate copy on this drive any more (the auto-sync was removed
2026-10-05; the user wants minimal files and no automatic backups). It is inside home-blank.tar.gz (path
blank/.claude/projects/-home-blank/memory/) and comes back with the home restore in PART 1, Step 4. To have an
assistant with context EARLIER (Step 3), extract just that folder - see Step 3.


================================================================
PART 1: RESTORING A
================================================================

BEFORE YOU START
-----------------
- Fresh install Fedora Asahi Remix Workstation/GNOME via asahi-installer
  from macOS Recovery.
- Complete the graphical initial-setup wizard.
- Username MUST be exactly: blank (the backup's internal paths and the
  restore script both assume this).
- Get to a normal GNOME desktop before doing anything below.


STEP 1 - Plug in the backup drive
-----------------------------------
GNOME should auto-mount it within a few seconds. Confirm the mount point:

    ls /run/media/blank/

You should see X10_4TB (or similar - substitute the real name everywhere
below if it differs).


STEP 2 - Open a Terminal
-------------------------
Activities -> type "Terminal" -> open it.


STEP 3 - (Optional but recommended) Install Claude Code and restore its
memory of this project
--------------------------------------------------------------------------
Gives you an assistant with full context on this whole project - why
things are set up this way, gotchas already hit, what's still open - for
the rest of this recovery and beyond.

1. Install Claude Code (needs internet access):

    curl -fsSL https://claude.ai/install.sh | bash

   Follow the prompts (including signing in) - restart the terminal
   afterward if it tells you to.

2. Restore its memory of this project - pull ONLY the memory folder out of the home archive (the full home
   restore comes later, in Step 4):

    tar -xzf /run/media/blank/X10_4TB/Software/asahi-restore-a-from-backup/home-blank.tar.gz -C /home blank/.claude/projects/-home-blank/memory

   (The archive is a 09-28 snapshot, so this memory is as of then. There is no separate or live-updated memory
   copy on the drive any more.)

3. Launch Claude Code from your home directory specifically - not a
   subfolder - so it picks up the memory location above:

    cd ~
    claude

   Then say something like "catch me up" or "we need to restore A and
   rebuild B, where do we stand" - it'll read the restored memory and
   have full context, including this exact recovery procedure.


STEP 4 - Run the restore script
---------------------------------
The scripts are already sitting on the drive as plain files - no need to
extract anything. Run:

    sudo bash /run/media/blank/X10_4TB/Software/asahi-restore-a-from-backup/restore-a-from-external.sh /run/media/blank/X10_4TB

You'll be asked for your sudo password (the one from initial setup).


WHAT THIS DOES (in order, ~15-30 min depending on internet speed)
----------------------------------------------------------------------
1. Restores enabled software repos (Brave, VeraCrypt, RPM Fusion, Asahi
   hotfixes/COPRs).
2. Installs the 1484 packages A has beyond a fresh minimal GNOME install
   (needs internet access).
3. Removes the 34 packages a fresh minimal GNOME install has that A
   deliberately doesn't.
4. Reinstalls Flatpak apps, if any.
5. Restores custom icon/cursor themes to /usr/share/icons.
6. Restores the entire home directory (dotfiles, documents, everything
   except the old .cache) on top of the fresh one.
7. Restores the targeted system files: reboot-picker + its helper +
   sudoers rule (validated with visudo before being trusted - removed
   automatically if it fails validation rather than risk locking out
   sudo), the ydotool systemd override, and zram-generator.conf.
   /etc/fstab is captured as a REFERENCE ONLY and NOT restored
   automatically - see PART 2 below, its /persist line needs to be
   re-added by hand with THIS install's actual partition
   UUID/label, not the old one.

If a step prints a warning and continues rather than stopping, that's
usually fine - the script tolerates a few expected non-fatal situations
(a package already gone, tar noticing a file changed mid-scan). A real
failure stops the script outright.


STEP 5 - Reboot
------------------
    sudo reboot


STEP 6 - Sanity check
------------------------
After logging back in, confirm:
- Icon theme applied correctly (not default GNOME/Fedora)
- Usual apps present (Brave, KDE apps, qView, etc.)
- Deliberately-removed apps still absent (Nautilus, LibreOffice-adjacent,
  GNOME Maps/Weather/Boxes, Ptyxis, Loupe, etc.)
- Flatpak app(s), if any, installed and open correctly
- Home directory looks right
- reboot-picker present and runs (Activities -> search for it, or check
  the dock): `ls -la /usr/local/bin/reboot-picker`
- ydotool socket override in place: `systemctl status ydotool` (after
  `sudo dnf install ydotool` if it wasn't in the package manifest)

If something looks wrong, the archive itself is untouched by running the
script - retry, or pull one thing out by hand:

    tar -tzf /run/media/blank/X10_4TB/Software/asahi-restore-a-from-backup/home-blank.tar.gz | less

(lists every file in the home-directory archive; extract just one with
`tar -xzf ... <path> -C /home`)


================================================================
PART 2: REBUILDING B + /PERSIST (do this AFTER Part 1 is confirmed good)
================================================================

This is a separate, later phase. A alone is a fully usable daily-driver
system - B is the read-only/amnesiac "public/loaner" boot option, and
/persist is the shared exFAT partition both A and B mount at /persist.
Neither exists yet after Part 1 - this phase creates both from scratch.

PREREQUISITE - this step CANNOT be scripted, must be done from macOS
Recovery, before anything below will work
-----------------------------------------------------------------------------
B needs its OWN set of partitions (APFS stub + ESP + boot + root) that are
registered with Apple's firmware boot picker. This registration is an
Apple-firmware-level thing - only asahi-installer running from macOS
Recovery can do it, nothing from inside Linux can create or register it.

Boot into macOS Recovery and run the Asahi installer again, choosing
"install alongside" to add a SECOND Fedora Asahi Remix install. Use a
generic/minimal option (Workstation, GNOME, default settings) - you'll
immediately shrink and repurpose it, so what it looks like as first
installed doesn't matter. This will also shrink macOS's own container
further and add another OS's worth of ESP/boot/root partitions.

After this step, re-verify the ACTUAL partition layout (numbers shift
after every asahi-installer run, so don't trust the layout documented in
memory or here - re-derive it fresh):

    lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT

Identify B's root and boot partitions (small root, ~7-8G btrfs; boot,
~1G ext4) as distinct from A's (much larger root, ~50G+).


STEP 1 - Shrink B, carve out /persist, wire A's fstab
---------------------------------------------------------
From A, as root:

    sudo bash /run/media/blank/X10_4TB/Software/Claude/asahi-clone-a-to-b/shrink-b-add-partition.sh /dev/nvme0n1 <B-root-partition>

This shrinks B's root btrfs+partition down to the minimum needed
(squashfs size + ~3GiB overhead), creates the new /persist partition in
the freed space (exFAT, labeled "persist", GPT type set for macOS Finder
auto-mount), and adds the correct fstab entry to A automatically - the
fstab.reference-only-do-not-blind-restore file from Part 1 is NOT needed
for this, this script handles it correctly with fresh UUIDs/label on its
own. (Confirm afterward: `grep persist /etc/fstab` and
`findmnt /persist`.)


STEP 2 - Build B's golden image from A
------------------------------------------
Still on A, as root:

    sudo bash /run/media/blank/X10_4TB/Software/Claude/asahi-clone-a-to-b/rebuild-golden-b.sh <B-root-partition> <B-boot-partition>

This is THE sole provisioning script for B - squashes A's own live
filesystem (with /etc/fstab replaced by a stripped placeholder so B
actually boots amnesiac instead of silently persisting /home writes),
builds a matching live-boot initramfs, and unconditionally wipes +
reflashes B's root/boot partitions. No confirmation prompt, no fallback -
if you're not ready to commit, don't run it yet. Installs
squashfs-tools/dracut-live automatically if missing. Watch for the final
"Done building and flashing." message before considering the run
complete - if it's interrupted between wiping B and flashing the new
image, B is left unbootable until you rerun this script (safe to rerun,
the wipe step is a no-op on already-empty partitions). Takes a few
minutes (the dracut step is the slow part) - run under tmux/screen if the
terminal session might drop.


STEP 3 - One-time GRUB patches (fresh B provision only)
-----------------------------------------------------------
rebuild-golden-b.sh never touches grub.cfg itself - two patches need to
be applied once per fresh B provision, via a chroot into B:

    sudo bash /run/media/blank/X10_4TB/Software/Claude/asahi-clone-a-to-b/b-tools.sh chroot <B-root-partition>

Once inside the chroot, extract and run the two patch functions from the
APPENDIX at the bottom of rebuild-golden-b.sh (past its `exit 0` - they're
never run automatically):
  - fresh_boot_grub_readable_patch - matches A's terminal_output console
    setting, never calls grub2-mkconfig
  - fresh_boot_grub_hide_menu_patch - unconditionally hides B's boot menu
    (grubenv-only approaches don't survive a reboot on this GRUB version)

IMPORTANT: never run plain `grub2-mkconfig` inside this chroot - it
regenerates ALL BLS entries from scratch and will delete B's golden entry
and kernel/initrd. If a change genuinely needs grub2-mkconfig, immediately
rerun rebuild-golden-b.sh afterward before rebooting.

Exit the chroot when done.


STEP 4 - Reboot-picker and asahi-bless
-------------------------------------------
reboot-picker itself was already restored to A in Part 1 Step 4. It calls
`asahi-bless` to set the firmware boot target - confirm that package is
installed (it should already be, if it was in the package manifest as
userinstalled):

    sudo dnf install asahi-bless
    asahi-bless --list-volumes

You should see three targets: the macOS volume, B's install
(asahi_atomic), and A's install (Asahi/whatever label A got this time).


STEP 5 - Reboot and test
----------------------------
Use reboot-picker (or asahi-bless directly) to boot into B. Once there,
run the ONLY test that actually matters - the amnesia test, not just a
successful boot:

    touch ~/this-should-disappear.txt
    sudo reboot

Boot into B again and confirm the file is gone:

    ls ~/this-should-disappear.txt

(should report "No such file or directory"). Also check
`findmnt /home` while in B - it should NOT show a real disk-backed mount;
if it does, the fstab-stripping in Step 2 didn't take and B is silently
persisting /home writes across reboots.


WHAT'S DELIBERATELY NOT AUTOMATED IN THIS WHOLE RECOVERY
-------------------------------------------------------------
- B's raw partition creation/registration (the macOS Recovery
  prerequisite above) - firmware-level, genuinely can't be scripted from
  Linux.
- fstab is restored as reference-only, not automatically, since UUIDs are
  install-specific - shrink-b-add-partition.sh writes the correct
  /persist line itself in Step 1 above, so in practice you don't need to
  touch fstab by hand at all unless something about A's other mounts also
  needs manual reconciliation.
