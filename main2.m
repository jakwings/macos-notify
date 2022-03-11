/*==========================================================================*\
) Copyright (c) 2022 by J.W https://github.com/jakwings/macos-notify         (
)                                                                            (
)   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION          (
)                                                                            (
)  0. You just DO WHAT THE FUCK YOU WANT TO.                                 (
\*==========================================================================*/


#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

#import <errno.h>
#import <signal.h>
#import <string.h>


static void help(BOOL to_stderr)
{
    const char *info =
"Usage:\n"
"    notify -body <text> [options]\n"
"\n"
"Options:\n"
"    -title <text>       Set title of notification.\n"
"    -subtitle <text>    Set subtitle of notification.\n"
"    -body <text>        Set message of notification.\n"
"    -icon <file>        Set icon of notification.\n"
"    -sound <name>       Play system sound for notification.\n"
"                        See files in \"/System/Library/Sounds\".\n"
"\n"
"    -id <text>\n"
"        Set id of notification.\n"
"        Previous notification of the same id will be updated.\n"
"    -timeout <seconds>\n"
"        Set duration of notification.\n"
"        The default timeout is none (0).\n"
"    -command <command>\n"
"        Run a shell script when the notification is clicked.\n"
"        Timeout will be set to 180 when timeout is 0.\n"
"    -bundle <id>\n"
"        Pretend to be another application.\n"
"        Use the application's icon as badge icon of notification.\n"
    ;

    if (to_stderr) {
        fprintf(stderr, "%s", info);
    } else {
        fprintf(stdout, "%s", info);
    }
}

enum ExitCode {
    ExitCode_Success,
    ExitCode_Signal,
    ExitCode_ParseArgument,
    ExitCode_ExecuteCommand,
    ExitCode_SendNotification,
    ExitCode_RequestAuthorization,
};

static void error_exit(enum ExitCode exitcode)
{
    switch (exitcode) {
    case ExitCode_Signal:
        fprintf(stderr, "[notify] Error: failed to handle signal: %s\n", strerror(errno));
        break;
    case ExitCode_ParseArgument:
        help(true);
        break;
    case ExitCode_ExecuteCommand:
        fprintf(stderr, "[notify] Error: unable to execute /bin/sh\n");
        break;
    case ExitCode_SendNotification:
        fprintf(stderr, "[notify] Error: failed to send notification\n");
        break;
    case ExitCode_RequestAuthorization:
        fprintf(stderr, "[notify] Error: notification requst denied\n");
        break;
    default:
        fprintf(stderr, "[notify] Error: unknown exitcode: %d\n", exitcode);
    }
    exit(exitcode ? exitcode : -1);
}

static void MyPrintError(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *string = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    fprintf(stderr, "[notify] Error: %s\n", [string UTF8String]);
}


#pragma mark - Swizzle NSBundle

static NSString *mainBundleIdentifier = @"jakwings.notify.macos";
static NSString *fakeBundleIdentifier = nil;

@implementation NSBundle (Hack)

+ (void)fakeBundleIdentifier
{
    method_exchangeImplementations(
        class_getInstanceMethod(self, @selector(bundleIdentifier)),
        class_getInstanceMethod(self, @selector(fakeBundleIdentifier))
    );
}

- (NSString *)fakeBundleIdentifier
{
    if (self == NSBundle.mainBundle) {
        return fakeBundleIdentifier ? fakeBundleIdentifier : mainBundleIdentifier;
    } else {
        return self.fakeBundleIdentifier;
    }
}

+ (void)fakeBundleURL
{
    method_exchangeImplementations(
        class_getInstanceMethod(self, @selector(bundleURL)),
        class_getInstanceMethod(self, @selector(fakeBundleURL))
    );
}

- (NSURL *)fakeBundleURL
{
    return [NSURL fileURLWithPath:@"/System/Applications/Utilities/Terminal.app" isDirectory:YES];
}

@end


#pragma mark - Customize NotificationCenter

@interface MyDelegate : NSObject<NSApplicationDelegate, UNUserNotificationCenterDelegate>

@property (assign) BOOL finished;
@property (assign) BOOL activated;
@property (assign) double timeout;
@property (assign) NSString *command;
@property (assign) NSString *identifier;
@property (assign) NSApplication *app;
@property (assign) UNUserNotificationCenter *center;

@end

@implementation MyDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
    completionHandler(
        UNNotificationPresentationOptionBadge |
        UNNotificationPresentationOptionSound |
        UNNotificationPresentationOptionList
    );
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler
{
    if (self.activated) {
        [self.app terminate:nil];
        return;
    }
    self.activated = YES;

    [center removePendingNotificationRequestsWithIdentifiers:@[self.identifier]];
    [center removeDeliveredNotificationsWithIdentifiers:@[self.identifier]];

    if (self.command) {
        self.finished = NO;

        NSTask *task = [NSTask new];
        task.launchPath = @"/bin/sh";
        task.arguments = @[@"-c", self.command];
        task.standardInput = NSFileHandle.fileHandleWithStandardInput;
        task.standardOutput = NSFileHandle.fileHandleWithStandardOutput;
        task.standardError = NSFileHandle.fileHandleWithStandardError;
        task.terminationHandler = ^void (NSTask *task) {
            if (task.terminationStatus == 0) {
                self.finished = YES;
                [self.app terminate:nil];
            } else {
                exit(task.terminationStatus);
            }
        };
        if ([NSFileManager.defaultManager isExecutableFileAtPath:task.launchPath]) {
            [task launch];
        } else {
            error_exit(ExitCode_ExecuteCommand);
        }
    }
    completionHandler();
    [self.app terminate:nil];
}

