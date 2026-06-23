#import "AppDelegate.h"
#import <stdatomic.h>
#import <unistd.h>

NSString * const TerminalNotifierBundleID = @"fr.julienxx.oss.terminal-notifier";

// Exactly one shutdown path may run the activation and exit: a notification
// click, the -wait Return handler, the delivery timeout, or the delivery
// completion itself. With -wait the first two are live concurrently (the UN
// delegate callback's queue is unspecified), so whoever claims shutdown
// first owns it and everyone else backs off.
static atomic_flag TNShutdownClaimed = ATOMIC_FLAG_INIT;
static BOOL TNClaimShutdown(void) {
  return !atomic_flag_test_and_set(&TNShutdownClaimed);
}

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
  // No-value flags (-wait, -ignoreDnD) are merged into the argument domain
  // by main(), so everything is read through NSUserDefaults here.
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
  if (defaults[@"wait"])     options[@"waitForActivation"] = @YES;
  if (defaults[@"focus"])    options[@"focusOrigin"] = [self currentFocusOrigin];

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

  if (defaults[@"ignoreDnD"]) options[@"ignoreDnD"] = @YES;

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

- (NSString *)trimmedString:(NSString *)string;
{
  return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)ttyNameForFileDescriptor:(int)fd;
{
  char *name = ttyname(fd);
  return name ? @(name) : nil;
}

- (NSString *)currentProcessTTY;
{
  return [self ttyNameForFileDescriptor:STDOUT_FILENO]
      ?: [self ttyNameForFileDescriptor:STDERR_FILENO]
      ?: [self ttyNameForFileDescriptor:STDIN_FILENO];
}

- (NSString *)pathForExecutable:(NSString *)executableName;
{
  NSMutableArray<NSString *> *directories = [NSMutableArray array];
  NSString *pathEnv = [NSProcessInfo processInfo].environment[@"PATH"];
  if (pathEnv.length > 0) {
    [directories addObjectsFromArray:[pathEnv componentsSeparatedByString:@":"]];
  }
  [directories addObjectsFromArray:@[@"/opt/homebrew/bin", @"/usr/local/bin", @"/usr/bin", @"/bin"]];

  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  for (NSString *directory in directories) {
    if (directory.length == 0 || ![directory hasPrefix:@"/"] || [seen containsObject:directory]) continue;
    [seen addObject:directory];
    NSString *path = [directory stringByAppendingPathComponent:executableName];
    if ([fm isExecutableFileAtPath:path]) return path;
  }
  return nil;
}

- (int)runTaskAtPath:(NSString *)launchPath
           arguments:(NSArray<NSString *> *)arguments
         environment:(NSDictionary<NSString *, NSString *> *)environment
              output:(NSString **)output;
{
  NSTask *task = [NSTask new];
  task.launchPath = launchPath;
  task.arguments = arguments;
  if (environment) {
    NSMutableDictionary *taskEnv = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [taskEnv addEntriesFromDictionary:environment];
    task.environment = taskEnv;
  }

  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  task.standardError = pipe;

  @try {
    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (output) {
      *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    }
    return task.terminationStatus;
  } @catch (NSException *exception) {
    if (output) *output = @"";
    return -1;
  }
}

- (NSArray<NSString *> *)tmuxArgumentsWithSocket:(NSString *)socket
                                         command:(NSArray<NSString *> *)command;
{
  NSMutableArray<NSString *> *arguments = [NSMutableArray array];
  if (socket.length > 0) {
    [arguments addObjectsFromArray:@[@"-S", socket]];
  }
  [arguments addObjectsFromArray:command];
  return arguments;
}

