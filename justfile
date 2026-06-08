set shell := ["bash", "-cu"]

project := "Terminal Notifier.xcodeproj"
build_dir := justfile_directory() / "build"
derived_data := build_dir / "DerivedData"
app := build_dir / "Release/terminal-notifier.app"
bin := app / "Contents/MacOS/terminal-notifier"

default:
    @just --list

# Minimum macOS the built binary will run on. Bumped from the project's
# historical 10.10 because modern Xcode SDKs no longer ship libarclite for
# pre-10.13 deployment targets, which breaks linking.
macos_deployment_target := "10.14"
dev_bundle_id := "fr.julienxx.oss.terminal-notifier.dev"
release_bundle_id := "fr.julienxx.oss.terminal-notifier"

# Build a local development app with a distinct notification identity
build:
    xcodebuild -project "{{project}}" -scheme "Terminal Notifier" -configuration Release \
        SYMROOT="{{build_dir}}" \
        -derivedDataPath "{{derived_data}}" \
        MACOSX_DEPLOYMENT_TARGET={{macos_deployment_target}} \
        PRODUCT_BUNDLE_IDENTIFIER={{dev_bundle_id}}
    /usr/libexec/PlistBuddy -c "Set :CFBundleName terminal-notifier (dev)" "{{app}}/Contents/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleName string terminal-notifier (dev)" "{{app}}/Contents/Info.plist"
    codesign --force --sign - "{{app}}"
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "{{app}}"

# Build a production-identity app for signing/notarization/release
release-build:
    xcodebuild -project "{{project}}" -scheme "Terminal Notifier" -configuration Release \
        SYMROOT="{{build_dir}}" \
        -derivedDataPath "{{derived_data}}" \
        MACOSX_DEPLOYMENT_TARGET={{macos_deployment_target}} \
        PRODUCT_BUNDLE_IDENTIFIER={{release_bundle_id}}

# Remove build artifacts
clean:
    rm -rf "{{build_dir}}"

# Run the freshly built binary; forwards args, e.g. `just run -message hi`
run *ARGS: build
    "{{bin}}" {{ARGS}}

# Send a quick smoke-test notification
smoke: build
    "{{bin}}" -title "terminal-notifier (dev)" -message "build OK"

# Run the interactive CLI smoke-test suite
test-cli: build
    scripts/test-cli.sh

# Print the absolute path to the built binary (useful for aliasing)
which: build
    @echo "{{bin}}"

home := env_var("HOME")
install_app_dir := home / "Applications"
install_app := install_app_dir / "terminal-notifier.app"
install_prefix := home / ".local"

# Install the built app to ~/Applications and an exec wrapper to ~/.local/bin
install: build
    rm -rf "{{install_app}}"
    mkdir -p "{{install_app_dir}}"
    cp -R "{{app}}" "{{install_app}}"
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "{{install_app}}"
    mkdir -p "{{install_prefix}}/bin"
    # Use an exec shim rather than a symlink: NSBundle.mainBundle resolves
    # from the path dyld was launched with, so a symlink in ~/.local/bin
    # makes UserNotifications see no bundle and hang on authorization.
    printf '#!/bin/sh\nexec "{{install_app}}/Contents/MacOS/terminal-notifier" "$@"\n' > "{{install_prefix}}/bin/terminal-notifier"
    chmod +x "{{install_prefix}}/bin/terminal-notifier"
    @echo "Installed terminal-notifier to {{install_prefix}}/bin/terminal-notifier"
