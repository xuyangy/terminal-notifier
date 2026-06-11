#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <unistd.h>
#import "AppDelegate.h"

// -sender / -appIcon spoofing
// ---------------------------
// terminal-notifier's old -sender flag asked the legacy notification API to
// attribute a notification to another bundle ID. UserNotifications instead
// reads identity from the calling bundle's CFBundleIdentifier, so the flag
// became a no-op.
//
// We restore the feature the same way the manual workaround does it: clone
// our own .app into a per-target cached bundle, overwrite its icon /
// display name / bundle ID, re-sign ad-hoc, then execv into the clone. The
// child process is then *actually* running from a bundle that looks like
// the sender app, and the UN framework attributes notifications correctly.
//
// Triggered by `-sender BUNDLE_ID` and/or `-appIcon URL`. Skipped when the
// TN_SPOOFED env var is set (set by us right before execv, to prevent loops).

static NSString *FindStringArg(NSArray<NSString *> *args, NSString *flag) {
  NSUInteger idx = [args indexOfObject:flag];
  if (idx == NSNotFound || idx + 1 >= args.count) return nil;
  return args[idx + 1];
}

static BOOL HasArg(int argc, char *argv[], const char *flag) {
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], flag) == 0) return YES;
  }
  return NO;
}

void PrintVersion(void) {
  NSBundle *bundle = [NSBundle mainBundle];
  const char *appName = [[bundle objectForInfoDictionaryKey:@"CFBundleExecutable"] UTF8String];
  const char *appVersion = [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String];
  printf("%s %s.\n", appName, appVersion);
}

void PrintHelpBanner(void) {
  NSBundle *bundle = [NSBundle mainBundle];
  const char *appName = [[bundle objectForInfoDictionaryKey:@"CFBundleExecutable"] UTF8String];
  const char *appVersion = [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String];
  printf("%s (%s) is a command-line tool to send macOS User Notifications.\n" \
         "\n" \
         "Usage: %s -message VALUE [options]\n" \
         "       %s -remove ID\n" \
         "       %s -list ID\n" \
         "\n" \
         "   Either of these is required (unless message data is piped to the tool):\n" \
         "\n" \
         "       -help              Display this help banner.\n" \
         "       -version           Display terminal-notifier version.\n" \
         "       -message VALUE     The notification message.\n" \
         "       -remove ID         Removes a notification with the specified ‘group’ ID.\n" \
         "       -list ID           If the specified ‘group’ ID exists show when it was delivered,\n" \
         "                          or use ‘ALL’ as ID to see all notifications.\n" \
         "                          The output is a tab-separated list.\n"
         "\n" \
         "   Optional:\n" \
         "\n" \
         "       -title VALUE       The notification title. Defaults to ‘Terminal’.\n" \
         "       -subtitle VALUE    The notification subtitle.\n" \
         "       -sound NAME        The name of a sound to play when the notification appears. The names are listed\n" \
         "                          in Sound Preferences. Use 'default' for the default notification sound.\n" \
         "       -group ID          A string which identifies the group the notifications belong to.\n" \
         "                          Old notifications with the same ID will be removed.\n" \
         "       -activate ID       The bundle identifier of the application to activate when the user clicks the notification.\n" \
         "       -sender ID         Make the notification appear to come from the app with this bundle ID.\n" \
         "                          terminal-notifier re-launches itself from a cached clone of its .app\n" \
         "                          bundle whose icon, display name, and bundle ID match the sender.\n" \
         "                          First use of a given sender shows the macOS notification-permission prompt.\n" \
         "       -appIcon PATH      Override the notification icon. Accepts .icns directly; other image\n" \
         "                          formats (png, jpg, tiff, …) are rendered to .icns automatically.\n" \
         "                          Combines with -sender (keeps the sender's name, swaps the icon).\n" \
         "       -contentImage URL  The URL of an image to display attached to the notification.\n" \
         "                          Supported types: png, jpg, jpeg, gif. (.icns is NOT supported.)\n" \
         "       -open URL          The URL of a resource to open when the user clicks the notification.\n" \
         "       -execute COMMAND   A shell command to perform when the user clicks the notification.\n" \
         "       -ignoreDnD         Mark notification as time-sensitive (requires entitlement to bypass Focus/DnD).\n" \
         "\n" \
         "When the user activates a notification, the results are logged to the system logs.\n" \
         "Use Console.app to view these logs.\n" \
         "\n" \
         "Note that in some circumstances the first character of a message has to be escaped in order to be recognized.\n" \
         "An example of this is when using an open bracket, which has to be escaped like so: ‘\\[’.\n" \
         "\n" \
         "For more information see https://github.com/julienXX/terminal-notifier.\n",
         appName, appVersion, appName, appName, appName);
}

