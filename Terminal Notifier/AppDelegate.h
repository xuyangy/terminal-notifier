#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

// Shared CLI output, implemented in main.m (the single copy of the banner).
void PrintHelpBanner(void);
void PrintVersion(void);

@interface AppDelegate : NSObject <NSApplicationDelegate, UNUserNotificationCenterDelegate>
@end
