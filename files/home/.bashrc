# .bashrc

# Source global definitions
if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

# User specific environment
if ! [[ "$PATH" =~ "$HOME/.local/bin:$HOME/bin:" ]]; then
    PATH="$HOME/.local/bin:$HOME/bin:$PATH"
fi
export PATH

# Uncomment the following line if you don't like systemctl's auto-paging feature:
# export SYSTEMD_PAGER=

# User specific aliases and functions
if [ -d ~/.bashrc.d ]; then
    for rc in ~/.bashrc.d/*; do
        if [ -f "$rc" ]; then
            . "$rc"
        fi
    done
fi
unset rc

export QT_QPA_PLATFORMTHEME="qt6ct"
export PATH="$HOME/.local/bin:$PATH"

# Plain "claude" always continues the most recent conversation instead of
# starting fresh. To start a genuinely new session when needed, bypass this
# alias with "command claude" or "\claude".
alias claude='claude -c'

# Same thing, shorter. Nothing else on this system currently uses "c" as a
# command/alias/function (checked 2026-09-21) - if that ever changes, this
# alias would silently take precedence over a same-named binary since bash
# resolves aliases before PATH.
alias c='claude -c'
