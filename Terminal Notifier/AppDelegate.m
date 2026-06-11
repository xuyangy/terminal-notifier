#import "AppDelegate.h"
#import <stdatomic.h>

NSString * const TerminalNotifierBundleID = @"fr.julienxx.oss.terminal-notifier";

@implementation NSUserDefaults (SubscriptAndUnescape)
- (id)objectForKeyedSubscript:(id)key;
{
  id obj = [self objectForKey:key];
  if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj hasPrefix:@"\\"]) {
    obj = [(NSString *)obj substringFromIndex:1];
  }
  return obj;
}
@end


@implementation AppDelegate {
  BOOL _responseHandled;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification;
{
  // Set the UN delegate before launch completes so click-launched responses
  // are delivered to us instead of being dropped.
  [UNUserNotificationCenter currentNotificationCenter].delegate = self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification;
{
  // -help and -version are handled in main() before NSApplicationMain.
  NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *subtitle = defaults[@"subtitle"];
  NSString *message  = defaults[@"message"];
  NSString *remove   = defaults[@"remove"];
  NSString *list     = defaults[@"list"];
  NSString *sound    = defaults[@"sound"];

  // If there is no message and data is piped to the application, use that instead.
  // When the .app is launched by Launch Services (e.g. from a notification click),
  // stdin is /dev/null — non-tty but EOFs immediately — so the read yields @"".
  // Treat an empty read as "no message" so we fall through to the response-waiting
  // fallback rather than posting an empty notification.
  // -list never uses the message, so skip the read for it — otherwise a stdin
  // pipe that never closes (e.g. invocation from a daemon) blocks the listing.
  if (message == nil && list == nil && !isatty(STDIN_FILENO)) {
    NSData *inputData = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSString *piped = [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
    if (piped.length > 0) message = piped;
  }

  if (message == nil && remove == nil && list == nil) {
    // Interactive invocation (stdin is a TTY) can't be a notification-click
    // relaunch, so print help immediately.
    if (isatty(STDIN_FILENO)) {
      PrintHelpBanner();
      exit(1);
    }
    // Otherwise the binary may have been re-launched in response to a
    // notification click; give the UN delegate time to fire
    // didReceiveNotificationResponse: before assuming this is a bare
    // invocation that should print help. A short window risks dropping the
    // click's action on a slow launch, so be generous.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      if (!self->_responseHandled) {
        PrintHelpBanner();
        exit(1);
      }
    });
    return;
  }

  if (list) {
    [self listNotificationWithGroupID:list];
    return;
  }

  NSMutableDictionary *options = [NSMutableDictionary dictionary];
  if (defaults[@"activate"]) options[@"bundleID"]         = defaults[@"activate"];
  if (defaults[@"group"])    options[@"groupID"]          = defaults[@"group"];
  if (defaults[@"execute"])  options[@"command"]          = defaults[@"execute"];
  if (defaults[@"contentImage"]) options[@"contentImage"] = defaults[@"contentImage"];

  if (defaults[@"open"]) {
    NSURL *url = [NSURL URLWithString:defaults[@"open"]];
    // Any URL with a scheme is acceptable: web URLs, file URLs, and
    // host-less schemes like mailto: or custom app schemes.
    if (url && url.scheme.length > 0) {
      options[@"open"] = defaults[@"open"];
    } else {
      NSLog(@"'%@' is not a valid URI.", defaults[@"open"]);
      exit(1);
    }
  }

  // NSProcessInfo may return the pre-main argument snapshot, so the -dnd
  // alias rewritten in main() is not necessarily visible here; accept both.
  if ([args containsObject:@"-ignoreDnD"] || [args containsObject:@"-dnd"]) {
    options[@"ignoreDnD"] = @YES;
  }

  void (^deliverIfNeeded)(void) = ^{
    if (message) {
      [self requestAuthorizationThenDeliverWithTitle:defaults[@"title"] ?: @"Terminal"
                                            subtitle:subtitle
                                             message:message
                                             options:options
                                               sound:sound];
    } else {
      exit(0);
    }
  };

  if (remove) {
    [self removeNotificationsWithGroupID:remove completion:deliverIfNeeded];
  } else {
    deliverIfNeeded();
  }
}

- (NSURL *)resolveImageURL:(NSString *)url;
{
  NSURL *imageURL = [NSURL URLWithString:url];
  if ([[imageURL scheme] length] == 0) {
    imageURL = [NSURL fileURLWithPath:url];
  }
  return imageURL;
}

// The name this app shows under in System Settings -> Notifications.
- (NSString *)notificationSettingsDisplayName;
{
  NSBundle *bundle = [NSBundle mainBundle];
  return [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]
      ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"]
      ?: @"terminal-notifier";
}

- (void)exitForDeniedAuthorization;
{
  NSLog(@"[!] Notifications for '%@' are turned off. Enable them in "
        @"System Settings -> Notifications -> %@ and try again.",
        [self notificationSettingsDisplayName], [self notificationSettingsDisplayName]);
  exit(1);
}

- (void)requestAuthorizationThenDeliverWithTitle:(NSString *)title
                                        subtitle:(NSString *)subtitle
                                         message:(NSString *)message
                                         options:(NSDictionary *)options
                                           sound:(NSString *)sound;
{
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
    // When the user has switched the app off in System Settings,
    // requestAuthorizationWithOptions: fails with an unhelpful generic
    // error, so detect the denial up front and explain how to fix it.
    if (settings.authorizationStatus == UNAuthorizationStatusDenied) {
      [self exitForDeniedAuthorization];
    }

    UNAuthorizationOptions authOptions = UNAuthorizationOptionAlert | UNAuthorizationOptionSound;
    [center requestAuthorizationWithOptions:authOptions
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
      if (error) {
        if ([error.domain isEqualToString:UNErrorDomain]
            && error.code == UNErrorCodeNotificationsNotAllowed) {
          [self exitForDeniedAuthorization];
        }
        NSLog(@"[!] Authorization request failed: %@", error.localizedDescription);
        exit(1);
      }
      if (!granted) {
        [self exitForDeniedAuthorization];
      }
      [self deliverNotificationWithTitle:title
                                subtitle:subtitle
                                 message:message
                                 options:options
                                   sound:sound];
    }];
  }];
}

- (void)deliverNotificationWithTitle:(NSString *)title
                            subtitle:(NSString *)subtitle
                             message:(NSString *)message
                             options:(NSDictionary *)options
                               sound:(NSString *)sound;
{
  UNMutableNotificationContent *content = [UNMutableNotificationContent new];
  content.title = title ?: @"";
  if (subtitle) content.subtitle = subtitle;
  content.body = message ?: @"";
  content.userInfo = options;

  if (sound != nil) {
    content.sound = [sound isEqualToString:@"default"]
        ? [UNNotificationSound defaultSound]
        : [UNNotificationSound soundNamed:sound];
  }

  if (options[@"contentImage"]) {
    NSURL *imageURL = [self resolveImageURL:options[@"contentImage"]];
    // UNNotificationAttachment MOVES the attached file into the system's
    // notification data store, which would delete the user's original.
    // Attach a temporary copy instead.
    if (imageURL.isFileURL) {
      NSString *ext = imageURL.pathExtension.length > 0 ? imageURL.pathExtension : @"png";
      NSString *tmpName = [NSString stringWithFormat:@"terminal-notifier-attachment-%@.%@",
                           [[NSUUID UUID] UUIDString], ext];
      NSURL *tmpURL = [NSURL fileURLWithPath:
                       [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName]];
      NSError *copyErr = nil;
      if ([[NSFileManager defaultManager] copyItemAtURL:imageURL toURL:tmpURL error:&copyErr]) {
        imageURL = tmpURL;
      } else {
        NSLog(@"[!] Failed to read contentImage: %@", copyErr.localizedDescription);
        imageURL = nil;
      }
    }
    if (imageURL) {
      NSError *attachErr = nil;
      UNNotificationAttachment *attachment =
        [UNNotificationAttachment attachmentWithIdentifier:@"contentImage"
                                                       URL:imageURL
                                                   options:nil
                                                     error:&attachErr];
      if (attachment) {
        content.attachments = @[attachment];
      } else {
        NSLog(@"[!] Failed to attach contentImage: %@", attachErr.localizedDescription);
      }
    }
  }

  if (options[@"ignoreDnD"]) {
    if (@available(macOS 12.0, *)) {
      content.interruptionLevel = UNNotificationInterruptionLevelTimeSensitive;
    }
  }

  // Use the group ID as the request identifier so re-sending the same group
  // replaces the existing notification, matching the historical behavior.
  NSString *identifier = options[@"groupID"] ?: [[NSUUID UUID] UUIDString];
  UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                       content:content
                                                                       trigger:nil];

  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  __block atomic_flag exited = ATOMIC_FLAG_INIT;
  void (^safeExit)(int) = ^(int status) {
    if (!atomic_flag_test_and_set(&exited)) {
      exit(status);
    }
  };

  [center addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
    if (error) {
      NSLog(@"[!] Failed to deliver notification: %@", error.localizedDescription);
      safeExit(1);
    }
    safeExit(0);
  }];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    NSLog(@"[!] Notification delivery did not complete within 10 seconds.");
    safeExit(2);
  });
}

- (void)removeNotificationsWithGroupID:(NSString *)groupID
                            completion:(void (^)(void))completion;
{
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (UNNotification *n in notifications) {
      NSString *deliveredGroupID = n.request.content.userInfo[@"groupID"];
      if ([@"ALL" isEqualToString:groupID] || [deliveredGroupID isEqualToString:groupID]) {
        [identifiers addObject:n.request.identifier];
        printf("* Removing previously sent notification, which was sent on: %s\n",
               [[n.date description] UTF8String]);
      }
    }
    if (identifiers.count > 0) {
      [center removeDeliveredNotificationsWithIdentifiers:identifiers];
    }
    dispatch_async(dispatch_get_main_queue(), completion);
  }];
}

