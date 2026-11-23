//
//  DSHAppDelegate.m
//
#import "DSHAppDelegate.h"
#import "DSHRootVC.h"

@implementation DSHAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    DSHRootVC *root = [[DSHRootVC alloc] init];
    root.title = @"DeepSeek Harness";

    // 深/浅色跟随系统
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;

    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // 后台保活：dsh 内核由 launchd 守护，App 退后台不影响任务继续跑
}

#pragma mark - URL Scheme

// iOS 9+ / 13+ 场景：通过 dsh:// 或 twodsh:// 唤起
- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    return [self handleURL:url];
}

// 旧 API（iOS 14 以下仍会走这条）
- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication
         annotation:(id)annotation {
    return [self handleURL:url];
}

- (BOOL)handleURL:(NSURL *)url {
    if (!url) return NO;
    DSHRootVC *root = (DSHRootVC *)self.window.rootViewController;
    if (![root isKindOfClass:[DSHRootVC class]]) return NO;

    // dsh://open?token=xxx  → 可带 token 直接进工作台
    // dsh://               → 只唤起
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *token = nil;
    for (NSURLQueryItem *item in c.queryItems) {
        if ([item.name isEqualToString:@"token"]) { token = item.value; break; }
    }
    if (token.length > 0) {
        root.authToken = token;
    }
    [root loadWorkbench];
    return YES;
}

@end