// Resolve the .app bundle for a given bundle ID. Uses the modern API on
// macOS 12+, falls back to the deprecated one for older systems.
static NSString *AppPathForBundleID(NSString *bundleID) {
  NSWorkspace *ws = [NSWorkspace sharedWorkspace];
  if (@available(macOS 12.0, *)) {
    NSArray<NSURL *> *urls = [ws URLsForApplicationsWithBundleIdentifier:bundleID];
    return urls.firstObject.path;
  }
  return [ws absolutePathForAppBundleWithIdentifier:bundleID];
}

// Locate the .icns file (or any usable image) representing this app bundle.
// Prefers CFBundleIconFile, falls back to the asset-catalog icon name, then
// to whatever NSWorkspace returns for the bundle.
static NSString *IconPathForAppBundle(NSString *appPath) {
  NSString *plistPath = [appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
  NSString *iconName = info[@"CFBundleIconFile"];
  if (iconName.length > 0) {
    if (![iconName.pathExtension isEqualToString:@"icns"]) {
      iconName = [iconName stringByAppendingPathExtension:@"icns"];
    }
    NSString *path = [appPath stringByAppendingPathComponent:
                      [@"Contents/Resources/" stringByAppendingString:iconName]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
  }
  // Asset-catalog icon (CFBundleIconName) — no plain .icns on disk. The
  // caller will have to render NSWorkspace's icon image into one.
  return nil;
}

// Render the system-provided icon for a path into a .icns file using
// iconutil. Returns YES on success.
static BOOL RenderIconToICNS(NSImage *image, NSString *destICNS) {
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *iconset = [tmpDir stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"tn-spoof-%@.iconset",
                        [[NSUUID UUID] UUIDString]]];
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:iconset error:nil];
  if (![fm createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:nil]) {
    return NO;
  }

  // Sizes iconutil expects in an .iconset directory.
  NSArray *sizes = @[ @16, @32, @128, @256, @512 ];
  for (NSNumber *s in sizes) {
    CGFloat px = s.doubleValue;
    for (int scale = 1; scale <= 2; scale++) {
      CGFloat pxScaled = px * scale;
      NSImage *resized = [[NSImage alloc] initWithSize:NSMakeSize(px, px)];
      [resized lockFocus];
      [image drawInRect:NSMakeRect(0, 0, px, px)
               fromRect:NSZeroRect
              operation:NSCompositingOperationCopy
               fraction:1.0];
      [resized unlockFocus];
      CGImageRef cg = [resized CGImageForProposedRect:NULL context:nil hints:nil];
      if (!cg) continue;
      NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
      // Force the bitmap to the scaled pixel size so iconutil accepts it.
      rep.size = NSMakeSize(pxScaled, pxScaled);
      NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      NSString *name = (scale == 1)
        ? [NSString stringWithFormat:@"icon_%.fx%.f.png", px, px]
        : [NSString stringWithFormat:@"icon_%.fx%.f@2x.png", px, px];
      [png writeToFile:[iconset stringByAppendingPathComponent:name] atomically:YES];
    }
  }

  NSTask *task = [NSTask new];
  task.launchPath = @"/usr/bin/iconutil";
  task.arguments = @[@"-c", @"icns", iconset, @"-o", destICNS];
  task.standardOutput = [NSPipe pipe];
  task.standardError = [NSPipe pipe];
  @try { [task launch]; [task waitUntilExit]; }
  @catch (NSException *e) { return NO; }
  [fm removeItemAtPath:iconset error:nil];
  return task.terminationStatus == 0 &&
         [fm fileExistsAtPath:destICNS];
}

// Produce a .icns at destICNS representing `senderAppPath` (which may use
// an asset-catalog icon). Returns YES on success.
static BOOL ProduceICNSForSenderApp(NSString *senderAppPath, NSString *destICNS) {
  NSString *direct = IconPathForAppBundle(senderAppPath);
  if (direct) {
    NSError *err = nil;
    [[NSFileManager defaultManager] removeItemAtPath:destICNS error:nil];
    if ([[NSFileManager defaultManager] copyItemAtPath:direct toPath:destICNS error:&err]) {
      return YES;
    }
  }
  NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:senderAppPath];
  if (!icon) return NO;
  return RenderIconToICNS(icon, destICNS);
}

// Produce a .icns at destICNS from an arbitrary image path or file URL
// (anything NSImage can load). Direct copy if the source is already .icns.
static BOOL ProduceICNSFromImagePath(NSString *imagePath, NSString *destICNS) {
  NSURL *imageURL = [NSURL URLWithString:imagePath];
  if (imageURL.isFileURL) imagePath = imageURL.path;

  if ([imagePath.pathExtension.lowercaseString isEqualToString:@"icns"]) {
    NSError *err = nil;
    [[NSFileManager defaultManager] removeItemAtPath:destICNS error:nil];
    if ([[NSFileManager defaultManager] copyItemAtPath:imagePath toPath:destICNS error:&err]) {
      return YES;
    }
  }
  NSImage *image = [[NSImage alloc] initWithContentsOfFile:imagePath];
  if (!image) return NO;
  return RenderIconToICNS(image, destICNS);
}

// Build (or refresh) a spoof clone of our own app bundle.
//
//   spoofAppPath  — destination path for the cloned .app
//   sourceAppPath — our own [[NSBundle mainBundle] bundlePath]
//   iconSourceICNS — path to the .icns to install as the spoof's icon
//   spoofBundleID — bundle ID to write into the spoof's Info.plist
//   displayName   — CFBundleName for the spoof (shown in Notification Center)
static BOOL BuildSpoofBundle(NSString *spoofAppPath,
                             NSString *sourceAppPath,
                             NSString *iconSourceICNS,
                             NSString *spoofBundleID,
                             NSString *displayName) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *err = nil;
  [fm removeItemAtPath:spoofAppPath error:nil];
  if (![fm copyItemAtPath:sourceAppPath toPath:spoofAppPath error:&err]) {
    fprintf(stderr, "[!] sender spoof: copy failed: %s\n",
            err.localizedDescription.UTF8String);
    return NO;
  }

  NSString *infoPath = [spoofAppPath stringByAppendingPathComponent:@"Contents/Info.plist"];
  NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfFile:infoPath] mutableCopy];
  if (!info) {
    fprintf(stderr, "[!] sender spoof: couldn't read Info.plist\n");
    return NO;
  }
  NSString *iconName = info[@"CFBundleIconFile"];
  if (iconName.length == 0) iconName = @"Terminal";
  if (![iconName.pathExtension isEqualToString:@"icns"]) {
    iconName = [iconName stringByAppendingPathExtension:@"icns"];
  }
  NSString *destIconPath = [spoofAppPath stringByAppendingPathComponent:
                            [@"Contents/Resources/" stringByAppendingString:iconName]];
  [fm removeItemAtPath:destIconPath error:nil];
  if (![fm copyItemAtPath:iconSourceICNS toPath:destIconPath error:&err]) {
    fprintf(stderr, "[!] sender spoof: icon install failed: %s\n",
            err.localizedDescription.UTF8String);
    return NO;
  }

  info[@"CFBundleIdentifier"] = spoofBundleID;
  if (displayName) info[@"CFBundleName"] = displayName;
  [info writeToFile:infoPath atomically:YES];

  NSTask *codesign = [NSTask new];
  codesign.launchPath = @"/usr/bin/codesign";
  codesign.arguments = @[@"--force", @"--deep", @"--sign", @"-", spoofAppPath];
  codesign.standardOutput = [NSPipe pipe];
  codesign.standardError = [NSPipe pipe];
  @try { [codesign launch]; [codesign waitUntilExit]; }
  @catch (NSException *e) {
    fprintf(stderr, "[!] sender spoof: codesign launch failed: %s\n",
            e.reason.UTF8String);
    return NO;
  }
  if (codesign.terminationStatus != 0) {
    fprintf(stderr, "[!] sender spoof: codesign exited %d\n", codesign.terminationStatus);
    return NO;
  }

  // Register the spoof with Launch Services so macOS recognises it as an
  // installed app. Without this, requestAuthorizationWithOptions: returns
  // "Notifications are not allowed for this application" without ever
  // surfacing the permission prompt — the OS doesn't know the bundle exists.
  NSTask *lsregister = [NSTask new];
  lsregister.launchPath = @"/System/Library/Frameworks/CoreServices.framework/"
                         @"Versions/Current/Frameworks/LaunchServices.framework/"
                         @"Versions/Current/Support/lsregister";
  lsregister.arguments = @[@"-f", spoofAppPath];
  lsregister.standardOutput = [NSPipe pipe];
  lsregister.standardError = [NSPipe pipe];
  @try { [lsregister launch]; [lsregister waitUntilExit]; }
  @catch (NSException *e) {
    fprintf(stderr, "[!] sender spoof: lsregister launch failed: %s\n",
            e.reason.UTF8String);
    // Non-fatal: a stale Launch Services entry usually still works.
  }

  return YES;
}

