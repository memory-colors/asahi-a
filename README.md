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

Useful: `sudo ./rebuild.sh packages` (one phase), `--dry-run` (print, change nothing), `--archive /path` (restore the external-drive data).

## Phases
| phase | does |
|---|---|
| repos | rpm macro so new packages skip non-English locales, RPM Fusion release, custom `.repo` files (Brave, Mullvad, claude-desktop, 2 COPRs) |
| packages | `dnf install --allowerasing` the 156 explicit packages, then removes the 110 leftover Minimal packages after a capability-level dependency check |
| files | system files (`files/system` mirrors `/`), home dotfiles/themes/launchers/fonts, `~/Software` scripts, GNOME settings (`files/dconf-user.ini`), SELinux relabel |
| services | enable/disable units from `lists.txt`, default target graphical |
| apps | LosslessCut v3.69.0 and czkawka-gui 12.0.2 from GitHub releases |
| archive | with `--archive DIR`: copy `DIR/home` -> `/home/blank`, `DIR/system` -> `/` |
| verify | read-only diff of installed packages and units against `lists.txt` |

## Deliberately NOT automated
bleachbit locale cleanup, initramfs/plymouth rebuild (`dracut`), bootloader changes, Claude Code install, partitioning.
Missing locale/man/help files are expected and are not an error.

## Layout
- `lists.txt` - `[install] [remove] [enable] [disable] [closure]` (closure = full package list of the recorded system)
- `files/system/` - non-RPM system files; `files/home/` - dotfiles/themes/configs; `files/Software/` - scripts and notes
- `files/dconf-user.ini` - `dconf dump /` (volatile history keys removed)
- the patched `gnome-shell-theme.gresource` is only restored on gnome-shell 50.5; on other builds the stock file is kept and the `machine-setup` color scripts must be re-run

## External-drive archive (NOT in this repo)
Mirror this layout under one folder, then `--archive <folder>`:
- `home/`: `.ssh`, `.bash_history`, `.claude*`, `.config/{BraveSoftware,Claude,Mullvad VPN,transmission,evolution,konsolesshconfig}`, `.local/share/{keyrings,pki}`, `.local/share/fonts/SF-*`, `Downloads`, `Screenshots`, `Software/Mull.txt`, notes
- `system/`: `etc/NetworkManager/system-connections`, `etc/mullvad-vpn`, `usr/share/icons/{MacTahoe-nord,MacTahoe-nord-dark,WhiteSur-grey,Bibata-*,breeze_cursors}`, `usr/share/fonts/SF-*`, `var/lib/AccountsService/{users,icons}`
