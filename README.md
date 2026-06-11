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
creates a wrapper at `~/.local/bin/terminal-notifier`.

Or manually:

```sh
$ curl -L -o terminal-notifier.zip https://github.com/xuyangy/terminal-notifier/releases/latest/download/terminal-notifier.zip
$ unzip terminal-notifier.zip
$ mkdir -p ~/Applications ~/.local/bin
$ cp -R terminal-notifier.app ~/Applications/
$ printf '#!/bin/sh\nexec "$HOME/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier" "$@"\n' > ~/.local/bin/terminal-notifier
$ chmod +x ~/.local/bin/terminal-notifier
```

Make sure `~/.local/bin` is on your `PATH`, then run:

```sh
$ terminal-notifier -message "installed OK"
```

### From source

Requires full Xcode (not only Command Line Tools) and
[just](https://github.com/casey/just):

```sh
$ just build      # development app at build/Release/terminal-notifier.app
$ just install    # copy to ~/Applications + wrapper in ~/.local/bin
```

## Usage

```sh
$ terminal-notifier -message VALUE [options]
$ terminal-notifier -remove ID
$ terminal-notifier -list ID
```

At a minimum, specify one of `-message`, `-remove`, or `-list` (or pipe the
message body in on stdin). terminal-notifier must run from inside its
application bundle — Notification Center identifies the posting application by
bundle metadata — so invoke it through the installed wrapper or the full
`terminal-notifier.app/Contents/MacOS/terminal-notifier` path, never a copied
or symlinked bare binary.

Exit status: `0` on success, `1` on bad arguments, denied notification
permission, or a failed click action, `2` if delivery does not complete within
ten seconds.

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

`-help`, `-version`

Print the usage banner or the version, then exit.

-------------------------------------------------------------------------------

`-message VALUE`

The message body of the notification.

If you pipe data into terminal-notifier, you can omit this option,
and the piped data will become the message body instead.

-------------------------------------------------------------------------------

`-title VALUE`

The title of the notification. This defaults to ‘Terminal’.

-------------------------------------------------------------------------------

`-subtitle VALUE`

The subtitle of the notification.

-------------------------------------------------------------------------------

`-sound NAME`

Play the `NAME` sound when the notification appears.
Sound names are listed in `/System/Library/Sounds` and `~/Library/Sounds`.

Use the special `NAME` “default” for the default notification sound.

-------------------------------------------------------------------------------

`-group ID`

Specifies the notification’s ‘group’. For any ‘group’, only _one_
notification will ever be shown, replacing previously posted notifications.

A notification can be explicitly removed with the `-remove` option (see
below).

Example group IDs:

* The sender’s name (to scope the notifications by tool).
* The sender’s process ID (to scope the notifications by a unique process).
* The current working directory (to scope notifications by project).

-------------------------------------------------------------------------------

`-remove ID`

Remove a previous notification from the `ID` ‘group’, if one exists.

Use the special `ID` “ALL” to remove all messages.

-------------------------------------------------------------------------------

`-list ID`

Lists details about the specified ‘group’ `ID`.

Use the special `ID` “ALL” to list details about all currently active messages.

The output of this command is tab-separated, which makes it easy to parse.

Note: `-list` and `-remove` only see notifications posted by the same bundle
identifier. Notifications sent through `-sender` or `-appIcon` (which use
per-sender spoof bundles), or by a dev build versus a release build, live in
separate notification stores and cannot be listed or removed across builds.

-------------------------------------------------------------------------------

`-activate ID`

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

`-appIcon PATH`

Specify a local image `PATH` or `file://` URL to display instead of the
application icon. `.icns` files are used directly; other image formats supported
by `NSImage` are converted to `.icns` for the cached spoof bundle.

-------------------------------------------------------------------------------

`-contentImage PATH`

Specify a local image `PATH` or `file://` URL to attach inside the notification.
Use common attachment formats such as png, jpg, jpeg, or gif. The original file
is left in place (a temporary copy is attached).

-------------------------------------------------------------------------------

`-open URL`

Open `URL` when the user clicks the notification. This can be a web or file URL,
or any custom URL scheme.

-------------------------------------------------------------------------------

`-execute COMMAND`

Run the shell command `COMMAND` when the user clicks the notification.
The command is passed to `/bin/sh -c`, and its output is written to the system
log (viewable in Console.app).

-------------------------------------------------------------------------------

`-ignoreDnD`

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