// Short stable hex digest of a string. Used to derive cache paths/IDs.
static NSString *ShortHash(NSString *input) {
  NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

  NSMutableString *hex = [NSMutableString stringWithCapacity:16];
  for (NSUInteger i = 0; i < 8; i++) {
    [hex appendFormat:@"%02x", digest[i]];
  }
  return hex;
}

// Read a file's mtime as an NSDate; nil if missing.
static NSDate *MTimeAt(NSString *path) {
  return [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}

static BOOL PathIsNewerThanPath(NSString *leftPath, NSString *rightPath) {
  NSDate *left = MTimeAt(leftPath);
  NSDate *right = MTimeAt(rightPath);
  if (!left) return NO;
  if (!right) return YES;
  return [left compare:right] == NSOrderedDescending;
}

static void CleanupStaleSpoofCache(NSString *cacheDir, NSString *keepAppPath, NSString *keepIconPath) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:cacheDir error:nil];
  NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-(30.0 * 24.0 * 60.0 * 60.0)];

  for (NSString *entry in entries) {
    if (![entry.pathExtension.lowercaseString isEqualToString:@"app"] &&
        ![entry.pathExtension.lowercaseString isEqualToString:@"icns"]) {
      continue;
    }

    NSString *path = [cacheDir stringByAppendingPathComponent:entry];
    if ([path isEqualToString:keepAppPath] || [path isEqualToString:keepIconPath]) continue;

    NSDate *modified = MTimeAt(path);
    if (modified && [modified compare:cutoff] == NSOrderedAscending) {
      [fm removeItemAtPath:path error:nil];
    }
  }
}

