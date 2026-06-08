# terminal-notifier

[![GitHub release](https://img.shields.io/github/release/xuyangy/terminal-notifier.svg)](https://github.com/xuyangy/terminal-notifier/releases)

terminal-notifier is a command-line tool to send macOS User Notifications.
This branch targets macOS 10.14 and higher and delivers notifications through
Apple's UserNotifications framework.

## Modernization notes

This branch updates the original project for current macOS development:

* Notification delivery uses `UserNotifications` instead of deprecated
  `NSUserNotification`.
* The old private notification image keys and default bundle-ID swizzle have
  been removed.
* `-sender` and `-appIcon` are implemented with cached spoof app bundles so
  Notification Center sees the requested sender identity.
* The old bundled Ruby gem wrapper has been removed.

## Historical note

[alerter](https://github.com/vjeantet/alerter) features were merged in terminal-notifier 1.7. This led to some issues and even more issues in the 1.8 release. We decided with [Valère Jeantet](https://github.com/vjeantet) to rollback this merge.

terminal-notifier does not include sticky notifications or action buttons. If
you need them, use [alerter](https://github.com/vjeantet/alerter). The original
2.0.0 release restarted versioning around that smaller feature set.

## Caveats

* It is packaged as an application bundle because Notification Center identifies
  the posting application by bundle metadata.
* The first notification from the main app, or from a new `-sender` spoof
  bundle, may trigger a macOS notification permission prompt.
* Release zips are currently ad-hoc signed by CI, not Developer ID signed or
  notarized. macOS may show Gatekeeper warnings for downloaded builds.
* `-ignoreDnD` maps to a time-sensitive notification on macOS 12+. Focus/DnD
  behavior is still controlled by macOS settings and entitlements.
* If you're looking for sticky notifications or action buttons, use
  [alerter](https://github.com/vjeantet/alerter).

## Build and Install

Install from a GitHub Release without cloning the repository:

```sh
$ curl -fsSL https://raw.githubusercontent.com/xuyangy/terminal-notifier/master/scripts/install-release.sh | sh
```

The installer downloads the latest release zip, copies the app to
`~/Applications/terminal-notifier.app`, and creates a wrapper at
`~/.local/bin/terminal-notifier`.

To install manually:

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

To build and install from a local checkout:

```sh
$ just build
$ just install
```

`just build` creates a development app at `build/Release/terminal-notifier.app`.
`just install` copies it to `~/Applications/terminal-notifier.app` and creates
an executable wrapper at `~/.local/bin/terminal-notifier`.

Prebuilt binaries may be available from the
[releases section](https://github.com/xuyangy/terminal-notifier/releases).

## Development

Build and smoke-test locally with:

```sh
$ just build
$ just smoke
$ just test-cli
```

`just build` uses the bundle id `fr.julienxx.oss.terminal-notifier.dev` to avoid
colliding with installed Homebrew or release builds during local testing. Raw
Xcode builds and `just release-build` use the production bundle id
`fr.julienxx.oss.terminal-notifier` automatically.

Create a production zip artifact with:

```sh
$ just package
```

This writes `build/package/terminal-notifier-<version>.zip`. For public
distribution, sign the production app with a Developer ID certificate, enable
the hardened runtime, notarize with `xcrun notarytool`, and staple the
notarization ticket before publishing binaries.

## Notification Permissions

macOS asks for notification permission the first time a bundle identifier posts
a notification. If you deny the prompt, delivery fails until you re-enable the
app in System Settings -> Notifications. Development builds appear as
`terminal-notifier` or `terminal-notifier (dev)`, depending on how they were
built and installed.

## Usage

```sh
$ ./build/Release/terminal-notifier.app/Contents/MacOS/terminal-notifier -[message|group|list] [VALUE|ID|ID] [options]
```

In order to use terminal-notifier, you have to call the binary _inside_ the
application bundle.

If installed with `just install`, run it through the wrapper:

```sh
$ terminal-notifier -[message|group|list] [VALUE|ID|ID] [options]
```

If you'd like notifications to stay on the screen until dismissed, go to System
Settings -> Notifications -> terminal-notifier and change the style from Banners
to Alerts. You cannot do this on a per-notification basis.


### Example Uses

Display piped data with a sound:
```sh
$ echo 'Piped Message Data!' | terminal-notifier -sound default
```

![Example 1](assets/Example_1.png)

Use a custom icon:
```sh
$ terminal-notifier -title ProjectX -subtitle "new tag detected" -message "Finished" -appIcon /path/to/icon.png
```

![Example 3](assets/Example_3.png)

Open an URL when the notification is clicked:
```sh
$ terminal-notifier -title 'Stock' -message 'Check your Apple stock!' -open 'https://finance.yahoo.com/quote/AAPL'
```

![Example 4](assets/Example_4.png)

Open an app when the notification is clicked:
```sh
$ terminal-notifier -group 'address-book-sync' -title 'Address Book Sync' -subtitle 'Finished' -message 'Imported 42 contacts.' -activate 'com.apple.AddressBook'
```

![Example 5](assets/Example_5.png)


### Options

At a minimum, you must specify either the `-message` , the `-remove`, or the
`-list` option.

-------------------------------------------------------------------------------

`-message VALUE`  **[required]**

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
Sound names are listed in `/System/Library/Sounds`.

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

`-remove ID`  **[required]**

Remove a previous notification from the `ID` ‘group’, if one exists.

Use the special `ID` “ALL” to remove all messages.

-------------------------------------------------------------------------------

`-list ID` **[required]**

Lists details about the specified ‘group’ `ID`.

Use the special `ID` “ALL” to list details about all currently active messages.

The output of this command is tab-separated, which makes it easy to parse.

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
Use common attachment formats such as png, jpg, jpeg, or gif.

-------------------------------------------------------------------------------

`-open URL`

Open `URL` when the user clicks the notification. This can be a web or file URL,
or any custom URL scheme.

-------------------------------------------------------------------------------

`-execute COMMAND`

Run the shell command `COMMAND` when the user clicks the notification.
The command is passed to `/bin/sh -c`.

-------------------------------------------------------------------------------

`-ignoreDnD`

Request a time-sensitive notification on macOS 12 and newer. macOS still
controls whether this can bypass Focus or Do Not Disturb.

## License

All the works are available under the MIT license. **Except** for
‘Terminal.icns’, which is a copy of Apple’s Terminal.app icon and as such is
copyright of Apple.

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
