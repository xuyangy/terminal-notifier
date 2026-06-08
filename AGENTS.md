# Repository Guidelines

## Project Structure & Module Organization

This repository contains the macOS `terminal-notifier` app.

- `Terminal Notifier/` holds the Objective-C application source, plist, precompiled header, and localized UI resources in `en.lproj/`.
- `Terminal Notifier.xcodeproj/` is the Xcode project and shared scheme metadata.
- `assets/` stores README screenshots and documentation images.
- `scripts/` contains manual CLI smoke tests.
- `README.markdown`, `CONTRIBUTING.md`, and `CODE_OF_CONDUCT.md` define user-facing behavior and contribution expectations.

## Build, Test, and Development Commands

- `just build` builds a Release app into `build/Release/terminal-notifier.app` and ad-hoc signs the development bundle.
- `just run -message hi` builds, then runs the freshly built binary with the provided CLI arguments.
- `just smoke` sends a quick notification for manual verification.
- `just test-cli` runs the interactive CLI smoke-test suite in `scripts/test-cli.sh`.
- `xcodebuild -project "Terminal Notifier.xcodeproj" -configuration Release SYMROOT=build` builds without `just`. This requires full Xcode, not only Command Line Tools.
- `git diff --check` catches trailing whitespace before committing.

## Coding Style & Naming Conventions

Match the existing style in the touched file. Objective-C uses two-space indentation, Cocoa naming conventions, and descriptive method names such as `deliverNotificationWithTitle:subtitle:message:options:sound:`. Keep public CLI option names aligned with README usage, such as `-message`, `-group`, and `-sender`.

## Testing Guidelines

There is no fully automated notification UI test suite. For Objective-C changes, build with Xcode and run targeted CLI checks. Use the interactive smoke test when changing delivery, grouping, removal, images, sender spoofing, or click handlers.

```sh
./build/Release/terminal-notifier.app/Contents/MacOS/terminal-notifier -message "Test"
```

## Commit & Pull Request Guidelines

Recent history uses short, descriptive commit subjects, often imperative or documentation-focused, for example `Create CONTRIBUTING.md` or `Update deployment target`. Keep commits focused and logical. Pull requests should reference the related issue, describe behavior changes, include reproduction steps for bugs, and add screenshots when notification UI or README assets change. Follow `CONTRIBUTING.md`: use topic branches, avoid direct work on `master`, and do not merge your own pull request.
