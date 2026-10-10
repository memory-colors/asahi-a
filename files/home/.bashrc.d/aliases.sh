# Fedora/dnf analog of the old Debian "up" alias
# (apt update && apt upgrade -> dnf upgrade --refresh does both in one step;
# no real autoclean-vs-clean distinction on dnf, so just one dnf clean all)
# flatpak step is conditional - flatpak was deliberately removed 2026-09-15,
# this way "up" doesn't break if it's absent, and picks it back up for free
# if it's ever reinstalled later.
up() {
    sudo dnf upgrade --refresh &&
    { command -v flatpak >/dev/null 2>&1 && flatpak update; } &&
    sudo dnf clean all &&
    sudo dnf autoremove
}

