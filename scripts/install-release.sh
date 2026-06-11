#!/bin/sh
set -eu

DOWNLOAD_URL="${TERMINAL_NOTIFIER_DOWNLOAD_URL:-https://github.com/xuyangy/terminal-notifier/releases/latest/download/terminal-notifier.zip}"
APP_DEST="${TERMINAL_NOTIFIER_APP_DEST:-$HOME/Applications/terminal-notifier.app}"
BIN_DIR="${TERMINAL_NOTIFIER_BIN_DIR:-$HOME/.local/bin}"
BIN_DEST="$BIN_DIR/terminal-notifier"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/terminal-notifier-install.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

echo "Downloading terminal-notifier..."
curl -fsSL "$DOWNLOAD_URL" -o "$tmpdir/terminal-notifier.zip"

echo "Unpacking..."
ditto -x -k "$tmpdir/terminal-notifier.zip" "$tmpdir"

if [ ! -d "$tmpdir/terminal-notifier.app" ]; then
  echo "Error: terminal-notifier.app was not found in the release zip." >&2
  exit 1
fi

echo "Installing app to $APP_DEST"
mkdir -p "$(dirname "$APP_DEST")"
rm -rf "$APP_DEST"
cp -R "$tmpdir/terminal-notifier.app" "$APP_DEST"

# Register with Launch Services so the notification permission flow works
# immediately (matches `just install`). Non-fatal if the tool is missing.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP_DEST" || true
fi

echo "Installing wrapper to $BIN_DEST"
mkdir -p "$BIN_DIR"
cat > "$BIN_DEST" <<EOF
#!/bin/sh
exec "$APP_DEST/Contents/MacOS/terminal-notifier" "\$@"
EOF
chmod +x "$BIN_DEST"

# Short alias; a symlink is fine here because the wrapper it points at
# execs the app binary by absolute path.
ln -sf terminal-notifier "$BIN_DIR/tn"

echo "Installed terminal-notifier (alias: tn)."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "Add this to your shell config if terminal-notifier is not found:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac
