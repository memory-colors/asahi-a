Extension Manager v0.6.5 (mjakeman/extension-manager) built from source on Asahi, 2026-10-05, installed USER-LOCAL (prefix ~/.local).
Configure: meson setup build --prefix=$HOME/.local -Dbacktrace=false -Dpackage=Fedora-Asahi-local ; ninja -C build ; ninja -C build install
Launcher: ~/.local/share/applications/com.mattjakeman.ExtensionManager.desktop (Exec=extension-manager) -> ~/.local/bin/extension-manager
Uninstall: every installed file is listed in install-log.txt, e.g.
  grep -oE '/home/blank/.local/[^ ]+' install-log.txt | sort -u | xargs -r rm -f   (then glib-compile-schemas ~/.local/share/glib-2.0/schemas)
Rebuild deps (dnf): meson ninja-build blueprint-compiler glib2-devel gtk4-devel libadwaita-devel json-glib-devel libsoup3-devel
