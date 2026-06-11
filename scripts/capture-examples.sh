#!/bin/bash
# Capture screenshots of every example in the README "Examples" section.
#
# For each example this script posts the notification, then runs
# `screencapture -w` — the cursor turns into a camera; CLICK THE NOTIFICATION
# BANNER to capture it. The click only selects the window to capture, it does
# not trigger the notification's click action.
#
# Examples are numbered 1-9 in the order they appear in README.md.

set -u

REPO="/Users/xuyangy/wkdir/Git/terminal-notifier"
TN="$REPO/build/Release/terminal-notifier.app/Contents/MacOS/terminal-notifier"
ASSETS="$REPO/assets"
PREVIEW="$ASSETS/System_prefs.png"

if [[ ! -x "$TN" ]]; then
    echo "error: $TN not found — run 'just build' first" >&2
    exit 1
fi

capture() {
    local num="$1"
    echo
    echo ">>> Example $num posted. Click the notification banner to capture it..."
    sleep 1
    screencapture -w "$ASSETS/Example_${num}.png"
    echo "    saved $ASSETS/Example_${num}.png"
}

# Example 0: piped data with a sound
echo 'Piped Message Data!' | "$TN" -sound default
capture 0

# Example 1: piped data with a sound
echo 'Piped Message Data!' | "$TN" -sound default
capture 1

# Example 2: custom icon
"$TN" -title ProjectX -subtitle "new tag detected" -message "Finished" -appIcon "$ASSETS/codex_cli.png"
capture 2

# Example 3: open an URL on click
"$TN" -title 'Stock' -message 'Check your Apple stock!' -open 'https://finance.yahoo.com/quote/AAPL'
capture 3

# Example 4: activate an app on click
"$TN" -group 'address-book-sync' -title 'Address Book Sync' -subtitle 'Finished' -message 'Imported 42 contacts.' -activate 'com.apple.AddressBook'
capture 4

# Example 5: run a shell command on click
echo "backup finished" > /tmp/backup.log
"$TN" -title 'Backup' -message 'Click to view the log' -execute 'open /tmp/backup.log'
capture 5

# Example 6: spoof the sending app
"$TN" -sender com.apple.Safari -title 'Download' -message 'cat-video.mp4 finished'
capture 6

# Example 7: attach an image inside the notification
"$TN" -title 'Render done' -message 'preview attached' -contentImage "$PREVIEW"
capture 7

# Example 8: replace notifications by group (capture the replacement,
# then finish the example with -list / -remove after the screenshot)
"$TN" -group deploy -message 'Deploying 1/3: api'
sleep 2
"$TN" -group deploy -message 'Deploying 2/3: web'
capture 8
"$TN" -list deploy
"$TN" -remove deploy

# Example 9: break through Focus/Do Not Disturb
"$TN" -title 'Alert' -message 'Disk almost full' -ignoreDnD
capture 9

echo
echo "Done. Captured images are in $ASSETS/"