- (NSDictionary *)tmuxOriginInfoWithPath:(NSString *)tmuxPath
                                  socket:(NSString *)socket
                                    pane:(NSString *)pane;
{
  NSString *format = @"#{client_tty}\t#{session_id}\t#{window_id}\t#{pane_id}";
  NSString *output = nil;
  NSArray *arguments = [self tmuxArgumentsWithSocket:socket
                                             command:@[@"display-message", @"-p", @"-t", pane, format]];
  if ([self runTaskAtPath:tmuxPath arguments:arguments environment:nil output:&output] != 0) {
    return @{};
  }

  NSArray<NSString *> *fields = [[self trimmedString:output] componentsSeparatedByString:@"\t"];
  if (fields.count < 4) return @{};

  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  if (fields[0].length > 0) info[@"clientTTY"] = fields[0];
  if (fields[1].length > 0) info[@"sessionID"] = fields[1];
  if (fields[2].length > 0) info[@"windowID"] = fields[2];
  if (fields[3].length > 0) info[@"paneID"] = fields[3];

  NSString *clientOutput = nil;
  NSString *clientFormat = @"#{client_tty}\t#{client_session}\t#{client_window}\t#{client_active_pane}";
  NSArray *clientArguments = [self tmuxArgumentsWithSocket:socket
                                                   command:@[@"list-clients", @"-F", clientFormat]];
  if ([self runTaskAtPath:tmuxPath arguments:clientArguments environment:nil output:&clientOutput] == 0) {
    NSString *fallbackTTY = nil;
    for (NSString *line in [clientOutput componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
      NSArray<NSString *> *clientFields = [line componentsSeparatedByString:@"\t"];
      if (clientFields.count < 4 || [clientFields[0] length] == 0) continue;

      BOOL samePane = [clientFields[3] isEqualToString:info[@"paneID"]];
      BOOL sameWindow = [clientFields[1] isEqualToString:info[@"sessionID"]]
          && [clientFields[2] isEqualToString:info[@"windowID"]];
      if (samePane) {
        info[@"clientTTY"] = clientFields[0];
        break;
      }
      if (sameWindow && fallbackTTY.length == 0) {
        fallbackTTY = clientFields[0];
      }
    }
    if (fallbackTTY.length > 0 && info[@"clientTTY"] == nil) {
      info[@"clientTTY"] = fallbackTTY;
    }
  }
  return info;
}

- (NSString *)terminalBundleIDForEnvironment:(NSDictionary *)environment;
{
  NSString *termProgram = environment[@"TERM_PROGRAM"];
  if ([termProgram isEqualToString:@"iTerm.app"]) return @"com.googlecode.iterm2";
  if ([termProgram isEqualToString:@"Apple_Terminal"]) return @"com.apple.Terminal";
  return nil;
}

- (NSDictionary *)currentFocusOrigin;
{
  NSDictionary *environment = [NSProcessInfo processInfo].environment;
  NSMutableDictionary *origin = [NSMutableDictionary dictionary];

  NSString *processTTY = [self currentProcessTTY];
  if (processTTY.length > 0) {
    origin[@"terminalTTY"] = processTTY;
  }

  NSString *terminalBundleID = [self terminalBundleIDForEnvironment:environment];
  if (terminalBundleID.length > 0) origin[@"terminalBundleID"] = terminalBundleID;

  NSString *tmuxEnv = environment[@"TMUX"];
  NSString *tmuxPane = environment[@"TMUX_PANE"];
  if (tmuxEnv.length > 0 && tmuxPane.length > 0) {
    origin[@"kind"] = @"tmux";
    origin[@"tmuxEnv"] = tmuxEnv;
    origin[@"tmuxPane"] = tmuxPane;

    NSString *socket = [tmuxEnv componentsSeparatedByString:@","].firstObject;
    if (socket.length > 0) origin[@"tmuxSocket"] = socket;

    NSString *tmuxPath = [self pathForExecutable:@"tmux"];
    if (tmuxPath.length > 0) {
      origin[@"tmuxPath"] = tmuxPath;
      NSDictionary *tmuxInfo = [self tmuxOriginInfoWithPath:tmuxPath socket:socket pane:tmuxPane];
      [origin addEntriesFromDictionary:tmuxInfo];
      if ([tmuxInfo[@"clientTTY"] length] > 0) {
        origin[@"terminalTTY"] = tmuxInfo[@"clientTTY"];
      }
    }
  } else {
    origin[@"kind"] = @"terminal";
  }

  return origin.count > 0 ? origin : @{@"kind": @"unknown"};
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
  __block atomic_bool deliveryCompleted = ATOMIC_VAR_INIT(false);
  void (^safeExit)(int) = ^(int status) {
    if (TNClaimShutdown()) {
      exit(status);
    }
  };

  [center addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
    if (error) {
      NSLog(@"[!] Failed to deliver notification: %@", error.localizedDescription);
      safeExit(1);
    }
    atomic_store(&deliveryCompleted, true);
    if (options[@"waitForActivation"]) {
      [self waitForEnterToActivateNotificationWithIdentifier:identifier
                                                      center:center
                                                        exit:safeExit];
    } else {
      safeExit(0);
    }
  }];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (!atomic_load(&deliveryCompleted)) {
      NSLog(@"[!] Notification delivery did not complete within 10 seconds.");
      safeExit(2);
    }
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

  if (!TNClaimShutdown()) {
    // The -wait Return path already owns the activation; let it exit.
    completionHandler();
    return;
  }

  UNNotification *userNotification = response.notification;
  BOOL success = [self activateNotificationWithUserInfo:userNotification.request.content.userInfo
                                                  title:userNotification.request.content.title
                                               subtitle:userNotification.request.content.subtitle
                                                message:userNotification.request.content.body
                                            logActivation:YES];

  completionHandler();
  exit(success ? 0 : 1);
}

