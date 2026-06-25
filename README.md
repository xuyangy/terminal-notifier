# terminal-notifier

[![GitHub release](https://img.shields.io/github/release/xuyangy/terminal-notifier.svg)](https://github.com/xuyangy/terminal-notifier/releases)
[![Build](https://github.com/xuyangy/terminal-notifier/actions/workflows/build.yml/badge.svg)](https://github.com/xuyangy/terminal-notifier/actions/workflows/build.yml)

terminal-notifier is a command-line tool to send macOS User Notifications.

```sh
$ terminal-notifier -title "Build" -message "Tests passed ✅" -sound default
```

This is a modernized fork of
[julienXX/terminal-notifier](https://github.com/julienXX/terminal-notifier)
that targets macOS 10.14 and higher and delivers notifications through Apple's
`UserNotifications` framework:

* Notification delivery uses `UserNotifications` instead of the deprecated
  `NSUserNotification` API removed from modern macOS.
* `-sender` and `-appIcon` work again, implemented with cached spoof app
  bundles so Notification Center sees the requested sender identity.
* The old private notification image keys, the default bundle-ID swizzle, and
  the bundled Ruby gem wrapper have been removed.

## Install

### From a GitHub Release (recommended)

```sh
$ curl -fsSL https://raw.githubusercontent.com/xuyangy/terminal-notifier/master/scripts/install-release.sh | sh
```

The installer downloads the latest release zip, copies the app to
`~/Applications/terminal-notifier.app`, registers it with Launch Services, and
creates a wrapper at `~/.local/bin/terminal-notifier` plus a short `tn` alias
next to it (skipped with a warning if an unrelated `tn` already exists).

Or manually:

```sh
$ curl -L -o terminal-notifier.zip https://github.com/xuyangy/terminal-notifier/releases/latest/download/terminal-notifier.zip
$ unzip terminal-notifier.zip
$ mkdir -p ~/Applications ~/.local/bin
$ cp -R terminal-notifier.app ~/Applications/
$ printf '#!/bin/sh\nexec "$HOME/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier" "$@"\n' > ~/.local/bin/terminal-notifier
$ chmod +x ~/.local/bin/terminal-notifier
$ ln -s terminal-notifier ~/.local/bin/tn   # optional short alias; fails if tn is already taken
```

Make sure `~/.local/bin` is on your `PATH`, then run:

```sh
$ terminal-notifier -message "installed OK"
$ tn -message "short alias works too"
```

### From source

Requires full Xcode (not only Command Line Tools) and
[just](https://github.com/casey/just):

```sh
$ just install    # builds, then installs to ~/Applications + wrapper & tn alias in ~/.local/bin
```

## Update

Installing is idempotent, so updating is just installing again. Re-run the
installer to fetch and switch to the latest release:

```sh
$ curl -fsSL https://raw.githubusercontent.com/xuyangy/terminal-notifier/master/scripts/install-release.sh | sh
```

Or, from a source checkout:

```sh
$ git pull
$ just install
```

The app in `~/Applications` is replaced in place; notification permission is
keyed to the bundle identifier, so it carries over without re-prompting. Check
what you are running with:

```sh
$ terminal-notifier -version
```

## Uninstall

Whichever way you installed, removal is the same. Run the uninstall script:

```sh
$ curl -fsSL https://raw.githubusercontent.com/xuyangy/terminal-notifier/master/scripts/uninstall.sh | sh
```

Or, from a source checkout:

```sh
$ just uninstall
```

Either one unregisters the app from Launch Services, then deletes
`~/Applications/terminal-notifier.app`, `~/.local/bin/terminal-notifier`, and
the `tn` alias.
The app's entry under System Settings -> Notifications disappears on its own
once the app is gone.

## Usage

```sh
$ terminal-notifier -message VALUE [options]
$ terminal-notifier -remove ID
$ terminal-notifier -list ID
$ terminal-notifier -focusLast
```

At a minimum, specify one of `-message`, `-remove`, `-list`, or `-focusLast`
(or pipe the message body in on stdin). Every common option also has a short
form, e.g. `-m` for `-message` and `-t` for `-title` — see [Options](#options).
terminal-notifier must run from inside its
application bundle — Notification Center identifies the posting application by
bundle metadata — so invoke it through the installed wrapper or the full
`terminal-notifier.app/Contents/MacOS/terminal-notifier` path, never a copied
or symlinked bare binary.

Exit status: `0` on success, `1` on bad arguments, denied notification
permission, a failed click action, a `-focusLast` with no saved origin (or
whose origin could not be focused), or a `-wait` that can't complete (no
controlling terminal, EOF instead of Return, or the notification was already
dismissed), `2` if delivery does not complete within ten seconds.

If you'd like notifications to stay on the screen until dismissed, go to System
Settings -> Notifications -> terminal-notifier and change the style from Banners
to Alerts. You cannot do this on a per-notification basis; for sticky
notifications and action buttons use
[alerter](https://github.com/vjeantet/alerter).

### Examples

Display piped data with a sound:
```sh
$ echo 'Piped Message Data!' | terminal-notifier -sound default
```

![Example 1](assets/Example_1.png)

Use a custom icon:
```sh
$ terminal-notifier -title ProjectX -subtitle "new tag detected" -message "Finished" -appIcon /path/to/icon.png
```

![Example 2](assets/Example_2.png)

Open an URL when the notification is clicked:
```sh
$ terminal-notifier -title 'Stock' -message 'Check your Apple stock!' -open 'https://finance.yahoo.com/quote/AAPL'
```

![Example 3](assets/Example_3.png)

Open an app when the notification is clicked:
```sh
$ terminal-notifier -group 'address-book-sync' -title 'Address Book Sync' -subtitle 'Finished' -message 'Imported 42 contacts.' -activate 'com.apple.AddressBook'
```

![Example 4](assets/Example_4.png)

Wait for Return in the terminal and treat it like a click while the
notification is still delivered:
```sh
$ terminal-notifier -message 'Build finished' -open 'https://example.com' -wait
```

Focus the terminal or tmux pane that posted the notification when it is clicked:
```sh
$ terminal-notifier -message 'LLM needs attention' -focus
```

Later, jump back to the origin of the most recent `-focus` notification:
```sh
$ terminal-notifier -focusLast
```

Run a shell command when the notification is clicked:
```sh
$ terminal-notifier -title 'Backup' -message 'Click to view the log' -execute 'open /tmp/backup.log'
```

![Example 5](assets/Example_5.png)

Make the notification look like it comes from another app:
```sh
$ terminal-notifier -sender com.apple.Safari -title 'Download' -message 'cat-video.mp4 finished'
```

![Example 6](assets/Example_6.png)

Attach an image inside the notification:
```sh
$ terminal-notifier -title 'Render done' -message 'preview attached' -contentImage assets/System_prefs.png
```

![Example 7](assets/Example_7.png)

Replace, list, and remove notifications by group:
```sh
$ terminal-notifier -group deploy -message 'Deploying 1/3: api'      # posts
$ terminal-notifier -group deploy -message 'Deploying 2/3: web'      # replaces the first
$ terminal-notifier -list deploy                                     # shows the current one
$ terminal-notifier -remove deploy                                   # dismisses it
```

![Example 8](assets/Example_8.png)

Break through Focus/Do Not Disturb (macOS 12+, subject to system settings):
```sh
$ terminal-notifier -title 'Alert' -message 'Disk almost full' -ignoreDnD
```

![Example 9](assets/Example_9.png)

### Options

`-h, -help`, `-v, -version`

Print the usage banner or the version, then exit.

-------------------------------------------------------------------------------

`-m, -message VALUE`

The message body of the notification.

If you pipe data into terminal-notifier, you can omit this option,
and the piped data will become the message body instead.

-------------------------------------------------------------------------------

`-t, -title VALUE`

The title of the notification. This defaults to ‘Terminal’.

-------------------------------------------------------------------------------

`-sub, -subtitle VALUE`

The subtitle of the notification.

-------------------------------------------------------------------------------

`-s, -sound NAME`

Play the `NAME` sound when the notification appears.
Sound names are listed in `/System/Library/Sounds` and `~/Library/Sounds`.

Use the special `NAME` “default” for the default notification sound.

-------------------------------------------------------------------------------

`-g, -group ID`

Specifies the notification’s ‘group’. For any ‘group’, only _one_
notification will ever be shown, replacing previously posted notifications.

A notification can be explicitly removed with the `-remove` option (see
below).

Example group IDs:

* The sender’s name (to scope the notifications by tool).
* The sender’s process ID (to scope the notifications by a unique process).
* The current working directory (to scope notifications by project).

-------------------------------------------------------------------------------

`-r, -remove ID`

Remove a previous notification from the `ID` ‘group’, if one exists.

Use the special `ID` “ALL” to remove all messages.

-------------------------------------------------------------------------------

`-l, -list ID`

Lists details about the specified ‘group’ `ID`.

Use the special `ID` “ALL” to list details about all currently active messages.

The output of this command is tab-separated, which makes it easy to parse.

Note: `-list` and `-remove` only see notifications posted by the same bundle
identifier. Notifications sent through `-sender` or `-appIcon` (which use
per-sender spoof bundles), or by a dev build versus a release build, live in
separate notification stores and cannot be listed or removed across builds.

-------------------------------------------------------------------------------

`-a, -activate ID`

Activate the application specified by `ID` when the user clicks the
notification.

You can find the bundle identifier (`CFBundleIdentifier`) of an application in its `Info.plist` file
_inside_ the application bundle.

Examples application IDs are:

* `com.apple.Terminal` to activate Terminal.app
* `com.apple.Safari` to activate Safari.app

-------------------------------------------------------------------------------

`-sender ID`

Make the notification appear to come from the app with this bundle identifier.
terminal-notifier does this by creating a cached clone of its own `.app`, then
changing the clone's bundle identifier, display name, and icon before re-running
from that clone. The first use of a sender may require notification permission
for the generated spoof bundle.

For information on the `ID`, see the `-activate` option.

-------------------------------------------------------------------------------

`-i, -appIcon PATH|NAME`

Specify a local image `PATH` or `file://` URL to display instead of the
application icon. `.icns` files are used directly; other image formats supported
by `NSImage` are converted to `.icns` for the cached spoof bundle.

As a shortcut, a bare agentic-tool name uses an icon bundled with
terminal-notifier instead of a file path: `claude` (aliases: `claude-code`),
`codex` (`codex-cli`), `antigravity`, and `opencode`. Names are matched
case- and separator-insensitively. A value containing a `/`, or one that names
an existing file, is always treated as a path.

```sh
$ terminal-notifier -message 'Build finished' -appIcon claude
```

Because `-appIcon` posts from a spoof bundle, combining it with `-focus` in
iTerm2 needs a one-time **Remember my choice → Allow** for iTerm2's
"control sequence to activate a session" prompt; see the `-focus` option below.

-------------------------------------------------------------------------------

`-c, -contentImage PATH`

Specify a local image `PATH` or `file://` URL to attach inside the notification.
Use common attachment formats such as png, jpg, jpeg, or gif. The original file
is left in place (a temporary copy is attached).

-------------------------------------------------------------------------------

`-o, -open URL`

Open `URL` when the user clicks the notification. This can be a web or file URL,
or any custom URL scheme.

-------------------------------------------------------------------------------

`-e, -execute COMMAND`

Run the shell command `COMMAND` when the user clicks the notification.
The command is passed to `/bin/sh -c`, and its output is written to the system
log (viewable in Console.app).

-------------------------------------------------------------------------------

`-wait`

Keep terminal-notifier running until you press Return on the controlling
terminal. If the notification is still delivered, Return removes it and runs the
same `-open`, `-activate`, or `-execute` behavior as clicking the notification.
Unlike a click, which logs to the system log, an `-execute` command run via
Return writes its output to the terminal.

-------------------------------------------------------------------------------

`-focus`

Focus the terminal that posted the notification when the user clicks it. When
posted from tmux, terminal-notifier records the tmux socket, client TTY, and
pane ID, then switches that client back to the originating pane. It also saves
this origin so it can be re-focused later with `-focusLast`.

In iTerm2 it raises the exact session via a `StealFocus` control sequence
(fast, no Automation permission needed). The first time, iTerm2 asks "a control
sequence attempted to activate a session" — tick **Remember my choice → Allow**
to silence it. In Terminal.app it uses AppleScript, which needs macOS
Automation permission.

Note: with `-sender`/`-appIcon`, the notification is owned by a separate spoof
bundle that has no Automation consent, so AppleScript-based focus silently fails
for it. In that mode iTerm2's `StealFocus` path is the only one that works, so
allowing the iTerm2 prompt above is required; Terminal.app click-focus is not
supported.

-------------------------------------------------------------------------------

`-focusLast`

Focus the origin saved by the most recent `-focus` notification, then exit.
Takes no message. Even when the notification toast is hidden or has already
disappeared (e.g. after one click), `-focusLast` lets you focus the last origin.
This is designed to be bound to a global keyboard shortcut, allowing you to jump
back to a task that notified you without using the mouse.

For example, to bind it to a Hyperkey (e.g. `Hyper + Return`) using **skhd**:
```sh
cmd + alt + ctrl + shift - return : ~/.local/bin/terminal-notifier -focusLast
```

Or as a **Raycast** Script Command:
```bash
#!/bin/bash
# @raycast.title Focus Last Notification
# @raycast.mode silent
~/.local/bin/terminal-notifier -focusLast
```

Or using **Hammerspoon**:
```lua
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "return", function()
  hs.execute("~/.local/bin/terminal-notifier -focusLast")
end)
```

-------------------------------------------------------------------------------

`-dnd, -ignoreDnD`

Request a time-sensitive notification on macOS 12 and newer. macOS still
controls whether this can bypass Focus or Do Not Disturb.

## Notification Permissions

macOS asks for notification permission the first time a bundle identifier posts
a notification. If you deny the prompt — or later switch the app off in System
Settings -> Notifications — delivery fails with exit status 1 and a message
naming the exact entry to re-enable, for example:

```
[!] Notifications for 'terminal-notifier' are turned off. Enable them in
System Settings -> Notifications -> terminal-notifier and try again.
```

Development builds appear as `terminal-notifier (dev)`, release builds as
`terminal-notifier`, and each `-sender`/`-appIcon` spoof bundle gets its own
entry under the spoofed name.

## Development

Build and smoke-test locally with:

```sh
$ just build      # build the dev app
$ just smoke      # send a quick test notification
$ just test-cli   # interactive smoke-test of every CLI feature
```

`just build` uses the bundle id `fr.julienxx.oss.terminal-notifier.dev` and the
display name `terminal-notifier (dev)` to avoid colliding with installed
Homebrew or release builds during local testing. Raw Xcode builds and
`just release-build` use the production bundle id
`fr.julienxx.oss.terminal-notifier` automatically.

Other useful recipes: `just run -message hi` (build and run with arguments),
`just which` (print the built binary path), `just clean`.

### Releasing

```sh
$ just package    # build + zip build/package/terminal-notifier-<version>.zip
```

Releases are published by CI: bump `CFBundleShortVersionString` and
`CFBundleVersion` in `Terminal Notifier/Terminal Notifier-Info.plist`, commit,
then push a `v<version>` tag that matches the plist version exactly — the
Release workflow verifies the match, builds, and attaches the zips to a GitHub
Release. For public distribution beyond that, sign the production app with a
Developer ID certificate, enable the hardened runtime, notarize with
`xcrun notarytool`, and staple the notarization ticket before publishing
binaries.

## Caveats

* It is packaged as an application bundle because Notification Center identifies
  the posting application by bundle metadata.
* The first notification from the main app, or from a new `-sender` spoof
  bundle, may trigger a macOS notification permission prompt.
* Release zips are currently ad-hoc signed by CI, not Developer ID signed or
  notarized. macOS may show Gatekeeper warnings for downloaded builds.
* `-ignoreDnD` maps to a time-sensitive notification on macOS 12+. Focus/DnD
  behavior is still controlled by macOS settings and entitlements.

## Historical note

[alerter](https://github.com/vjeantet/alerter) features were merged in terminal-notifier 1.7. This led to some issues and even more issues in the 1.8 release. We decided with [Valère Jeantet](https://github.com/vjeantet) to rollback this merge.

terminal-notifier does not include sticky notifications or action buttons. If
you need them, use [alerter](https://github.com/vjeantet/alerter). The original
2.0.0 release restarted versioning around that smaller feature set.

## License

All the works are available under the MIT license. **Except** for
‘iTerm2.icns’, which is a copy of the [iTerm2](https://iterm2.com) app icon
and as such is copyright of George Nachman and the iTerm2 contributors
(GPL-2.0).

Copyright (C) 2012-2017 Eloy Durán <eloy.de.enige@gmail.com>, Julien Blanchard
<julien@sideburns.eu>

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