- (void)listNotificationWithGroupID:(NSString *)listGroupID;
{
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (UNNotification *n in notifications) {
      NSString *deliveredGroupID = n.request.content.userInfo[@"groupID"];
      if ([@"ALL" isEqualToString:listGroupID] || [deliveredGroupID isEqualToString:listGroupID]) {
        [lines addObject:[NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@",
                          deliveredGroupID ?: @"",
                          n.request.content.title ?: @"",
                          n.request.content.subtitle ?: @"",
                          n.request.content.body ?: @"",
                          [n.date description]]];
      }
    }
    if (lines.count > 0) {
      printf("GroupID\tTitle\tSubtitle\tMessage\tDelivered At\n");
      for (NSString *line in lines) {
        printf("%s\n", [line UTF8String]);
      }
    }
    exit(0);
  }];
}

#pragma mark - UNUserNotificationCenterDelegate

// Show the banner even if our (short-lived) app is foreground when delivery happens.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler;
{
  if (@available(macOS 11.0, *)) {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
  } else {
    completionHandler(UNNotificationPresentationOptionAlert | UNNotificationPresentationOptionSound);
  }
}

// Invoked when the user clicks a delivered notification (relaunches the app).
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler;
{
  _responseHandled = YES;

  UNNotification *userNotification = response.notification;
  NSDictionary *userInfo = userNotification.request.content.userInfo;
  NSString *groupID  = userInfo[@"groupID"];
  NSString *bundleID = userInfo[@"bundleID"];
  NSString *command  = userInfo[@"command"];
  NSString *open     = userInfo[@"open"];

  NSLog(@"User activated notification:");
  NSLog(@" group ID: %@", groupID);
  NSLog(@"    title: %@", userNotification.request.content.title);
  NSLog(@" subtitle: %@", userNotification.request.content.subtitle);
  NSLog(@"  message: %@", userNotification.request.content.body);
  NSLog(@"bundle ID: %@", bundleID);
  NSLog(@"  command: %@", command);
  NSLog(@"     open: %@", open);

  BOOL success = YES;
  if (bundleID) success &= [self activateAppWithBundleID:bundleID];
  if (command)  success &= [self executeShellCommand:command];
  if (open) {
    NSURL *url = [NSURL URLWithString:open];
    if (url) {
      success &= [[NSWorkspace sharedWorkspace] openURL:url];
    } else {
      NSLog(@"[!] Stored open URL is not valid: %@", open);
      success = NO;
    }
  }

  completionHandler();
  exit(success ? 0 : 1);
}

// Activate via NSRunningApplication/NSWorkspace rather than ScriptingBridge:
// SBApplication sends an Apple Event, which on 10.14+ needs Automation (TCC)
// consent that a short-lived background process can't meaningfully obtain.
- (BOOL)activateAppWithBundleID:(NSString *)bundleID;
{
  NSRunningApplication *running =
    [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].firstObject;
  if (running) {
    return [running activateWithOptions:NSApplicationActivateAllWindows];
  }

  NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
  NSURL *appURL = [workspace URLForApplicationWithBundleIdentifier:bundleID];
  if (!appURL) {
    NSLog(@"Unable to find an application with the specified bundle identifier.");
    return NO;
  }

  if (@available(macOS 10.15, *)) {
    // openApplicationAtURL: is asynchronous and we exit right after handling
    // the response, so block (with a timeout) until the launch is confirmed.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL launched = NO;
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.activates = YES;
    [workspace openApplicationAtURL:appURL
                      configuration:config
                  completionHandler:^(NSRunningApplication *app, NSError *error) {
      if (error) NSLog(@"Unable to activate application: %@", error.localizedDescription);
      launched = (app != nil);
      dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
    return launched;
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return [workspace launchApplication:appURL.path];
#pragma clang diagnostic pop
}

- (BOOL)executeShellCommand:(NSString *)command;
{
  NSPipe *pipe = [NSPipe pipe];
  NSFileHandle *fileHandle = [pipe fileHandleForReading];

  NSTask *task = [NSTask new];
  task.launchPath = @"/bin/sh";
  task.arguments = @[@"-c", command];
  task.standardOutput = pipe;
  task.standardError = pipe;
  [task launch];

  NSData *data = nil;
  NSMutableData *accumulatedData = [NSMutableData data];
  while ((data = [fileHandle availableData]) && [data length]) {
    [accumulatedData appendData:data];
  }

  [task waitUntilExit];
  NSLog(@"command output:\n%@", [[NSString alloc] initWithData:accumulatedData encoding:NSUTF8StringEncoding]);
  return [task terminationStatus] == 0;
}

@end