- (void)waitForEnterToActivateNotificationWithIdentifier:(NSString *)identifier
                                                  center:(UNUserNotificationCenter *)center
                                                    exit:(void (^)(int))safeExit;
{
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    FILE *tty = fopen("/dev/tty", "r");
    if (!tty) {
      NSLog(@"[!] -wait requires an interactive controlling terminal.");
      safeExit(1);
      return;
    }

    int ch = EOF;
    do {
      ch = fgetc(tty);
    } while (ch != EOF && ch != '\n' && ch != '\r');
    fclose(tty);

    if (ch == EOF) {
      NSLog(@"[!] Failed to read Return from the controlling terminal.");
      safeExit(1);
      return;
    }

    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
      UNNotification *matched = nil;
      for (UNNotification *notification in notifications) {
        if ([notification.request.identifier isEqualToString:identifier]) {
          matched = notification;
          break;
        }
      }

      if (!matched) {
        NSLog(@"[!] Notification is no longer delivered; Return was ignored.");
        safeExit(1);
        return;
      }

      [center removeDeliveredNotificationsWithIdentifiers:@[identifier]];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!TNClaimShutdown()) return;  // a click owns the activation; it will exit
        BOOL success = [self activateNotificationWithUserInfo:matched.request.content.userInfo
                                                        title:matched.request.content.title
                                                     subtitle:matched.request.content.subtitle
                                                      message:matched.request.content.body
                                                logActivation:NO];
        exit(success ? 0 : 1);
      });
    }];
  });
}

- (NSString *)appleScriptStringLiteral:(NSString *)string;
{
  NSMutableString *escaped = [string mutableCopy] ?: [NSMutableString string];
  [escaped replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, escaped.length)];
  [escaped replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, escaped.length)];
  return [NSString stringWithFormat:@"\"%@\"", escaped];
}

- (BOOL)runAppleScript:(NSString *)script;
{
  NSString *output = nil;
  int status = [self runTaskAtPath:@"/usr/bin/osascript"
                         arguments:@[@"-e", script]
                       environment:nil
                            output:&output];
  NSString *trimmed = [self trimmedString:output];
  if (status == 0 && [trimmed isEqualToString:@"ok"]) return YES;
  if (trimmed.length > 0) {
    NSLog(@"[!] Focus AppleScript did not complete: %@", trimmed);
  }
  return NO;
}

