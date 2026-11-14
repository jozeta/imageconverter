#!/bin/sh
# Makes the command-line tool inside the installed app available as `imageconverter`: a symlink in
# ~/.local/bin (no sudo). Usage: scripts/install-cli.sh [path/to/imageconverter.app]
# (default /Applications/imageconverter.app). Run it again after moving the app; remove the link to uninstall.
set -eu

app=${1:-/Applications/imageconverter.app}
tool="$app/Contents/Helpers/imageconverter"
bindir="$HOME/.local/bin"
link="$bindir/imageconverter"

if [ ! -x "$tool" ]; then
    echo "install-cli.sh: $tool not found. Install imageconverter.app first (or pass its path)." >&2
    exit 1
fi
if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "install-cli.sh: $link exists and is not a symlink; not replacing it." >&2
    exit 1
fi

mkdir -p "$bindir"
ln -sfn "$tool" "$link"
echo "Linked $link -> $tool"
"$link" --version

case ":$PATH:" in
    *":$bindir:"*) ;;
    *)
        echo
        echo "$bindir is not on your PATH. Add it, for example for zsh:"
        echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && exec zsh"
        ;;
esac
