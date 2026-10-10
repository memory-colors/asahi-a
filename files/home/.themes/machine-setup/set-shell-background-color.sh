#!/bin/bash
# set-shell-background-color.sh - Overview background AND GDM login-screen background (one color).
#   Overview: `#overview { background-color }` in ~/.themes/Adwaita-custom/gnome-shell/gnome-shell.css (anchored edit).
#   GDM: `#lockDialogGroup` in /usr/share/gnome-shell/gnome-shell-theme.gresource, rebuilt and installed by
#        `set-shell-accent-color.sh --gdm` (pkexec password prompt; it reads this color from the overview rule,
#        so the two stay equal). If the GDM step is cancelled/fails: run `set-shell-accent-color.sh --gdm` to retry.
# SHELL_CSS=<path> overrides the css (test runs skip the GDM step).
# Usage: ./set-shell-background-color.sh <hex>
#        ./set-shell-background-color.sh --get
set -euo pipefail
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CSS="${SHELL_CSS:-$HOME/.themes/Adwaita-custom/gnome-shell/gnome-shell.css}"
get() { python3 - "$CSS" <<'PYEOF'
import re, sys
m = re.search(r'^#overview\s*\{[^}]*?background-color:\s*#([0-9a-fA-F]{6})', open(sys.argv[1]).read(), re.M)
print(m.group(1).lower() if m else '')
PYEOF
}
[ "${1:-}" == "--get" ] && { get; exit 0; }
[ $# -eq 1 ] || { echo "Usage: $0 <new-hex-color>"; exit 1; }
NEW="${1#\#}"; NEW="${NEW,,}"
[[ "$NEW" =~ ^[0-9a-f]{6}$ ]] || { echo "Error: '$1' is not a 6-digit hex color." >&2; exit 1; }
[ -f "$CSS" ] || { echo "Error: $CSS not found." >&2; exit 1; }
OLD="$(get)"
[ -n "$OLD" ] || { echo "Error: '#overview { background-color }' rule not found." >&2; exit 1; }
if [ "$OLD" != "$NEW" ]; then
    cp "$CSS" "${CSS}.bak-pre-overview-bg-${NEW}"
    python3 - "$CSS" "$NEW" <<'PYEOF'
import re, sys
p, new = sys.argv[1:3]
t = open(p).read()
t, n = re.subn(r'(^#overview\s*\{[^}]*?background-color:\s*)#[0-9a-fA-F]{6}', r'\g<1>#' + new, t, count=1, flags=re.M)
open(p, 'w').write(t)
PYEOF
    echo "Overview background #$OLD -> #$NEW (log out and back in to apply)"
else
    echo "Overview is already #$NEW."
fi
if [ -z "${SHELL_CSS:-}" ]; then
    "$HERE/set-shell-accent-color.sh" --gdm || echo "  (run $HERE/set-shell-accent-color.sh --gdm to retry the GDM part)"
fi
