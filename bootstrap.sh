#!/bin/bash
# One command on a fresh Fedora Asahi Remix 44 Minimal install (logged in as the user "blank", on the network):
#   curl -fsSL https://raw.githubusercontent.com/memory-colors/asahi-a/main/bootstrap.sh | sudo bash
# Installs git, clones this repo to /root/asahi-a, then runs rebuild.sh with the terminal reattached so
# dnf can ask its normal questions (no -y anywhere). Pass phases/flags through:  ... | sudo bash -s -- packages --dry-run
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
command -v git >/dev/null || dnf install git rsync < /dev/tty
rm -rf /root/asahi-a
git clone --depth 1 https://github.com/memory-colors/asahi-a.git /root/asahi-a
cd /root/asahi-a
exec ./rebuild.sh "$@" < /dev/tty