- (BOOL)focusITermSessionWithTTY:(NSString *)tty applicationName:(NSString *)applicationName;
{
  NSString *ttyLiteral = [self appleScriptStringLiteral:tty];
  NSString *ttyNameLiteral = [self appleScriptStringLiteral:tty.lastPathComponent ?: tty];
  NSString *applicationLiteral = [self appleScriptStringLiteral:applicationName];
  NSString *script = [NSString stringWithFormat:
    @"set targetTTY to %@\n"
    "set targetTTYName to %@\n"
    "tell application %@\n"
    "  repeat with w in windows\n"
    "    repeat with t in tabs of w\n"
    "      repeat with s in sessions of t\n"
    "        set sessionTTY to tty of s\n"
    "        if sessionTTY is targetTTY or sessionTTY is targetTTYName or \"/dev/\" & sessionTTY is targetTTY then\n"
    "          select s\n"
    "          select t\n"
    "          select w\n"
    "          activate\n"
    "          return \"ok\"\n"
    "        end if\n"
    "      end repeat\n"
    "    end repeat\n"
    "  end repeat\n"
    "end tell\n"
    "return \"not found\"",
    ttyLiteral, ttyNameLiteral, applicationLiteral];
  return [self runAppleScript:script];
}

- (BOOL)focusITermSessionWithTTY:(NSString *)tty;
{
  return [self focusITermSessionWithTTY:tty applicationName:@"iTerm"]
      || [self focusITermSessionWithTTY:tty applicationName:@"iTerm2"];
}

- (BOOL)focusTerminalTabWithTTY:(NSString *)tty;
{
  NSString *ttyLiteral = [self appleScriptStringLiteral:tty];
  NSString *ttyNameLiteral = [self appleScriptStringLiteral:tty.lastPathComponent ?: tty];
  NSString *script = [NSString stringWithFormat:
    @"set targetTTY to %@\n"
    "set targetTTYName to %@\n"
    "tell application \"Terminal\"\n"
    "  repeat with w in windows\n"
    "    repeat with t in tabs of w\n"
    "      set tabTTY to tty of t\n"
    "      if tabTTY is targetTTY or tabTTY is targetTTYName or \"/dev/\" & tabTTY is targetTTY then\n"
    "        set selected tab of w to t\n"
    "        set index of w to 1\n"
    "        activate\n"
    "        return \"ok\"\n"
    "      end if\n"
    "    end repeat\n"
    "  end repeat\n"
    "end tell\n"
    "return \"not found\"", ttyLiteral, ttyNameLiteral];
  return [self runAppleScript:script];
}

- (BOOL)focusTmuxOrigin:(NSDictionary *)origin;
{
  NSString *tmuxPath = origin[@"tmuxPath"] ?: [self pathForExecutable:@"tmux"];
  NSString *tmuxPane = origin[@"tmuxPane"];
  if (tmuxPath.length == 0 || tmuxPane.length == 0) return NO;

  NSString *socket = origin[@"tmuxSocket"];
  NSString *clientTTY = origin[@"clientTTY"];
  NSString *sessionID = origin[@"sessionID"];
  NSString *windowID = origin[@"windowID"];
  NSString *paneID = origin[@"paneID"] ?: tmuxPane;
  NSDictionary *environment = origin[@"tmuxEnv"] ? @{@"TMUX": origin[@"tmuxEnv"]} : nil;
  BOOL success = NO;

  if (windowID.length > 0) {
    NSArray *selectWindow = [self tmuxArgumentsWithSocket:socket
                                                  command:@[@"select-window", @"-t", windowID]];
    success |= [self runTaskAtPath:tmuxPath arguments:selectWindow environment:environment output:nil] == 0;
  }

  if (paneID.length > 0) {
    NSArray *selectPane = [self tmuxArgumentsWithSocket:socket
                                                command:@[@"select-pane", @"-t", paneID]];
    success |= [self runTaskAtPath:tmuxPath arguments:selectPane environment:environment output:nil] == 0;
  }

  if (clientTTY.length > 0) {
    NSString *target = sessionID.length > 0 ? sessionID : tmuxPane;
    NSArray *arguments = [self tmuxArgumentsWithSocket:socket
                                               command:@[@"switch-client", @"-c", clientTTY, @"-t", target]];
    success |= [self runTaskAtPath:tmuxPath arguments:arguments environment:environment output:nil] == 0;
  }

  return success;
}