- (void)finish
{
    if (self.timeout > 0) {
        // XXX: -id foo -timeout 5 && -id foo -timeout 10
        [self.center removePendingNotificationRequestsWithIdentifiers:@[self.identifier]];
        [self.center removeDeliveredNotificationsWithIdentifiers:@[self.identifier]];
    }
    if (!(self.activated && self.command)) {
        self.finished = YES;
    }
    [self.app terminate:nil];
    //[self finish];  // keep notifying
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    return self.finished ? NSTerminateNow : NSTerminateCancel;
}

@end


#pragma mark -

int main(void)
{
    // use case: notify -body Background -timeout 10 & disown; exit
    if (signal(SIGHUP, SIG_IGN) == SIG_ERR) {
        error_exit(ExitCode_Signal);
    }

    NSUserDefaults *options = [NSUserDefaults.standardUserDefaults initWithSuiteName:NSArgumentDomain];

    // avoid this hack if possible
    if ((fakeBundleIdentifier = [options stringForKey:@"bundle"])) {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;

        if (fakeBundleIdentifier.length <= 0 && bundleIdentifier.length > 0) {
            fakeBundleIdentifier = bundleIdentifier;
        }
        [NSBundle fakeBundleIdentifier];
    }

    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.threadIdentifier = [options stringForKey:@"id"];
    content.title = [options stringForKey:@"title"];
    content.subtitle = [options stringForKey:@"subtitle"];
    content.body = [options stringForKey:@"body"];
    content.badge = @([options doubleForKey:@"badge"]);
    content.sound = ![options stringForKey:@"sound"] ? nil :
           [UNNotificationSound soundNamed:[options stringForKey:@"sound"]];
    content.attachments = ![options stringForKey:@"icon"] ? nil : @[
        [UNNotificationAttachment
            attachmentWithIdentifier:@""
                                 URL:[NSURL fileURLWithPath:[options stringForKey:@"icon"] isDirectory:NO]
                             options:nil
                               error:nil
        ]
    ];

    if (!content.body) {
        error_exit(ExitCode_ParseArgument);
    }
    if (!content.threadIdentifier) {
        content.threadIdentifier = [[NSUUID UUID] UUIDString];
    }

    UNNotificationRequest *request = [UNNotificationRequest
        requestWithIdentifier:content.threadIdentifier
                      content:content
                      trigger:nil
    ];

    MyDelegate *delegate = [MyDelegate new];
    delegate.finished = NO;
    delegate.activated = NO;
    delegate.identifier = request.identifier;
    delegate.timeout = [options doubleForKey:@"timeout"];
    delegate.command = [options stringForKey:@"command"];

    if (delegate.timeout <= 0 && delegate.command) {
        delegate.timeout = 180;
    }

    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyProhibited;
    app.delegate = delegate;
    delegate.app = app;

    [NSBundle fakeBundleURL];  // unavoidable?
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    center.delegate = delegate;
    delegate.center = center;

    [center getNotificationSettingsWithCompletionHandler:^void (UNNotificationSettings *settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusDenied) {
            delegate.finished = YES;
            return;
        }
fprintf(stderr, "badge: %d\n", UNNotificationSettingEnabled == settings.badgeSetting);
fprintf(stderr, "sound: %d\n", UNNotificationSettingEnabled == settings.soundSetting);
fprintf(stderr, "alert: %d\n", UNNotificationSettingEnabled == settings.alertSetting);
fprintf(stderr, "style: %ld\n", settings.alertStyle);
        [center requestAuthorizationWithOptions:(
                    UNAuthorizationOptionBadge |
                    UNAuthorizationOptionSound |
                    UNAuthorizationOptionAlert |
                    UNAuthorizationOptionProvisional |
                    UNAuthorizationOptionNone
                )
                completionHandler:^void (BOOL granted, NSError *error) {
                    // FIXME
                    if (error) {
                        MyPrintError(@"%@", error.localizedDescription);
                        exit(ExitCode_SendNotification);
                    }
                    if (!granted) {
                        error_exit(ExitCode_RequestAuthorization);
                    }
                    [center addNotificationRequest:request withCompletionHandler:^ (NSError *error) {
                        if (error) {
                            MyPrintError(@"%@", error.localizedDescription);
                            exit(ExitCode_SendNotification);
                        }
                        delegate.finished = YES;
                    }];
                }
        ];
    }];
    [delegate performSelector:@selector(finish)
                   withObject:nil
                   afterDelay:fmax(delegate.timeout, 0.001)
    ];
    [app run];

    return ExitCode_Success;
}
