#!/bin/sh
set -eu

# Removes everything install-release.sh / `just install` put in place.
# Honors the same overrides as the installer.
APP_DEST="${TERMINAL_NOTIFIER_APP_DEST:-$HOME/Applications/terminal-notifier.app}"
BIN_DIR="${TERMINAL_NOTIFIER_BIN_DIR:-$HOME/.local/bin}"
BIN_DEST="$BIN_DIR/terminal-notifier"
ALIAS_DEST="$BIN_DIR/tn"

removed=0

if [ -e "$BIN_DEST" ]; then
  echo "Removing wrapper $BIN_DEST"
  rm -f "$BIN_DEST"
  removed=1
fi

# Only remove the alias if it is our symlink, not some unrelated `tn`.
if [ -L "$ALIAS_DEST" ] && [ "$(readlink "$ALIAS_DEST")" = "terminal-notifier" ]; then
  echo "Removing alias $ALIAS_DEST"
  rm -f "$ALIAS_DEST"
  removed=1
fi

if [ -d "$APP_DEST" ]; then
  # Unregister before deleting so Launch Services drops the entry cleanly.
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
  if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -u "$APP_DEST" || true
  fi
  echo "Removing app $APP_DEST"
  rm -rf "$APP_DEST"
  removed=1
fi

if [ "$removed" -eq 0 ]; then
  echo "Nothing to remove: terminal-notifier is not installed at $APP_DEST or $BIN_DEST."
  exit 0
fi

echo "Uninstalled terminal-notifier."
echo "Its entry under System Settings -> Notifications disappears on its own."
