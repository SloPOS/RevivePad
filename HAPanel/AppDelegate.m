#import "AppDelegate.h"
#import "PanelViewController.h"

NSString *const HAUserActivityNotification = @"HAUserActivity";

// Window that reports every touch, so the panel knows someone is using it
// (keeps the screen awake and drawers open while scrolling, sliding, etc.).
@interface HAWindow : UIWindow
@end

@implementation HAWindow
- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        for (UITouch *t in [event allTouches]) {
            if (t.phase == UITouchPhaseBegan) {
                [[NSNotificationCenter defaultCenter] postNotificationName:HAUserActivityNotification object:nil];
                break;
            }
        }
    }
    [super sendEvent:event];
}
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[HAWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[PanelViewController alloc] init];
    [self.window makeKeyAndVisible];
    application.idleTimerDisabled = YES;   // wall panel: never auto-lock while open
    // selected segment: dark text on the tint colour (the default is invisible against it on iOS 8)
    [[UISegmentedControl appearance] setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]} forState:UIControlStateSelected];
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    application.idleTimerDisabled = YES;
}

@end