- (BOOL)focusTerminalOrigin:(NSDictionary *)origin;
{
  NSString *tty = origin[@"terminalTTY"];
  NSString *bundleID = origin[@"terminalBundleID"];

  if (tty.length > 0 && [bundleID isEqualToString:@"com.googlecode.iterm2"]) {
    if ([self focusITermSessionWithTTY:tty]) return YES;
  }
  if (tty.length > 0 && [bundleID isEqualToString:@"com.apple.Terminal"]) {
    if ([self focusTerminalTabWithTTY:tty]) return YES;
  }
  if (tty.length > 0 && bundleID.length == 0) {
    if ([self focusITermSessionWithTTY:tty]) return YES;
    if ([self focusTerminalTabWithTTY:tty]) return YES;
  }
  if (bundleID.length > 0) {
    return [self activateAppWithBundleID:bundleID];
  }
  return NO;
}

- (BOOL)focusOrigin:(NSDictionary *)origin;
{
  BOOL success = NO;
  if ([origin[@"kind"] isEqualToString:@"tmux"]) {
    success |= [self focusTmuxOrigin:origin];
  }
  success |= [self focusTerminalOrigin:origin];
  if (!success) {
    NSLog(@"[!] Unable to focus notification origin: %@", origin);
  }
  return success;
}

- (BOOL)activateNotificationWithUserInfo:(NSDictionary *)userInfo
                                   title:(NSString *)title
                                subtitle:(NSString *)subtitle
                                 message:(NSString *)message
                           logActivation:(BOOL)logActivation;
{
  NSString *groupID  = userInfo[@"groupID"];
  NSString *bundleID = userInfo[@"bundleID"];
  NSString *command  = userInfo[@"command"];
  NSString *open     = userInfo[@"open"];
  NSDictionary *focusOrigin = [userInfo[@"focusOrigin"] isKindOfClass:[NSDictionary class]]
      ? userInfo[@"focusOrigin"]
      : nil;

  if (logActivation) {
    NSLog(@"User activated notification:");
    NSLog(@" group ID: %@", groupID);
    NSLog(@"    title: %@", title);
    NSLog(@" subtitle: %@", subtitle);
    NSLog(@"  message: %@", message);
    NSLog(@"bundle ID: %@", bundleID);
    NSLog(@"  command: %@", command);
    NSLog(@"     open: %@", open);
    NSLog(@"   origin: %@", focusOrigin);
  }

  BOOL success = YES;
  if (focusOrigin) success &= [self focusOrigin:focusOrigin];
  if (bundleID) success &= [self activateAppWithBundleID:bundleID];
  if (command)  success &= [self executeShellCommand:command logOutput:logActivation];
  if (open) {
    NSURL *url = [NSURL URLWithString:open];
    if (url) {
      success &= [[NSWorkspace sharedWorkspace] openURL:url];
    } else {
      NSLog(@"[!] Stored open URL is not valid: %@", open);
      success = NO;
    }
  }

  return success;
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

- (BOOL)executeShellCommand:(NSString *)command logOutput:(BOOL)logOutput;
{
  NSTask *task = [NSTask new];
  task.launchPath = @"/bin/sh";
  task.arguments = @[@"-c", command];

  // With logOutput (click activation, no terminal) the output is captured
  // for the system log. Without it (-wait) the command inherits our
  // stdout/stderr, so its output lands on the controlling terminal.
  NSFileHandle *fileHandle = nil;
  if (logOutput) {
    NSPipe *pipe = [NSPipe pipe];
    fileHandle = [pipe fileHandleForReading];
    task.standardOutput = pipe;
    task.standardError = pipe;
  }
  [task launch];

  if (fileHandle) {
    NSData *data = nil;
    NSMutableData *accumulatedData = [NSMutableData data];
    while ((data = [fileHandle availableData]) && [data length]) {
      [accumulatedData appendData:data];
    }
    NSLog(@"command output:\n%@", [[NSString alloc] initWithData:accumulatedData encoding:NSUTF8StringEncoding]);
  }

  [task waitUntilExit];
  return [task terminationStatus] == 0;
}

@end