// The actual entry point for spoof handling. Returns only if we did NOT
// exec (either nothing to do, or a recoverable error and we want to fall
// through to the default identity).
static void HandleSpoofIfNeeded(int argc, char *argv[]) {
  if (getenv("TN_SPOOFED")) return;

  NSMutableArray<NSString *> *args = [NSMutableArray array];
  for (int i = 0; i < argc; i++) [args addObject:@(argv[i])];

  NSString *senderID = FindStringArg(args, @"-sender");
  NSString *appIcon  = FindStringArg(args, @"-appIcon");
  if (!senderID && !appIcon) return;

  NSString *sourceAppPath = [[NSBundle mainBundle] bundlePath];
  if (![sourceAppPath.pathExtension isEqualToString:@"app"]) {
    // Running outside a .app (e.g. a stripped binary) — can't clone ourselves.
    return;
  }

  // Resolve the sender, if provided. A missing sender is non-fatal; we
  // still honour -appIcon and fall through to the default name.
  NSString *senderAppPath = nil;
  NSString *senderDisplayName = nil;
  if (senderID) {
    senderAppPath = AppPathForBundleID(senderID);
    if (!senderAppPath) {
      fprintf(stderr, "[!] -sender: no application found for bundle id '%s'\n",
              senderID.UTF8String);
    } else {
      NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [senderAppPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
      senderDisplayName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
      if (!senderDisplayName) {
        senderDisplayName = [senderAppPath.lastPathComponent stringByDeletingPathExtension];
      }
    }
  }

  // Derive a cache key. Different (sender, icon-override) combinations get
  // independent spoof bundles so they coexist in Notification Center.
  NSString *cacheKey;
  if (senderID && appIcon) {
    cacheKey = [NSString stringWithFormat:@"%@-icon-%@", senderID, ShortHash(appIcon)];
  } else if (senderID) {
    cacheKey = senderID;
  } else {
    cacheKey = [NSString stringWithFormat:@"icon-%@", ShortHash(appIcon)];
  }

  NSString *cacheDir = [NSHomeDirectory() stringByAppendingPathComponent:
                        @"Library/Application Support/terminal-notifier/spoof"];
  [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  NSString *spoofAppPath = [cacheDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"%@.app", cacheKey]];
  NSString *spoofBinary = [spoofAppPath stringByAppendingPathComponent:
                           @"Contents/MacOS/terminal-notifier"];
  NSString *stampPath = [spoofAppPath stringByAppendingPathComponent:@".built-from"];
  // Icon staged outside the .app — BuildSpoofBundle wipes the .app before copying.
  NSString *iconStagePath = [cacheDir stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"%@.icns", cacheKey]];
  CleanupStaleSpoofCache(cacheDir, spoofAppPath, iconStagePath);

  // The spoof bundle ID combines our own base ID with a hash of the cache
  // key, so each spoof gets its own Notification Center entry without
  // colliding with the real sender app's bundle.
  NSString *baseBundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"fr.julienxx.oss.terminal-notifier";
  NSString *spoofBundleID = [NSString stringWithFormat:@"%@.spoof.%@",
                             baseBundleID, ShortHash(cacheKey)];

  // Detect whether the spoof needs to be (re)built. Rebuild when:
  //   - it doesn't exist
  //   - our own binary is newer than the spoof's
  //   - the stamp doesn't match our current source app path
  //   - the icon source (sender app or override file) is newer than the
  //     icon we staged last time
  BOOL needsBuild = NO;
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm isExecutableFileAtPath:spoofBinary]) {
    needsBuild = YES;
  } else {
    NSString *stamp = [NSString stringWithContentsOfFile:stampPath
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    if (![stamp isEqualToString:sourceAppPath]) needsBuild = YES;
    NSString *sourceBinary = [sourceAppPath stringByAppendingPathComponent:
                              @"Contents/MacOS/terminal-notifier"];
    if (!needsBuild && PathIsNewerThanPath(sourceBinary, spoofBinary)) {
      needsBuild = YES;
    }
    if (!needsBuild) {
      NSString *iconSrc = appIcon ?: (senderAppPath ? IconPathForAppBundle(senderAppPath) : nil);
      if (iconSrc && PathIsNewerThanPath(iconSrc, iconStagePath)) {
        needsBuild = YES;
      }
    }
  }

  if (needsBuild) {
    // Stage the icns first; bail out (fall through to default identity)
    // if we couldn't produce one.
    [fm createDirectoryAtPath:spoofAppPath withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL haveIcon = NO;
    if (appIcon) {
      haveIcon = ProduceICNSFromImagePath(appIcon, iconStagePath);
      if (!haveIcon) {
        fprintf(stderr, "[!] -appIcon: couldn't convert '%s' to icns\n",
                appIcon.UTF8String);
      }
    } else if (senderAppPath) {
      haveIcon = ProduceICNSForSenderApp(senderAppPath, iconStagePath);
      if (!haveIcon) {
        fprintf(stderr, "[!] -sender: couldn't extract icon from '%s'\n",
                senderAppPath.UTF8String);
      }
    }
    if (!haveIcon) {
      [fm removeItemAtPath:spoofAppPath error:nil];
      return;
    }
    if (!BuildSpoofBundle(spoofAppPath, sourceAppPath,
                          iconStagePath, spoofBundleID, senderDisplayName)) {
      [fm removeItemAtPath:spoofAppPath error:nil];
      return;
    }
    [sourceAppPath writeToFile:stampPath
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:nil];
  }

  // Re-exec from the spoof bundle. Pass TN_SPOOFED so the new process
  // doesn't try to spoof again.
  setenv("TN_SPOOFED", "1", 1);
  char **newargv = malloc(sizeof(char *) * (argc + 1));
  newargv[0] = strdup(spoofBinary.fileSystemRepresentation);
  for (int i = 1; i < argc; i++) newargv[i] = argv[i];
  newargv[argc] = NULL;
  execv(newargv[0], newargv);
  // execv only returns on error.
  perror("[!] sender spoof: execv failed");
  free(newargv[0]);
  free(newargv);
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        if (HasArg(argc, argv, "-help")) {
            PrintHelpBanner();
            return 0;
        }
        if (HasArg(argc, argv, "-version")) {
            PrintVersion();
            return 0;
        }
        HandleSpoofIfNeeded(argc, argv);
    }
    return NSApplicationMain(argc, (const char **)argv);
}
