# asahi-a

Rebuild my Fedora Asahi Remix 44 (GNOME) system from the official **Minimal** image with one command.
Public repo: no secrets in here. Secrets/personal/big theme data live on an external drive (see below).

## Use
1. Install Fedora Asahi Remix 44 **Minimal** from macOS with the Asahi installer (fixed partition sizes), create user `blank`, boot, log in, connect to the network.
2. Run:
   ```
   curl -fsSL https://raw.githubusercontent.com/memory-colors/asahi-a/main/bootstrap.sh | sudo bash
   ```
   It clones this repo to `/root/asahi-a` and runs `rebuild.sh`. Every phase asks first; `dnf` shows its own prompts (no `-y`).
3. Reboot, then `sudo /root/asahi-a/rebuild.sh verify`.

Useful: `sudo ./rebuild.sh packages` (one phase), `--dry-run` (print, change nothing), `--archive FILE.tar.zst` (unpack the private archive from the external drive).

## Phases
| phase | does |
|---|---|
| repos | rpm macro so new packages skip non-English locales, RPM Fusion release, custom `.repo` files (Brave, Mullvad, claude-desktop, 2 COPRs) |
| packages | `dnf install --allowerasing` the 156 explicit packages, then removes the 110 leftover Minimal packages after a capability-level dependency check |
| files | system files (`files/system` mirrors `/`), home dotfiles/themes/launchers/fonts, `~/Software` scripts, GNOME settings (`files/dconf-user.ini`), SELinux relabel |
| services | enable/disable units from `lists.txt`, default target graphical |
| apps | LosslessCut v3.69.0 and czkawka-gui 12.0.2 from GitHub releases |
| archive | with `--archive FILE`: unpack the private tar over `/` (owners/modes kept), copy SF fonts to `/usr/share/fonts` |
| verify | read-only diff of installed packages and units against `lists.txt` |

## Deliberately NOT automated
bleachbit locale cleanup, initramfs/plymouth rebuild (`dracut`), bootloader changes, Claude Code install, partitioning.
Missing locale/man/help files are expected and are not an error.

## Layout
- `lists.txt` - `[install] [remove] [enable] [disable] [closure]` (closure = full package list of the recorded system)
- `files/system/` - non-RPM system files; `files/home/` - dotfiles/themes/configs; `files/Software/` - scripts and notes
- `files/dconf-user.ini` - `dconf dump /` (volatile history keys removed)
- the patched `gnome-shell-theme.gresource` is only restored on gnome-shell 50.5; on other builds the stock file is kept and the `machine-setup` color scripts must be re-run

## Private archive (NOT in this repo)
One unencrypted file kept on the external drive, e.g. `asahi-a-archive-private_<date>.tar.zst` (exFAT cannot hold symlinks/modes, hence a tar).
Create it on the source system, restore it on the new one:
```
sudo ./rebuild.sh make-archive /run/media/blank/X10_4TB/asahi-a-archive-private_<date>.tar.zst
sudo ./rebuild.sh archive --archive /run/media/blank/X10_4TB/asahi-a-archive-private_<date>.tar.zst
```
Contents are driven by the classification lists at the top of `rebuild.sh` (loose files in `~` and unpublished `~/Software` items are included automatically; `./rebuild.sh sync-repo` refreshes this repo from the live system without committing): ssh/keyrings/Wi-Fi/Mullvad accounts, Brave + Claude Desktop data, shell history, `~/.claude`, notes, the modified icon themes (MacTahoe-nord, MacTahoe-nord-dark, WhiteSur-grey, Bibata-Modern-Ice, breeze_cursors) and the SF fonts (stored once).
