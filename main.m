/*==========================================================================*\
) Copyright (c) 2022 by J.W https://github.com/jakwings/macos-notify         (
)                                                                            (
)   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION          (
)                                                                            (
)  0. You just DO WHAT THE FUCK YOU WANT TO.                                 (
\*==========================================================================*/


#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
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
        fprintf(stderr, "[notify] Error: failed to execute /bin/sh\n");
        break;
    default:
        fprintf(stderr, "[notify] Error: unknown exitcode: %d\n", exitcode);
    }
    exit(exitcode ? exitcode : -1);
}


#pragma mark - Swizzle NSBundle

static NSString *mainBundleIdentifier = @"jakwings.notify.macos";
static NSString *fakeBundleIdentifier = nil;

@implementation NSBundle (Hack)

+ (void)hack
{
    Class class = objc_getClass("NSBundle");
    method_exchangeImplementations(
        class_getInstanceMethod(class, @selector(bundleIdentifier)),
        class_getInstanceMethod(class, @selector(fakeBundleIdentifier))
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

@end


#pragma mark - Customize NotificationCenter

@interface MyDelegate : NSObject<NSApplicationDelegate, NSUserNotificationCenterDelegate>

@property (assign) BOOL finished;
@property (assign) BOOL activated;
@property (assign) double timeout;
@property (assign) NSString *command;
@property (assign) NSApplication *app;
@property (assign) NSTask *task;
@property (assign) NSUserNotification *notification;
@property (assign) NSUserNotificationCenter *center;
@property (assign) NSDistributedNotificationCenter *dc;

@end

@implementation MyDelegate

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center
        shouldPresentNotification:(NSUserNotification *)notification
{
    return YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center
        didDeliverNotification:(NSUserNotification *)notification
{
    self.finished = YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center
       didActivateNotification:(NSUserNotification *)notification
{
    if (self.activated) {
        [self.app terminate:nil];
        return;
    }
    self.activated = YES;

    [center removeScheduledNotification:notification];
    [center removeDeliveredNotification:notification];

    if (self.command) {
        self.finished = NO;

        NSTask *task = [[NSTask alloc] init];
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
                [self clean];
                exit(task.terminationStatus);
            }
        };
        if ([NSFileManager.defaultManager isExecutableFileAtPath:task.launchPath]) {
            [task launch];
        } else {
            [self clean];
            error_exit(ExitCode_ExecuteCommand);
        }
        self.task = task;
    }
    [self.app terminate:nil];
}

- (void)finish
{
    if (self.timeout > 0) {
        [self.center removeScheduledNotification:self.notification];
        [self.center removeDeliveredNotification:self.notification];
    }
    if (!(self.activated && self.command)) {
        self.finished = YES;
    }
    [self.app terminate:nil];
    //[self finish];  // keep notifying
}

- (void)relax
{
    self.timeout = 0;
}

- (void)clean
{
    [self.dc removeObserver:self name:nil object:nil];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    return self.finished ? NSTerminateNow : NSTerminateCancel;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self clean];
}

@end


#pragma mark -

NSApplication *app = nil;

static void cancel(int sig)
{
    MyDelegate *delegate = (id)app.delegate;
    [delegate.task terminate];
    [delegate clean];
    signal(sig, SIG_DFL);
    kill(0, sig);
    exit(0x80 + sig);
}

int main(void)
{
    // use case: notify -body Background -timeout 10 & disown; exit
    if (signal(SIGHUP, SIG_IGN) == SIG_ERR ||
            signal(SIGINT, cancel) == SIG_ERR ||
            signal(SIGQUIT, cancel) == SIG_ERR ||
            signal(SIGTERM, cancel) == SIG_ERR) {
        error_exit(ExitCode_Signal);
    }

    NSUserDefaults *options = [NSUserDefaults.standardUserDefaults initWithSuiteName:NSArgumentDomain];

    // avoid this hack if possible
    if ((fakeBundleIdentifier = [options stringForKey:@"bundle"])) {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;

        if (fakeBundleIdentifier.length <= 0 && bundleIdentifier.length > 0) {
            fakeBundleIdentifier = bundleIdentifier;
        }
        [NSBundle hack];
    }

    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.identifier = [options stringForKey:@"id"];
    notification.title = [options stringForKey:@"title"];
    notification.subtitle = [options stringForKey:@"subtitle"];
    notification.informativeText = [options stringForKey:@"body"];
    notification.soundName = [options stringForKey:@"sound"];
    notification.contentImage = [[NSImage alloc] initWithContentsOfFile:[options stringForKey:@"icon"]];
    notification.deliveryRepeatInterval = nil;

    if (!notification.informativeText) {
        error_exit(ExitCode_ParseArgument);
    }

    MyDelegate *delegate = [[MyDelegate alloc] init];
    delegate.finished = NO;
    delegate.activated = NO;
    delegate.notification = notification;
    delegate.timeout = [options doubleForKey:@"timeout"];
    delegate.command = [options stringForKey:@"command"];

    if (delegate.timeout <= 0 && delegate.command) {
        delegate.timeout = 180;
    }

    app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyProhibited;
    app.delegate = delegate;
    delegate.app = app;

    // use case: notify -id foo -timeout 5 -body foo & sleep 1
    //           notify -id foo -timeout 10 -body baz
    if (notification.identifier) {
        NSNotificationName name = NSBundle.mainBundle.bundleIdentifier;
        NSString *token = notification.identifier;
        delegate.dc = [NSDistributedNotificationCenter notificationCenterForType:NSLocalNotificationCenterType];
        [delegate.dc postNotificationName:name object:token userInfo:nil deliverImmediately:YES];
        [delegate.dc addObserver:delegate selector:@selector(relax) name:name object:token];
    }

    NSUserNotificationCenter *center = NSUserNotificationCenter.defaultUserNotificationCenter;
    center.delegate = delegate;
    delegate.center = center;

    [center deliverNotification:notification];
    [delegate performSelector:@selector(finish) withObject:nil afterDelay:fmax(delegate.timeout, 0.001)];

    [app run];

    return ExitCode_Success;
}
