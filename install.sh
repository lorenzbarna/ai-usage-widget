#!/usr/bin/env bash
# Usage: ./install.sh [provider...]   e.g. ./install.sh claude   (no args: every widgets/<provider>/)
# Links ai-usage.py to ~/.local/bin/ai-usage, installs or updates the widgets, and restarts plasmashell
# because it caches QML. Re-run after editing a widget. Edits to ai-usage.py are live through the symlink.
set -euo pipefail
cd "$(dirname "$0")"
all=$(cd widgets && ls -d */ | tr -d / | grep -vx _template)
want=${*:-$all}
for p in $want; do
    grep -qx "$p" <<<"$all" || { echo "unknown provider: $p (have: $(echo $all))" >&2; exit 1; }
done
mkdir -p ~/.local/bin
ln -sf "$PWD/ai-usage.py" ~/.local/bin/ai-usage
for p in $want; do
    kpackagetool6 -t Plasma/Applet -u "widgets/$p" 2>/dev/null || kpackagetool6 -t Plasma/Applet -i "widgets/$p"
done
echo "Restarting the Plasma shell to load the widgets (panels and desktop blink once)..."
systemctl --user restart plasma-plasmashell 2>/dev/null || { kquitapp6 plasmashell || true; kstart plasmashell; } >/dev/null 2>&1
