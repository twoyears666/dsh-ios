//
//  DSHApp.m
//  最小外壳：起内核 + 用系统 Safari 进程显示网页。
//
//  为什么用 SFSafariViewController 而不是 WKWebView（关键！）：
//    iOS 16 rootless 上，手签越狱 App 的 WKWebView **无法启动 WebContent XPC**
//    （"Invalid connection identifier"），与 entitlements 无关。
//    我们之前连续 10 次内容进程被终止、自检都过不了，就是这个原因。
//    SFSafariViewController 把页面跑在**系统自己的 SafariViewService 进程**里，
//    同一个 Web UI 能可靠渲染。这是 yitenchen123/dsh-ios 真机验证过的方案。
//
//  为什么内核由 App 起：
//    这台设备上 launchd 注册成功但从不 spawn（active count 恒 0）；
//    而 App 能 exec bundle 内的 node（实测 rc=0）。
//
#import "DSHApp.h"

#import <SafariServices/SafariServices.h>
#import <stdarg.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <signal.h>
#import <string.h>

#import "DSHShell.h"
#import "DSHProc.h"
#import "DSHJIT.h"

static NSString *const kInstall  = @"/var/jb/usr/lib/dsh";
static NSString *const kDataRoot = @"/var/mobile/Media/deepseek-harness";
static NSString *const kPort     = @"3080";

// 固定 token —— 与 patch-ios.js 里 processLaunchToken 的缺省值逐字一致。
// 裸 "/" 会 401；URL 必须带这个 token 才能 303 换 cookie 进页面。
static NSString *const kWebToken = @"dshios-fixed-token-8f3a2c";

#pragma mark - 日志

static void DSHResetLog(void) {
    NSString *path = [kDataRoot stringByAppendingPathComponent:@"logs/minimal.log"];
    [[NSFileManager defaultManager] createDirectoryAtPath:
        [path stringByDeletingLastPathComponent]
                 withIntermediateDirectories:YES attributes:nil error:NULL];
    [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
}

static void DSHLog(NSString *fmt, ...) {
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        [[NSFileManager defaultManager] createDirectoryAtPath:
            [kDataRoot stringByAppendingPathComponent:@"logs"]
                                 withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[dsh] %@", msg);

    NSString *path = [kDataRoot stringByAppendingPathComponent:@"logs/minimal.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [data writeToFile:path atomically:NO]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:data]; } @catch (NSException *e) {}
    [fh closeFile];
}

#pragma mark - 探活（只认 2xx/3xx，401 不算就绪）

static NSInteger DSHProbeStatus(void) {
    NSString *urlStr = [NSString stringWithFormat:
                        @"http://127.0.0.1:%@/?token=%@", kPort, kWebToken];
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:urlStr]
           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
       timeoutInterval:3];
    req.HTTPMethod = @"GET";
    // 用同步请求，简单可靠。NSURLSession 在 App 进程里能用（之前 200 已验证）。
    NSHTTPURLResponse *resp = nil;
    [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:NULL];
    return resp ? (NSInteger)resp.statusCode : -1;
}

#pragma mark - Root VC：一个 status label + 起内核 + present Safari

@interface DSHRootVC : UIViewController <SFSafariViewControllerDelegate>
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) SFSafariViewController *safari;
@property (nonatomic, assign) NSInteger tries;
@property (nonatomic, assign) BOOL starting;
@end

@implementation DSHRootVC

- (void)viewDidLoad {
    [super viewDidLoad];
    DSHResetLog();
    self.view.backgroundColor = [UIColor colorWithRed:0.043 green:0.055 blue:0.078 alpha:1.0];

    UIDevice *dev = [UIDevice currentDevice];
    DSHLog(@"========== 本次启动 ==========");
    DSHLog(@"Safari 外壳 | iOS %@ / %@ | build %@",
           dev.systemVersion, dev.model,
           [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?");

    self.spinner = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.color = [UIColor whiteColor];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];

    self.status = [[UILabel alloc] init];
    self.status.text = @"正在启动…";
    self.status.textColor = [UIColor whiteColor];
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.numberOfLines = 0;
    self.status.font = [UIFont systemFontOfSize:15];
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.status];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor constant:-30],
        [self.status.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:16],
        [self.status.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:32],
        [self.status.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-32],
        [self.status.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    ]];
    [self.spinner startAnimating];

    // 回前台：内核还在就重新探测；版本变了就重开
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationWillEnterForegroundNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.safari) return;   // Safari 已经开着就不用管
            NSString *installed = [self installedVersion];
            NSString *running = [DSHProc recordedKernelVersion];
            if (installed.length > 0 && running.length > 0
                && ![running isEqualToString:installed]) {
                DSHLog(@"回前台发现版本不一致（跑 %@ / 装 %@），重开内核", running, installed);
                dispatch_async(dispatch_get_main_queue(), ^{ [self startKernel]; });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{ [self poll]; });
            }
        });
    }];

    [self startKernel];
}

#pragma mark 起内核

- (nullable NSString *)installedVersion {
    NSString *p = [kInstall stringByAppendingPathComponent:@"VERSION"];
    NSString *v = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
    v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return v.length > 0 ? v : nil;
}

- (void)startKernel {
    if (self.starting) { DSHLog(@"startKernel 重入，忽略"); return; }
    self.starting = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ self.starting = NO; });

    NSString *installed = [self installedVersion];
    pid_t running = [DSHProc kernelPid];
    BOOL alive = (running > 0) && (kill(running, 0) == 0);
    if (alive) {
        NSString *runningVer = [DSHProc recordedKernelVersion];
        if (installed.length > 0 && [runningVer isEqualToString:installed]) {
            DSHLog(@"复用已有内核 %@ pid=%d", runningVer, running);
            [self poll];
            return;
        }
        DSHLog(@"内核版本不符（跑 %@ / 装 %@），停掉重开", runningVer ?: @"?", installed ?: @"?");
    }

    DSHLog(@"清理旧内核并启动 %@", installed ?: @"(未知版本)");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [DSHProc killAllKernelsWait:3];
        usleep(600 * 1000);

        NSString *node = [self nodePath];
        if (node.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.status.text = @"找不到 node（DSH.app/runtime/node）";
            });
            return;
        }
        NSString *binJS = [kInstall stringByAppendingPathComponent:
                           @"node_modules/@deepseek-ai/dsh/lib/bin.js"];
        NSString *shim  = [kInstall stringByAppendingPathComponent:@"fetch-shim.cjs"];
        NSString *img   = [kInstall stringByAppendingPathComponent:@"ios-image-shim.mjs"];
        NSMutableArray *args = [NSMutableArray arrayWithArray:@[ @"--jitless", @"--require", shim ]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:img])
            [args addObjectsFromArray:@[ @"--import", img ]];
        [args addObjectsFromArray:@[ @"--expose-internals", binJS,
                                     @"web", @"--no-open", @"--port", kPort ]];

        NSString *logPath = [kDataRoot stringByAppendingPathComponent:@"logs/app-spawn.log"];
        pid_t pid = 0;
        int rc = [DSHShell spawnDetached:node args:args logPath:logPath
                                     env:[self kernelEnv] suspended:YES pid:&pid];
        DSHLog(@"spawn node rc=%d pid=%d", rc, pid);
        if (rc == 0 && pid > 0) {
            [DSHJIT enableForPid:pid];       // nowasm 档不需要 JIT，试一次记录用
            kill(pid, SIGCONT);
            [DSHProc rememberSpawnedPid:pid];
            [DSHProc writeKernelPid:pid version:[self installedVersion]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self poll]; });
    });
}

- (nullable NSString *)nodePath {
    NSString *inBundle = [[[NSBundle mainBundle] bundlePath]
                          stringByAppendingPathComponent:@"runtime/node"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:inBundle]) return inBundle;
    NSString *legacy = [kInstall stringByAppendingPathComponent:@"bin/node"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:legacy]) return legacy;
    return nil;
}

- (NSDictionary<NSString *, NSString *> *)kernelEnv {
    NSString *cache = [kDataRoot stringByAppendingPathComponent:@"cache"];
    return @{
        @"HOME": @"/var/mobile",
        @"PATH": @"/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        @"NODE_PATH": [kInstall stringByAppendingPathComponent:@"node_modules"],
        @"DSH_NODE": [self nodePath] ?: [kInstall stringByAppendingPathComponent:@"bin/node"],
        @"DSH_ROOT": kDataRoot,
        @"DSH_HOME": [kDataRoot stringByAppendingPathComponent:@"data"],
        @"DSH_CONFIG_DIR": [kDataRoot stringByAppendingPathComponent:@"config"],
        @"DSH_WORKSPACES_DIR": [kDataRoot stringByAppendingPathComponent:@"workspaces"],
        @"DSH_LOG_DIR": [kDataRoot stringByAppendingPathComponent:@"logs"],
        @"DSH_CACHE_DIR": cache,
        @"DSH_WEB_TOKEN": kWebToken,       // 固定 token —— 与服务端补丁一致
        @"PIDFILE": [kDataRoot stringByAppendingPathComponent:@"config/kernel.pid"],
        @"PNPM_HOME": [cache stringByAppendingPathComponent:@"pnpm"],
        @"XDG_DATA_HOME": [cache stringByAppendingPathComponent:@"pnpm-data"],
        @"XDG_CACHE_HOME": [cache stringByAppendingPathComponent:@"pnpm-cache"],
        @"npm_config_cache": [cache stringByAppendingPathComponent:@"npm-cache"],
        @"npm_config_store_dir": [cache stringByAppendingPathComponent:@"pnpm/store"],
        @"TMPDIR": [cache stringByAppendingPathComponent:@"tmp"],
        @"LANG": @"en_US.UTF-8",
    };
}

#pragma mark 等端口 → present Safari

- (void)poll {
    self.tries += 1;
    NSInteger code = DSHProbeStatus();
    DSHLog(@"探测 #%ld → HTTP %ld", (long)self.tries, (long)code);
    if (code >= 200 && code < 400) {
        // 优先用 Reynard（Gecko 内核，全屏无顶栏）—— 用户实测它能加载 dsh 页面。
        // 没装才退回 SFSafariViewController。
        if ([self openInReynard]) return;
        DSHLog(@"内核就绪，present SFSafariViewController");
        [self presentSafari];
        return;
    }
    if (self.tries > 100) {
        self.status.text = [NSString stringWithFormat:
            @"内核未就绪（HTTP %ld）。\n请检查 app-spawn.log", (long)code];
        return;
    }
    self.status.text = [NSString stringWithFormat:
        @"正在启动内核…（HTTP %ld，%ld 秒）", (long)code, (long)self.tries];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self poll]; });
}

/// 用 Reynard（Gecko 内核浏览器）打开页面。
/// 它注册了 reynard:// scheme 和 http/https，通过
/// reynard://open?url=<encoded> 可以把任意 URL 甩给它，
/// 在它自己的 Gecko 进程里全屏渲染 —— 绕开我们 App 起不了 WebContent 的问题。
/// 返回 YES 表示成功唤起。
- (BOOL)openInReynard {
    NSString *page = [NSString stringWithFormat:
        @"http://127.0.0.1:%@/?token=%@", kPort, kWebToken];
    NSURL *reynardURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"reynard://open?url=%@",
            [page stringByAddingPercentEncodingWithAllowedCharacters:
                [NSCharacterSet URLQueryAllowedCharacterSet]]]];

    UIApplication *app = [UIApplication sharedApplication];
    if (![app canOpenURL:reynardURL]) {
        DSHLog(@"Reynard 未安装（canOpenURL=NO），走 Safari 兜底");
        return NO;
    }
    DSHLog(@"唤起 Reynard: %@", reynardURL.absoluteString);
    if (@available(iOS 10.0, *)) {
        [app openURL:reynardURL options:@{} completionHandler:^(BOOL ok) {
            DSHLog(@"Reynard openURL 结果: %@", ok ? @"成功" : @"失败");
        }];
    } else {
        [app openURL:reynardURL];
    }
    return YES;
}

- (void)presentSafari {
    if (self.safari) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"http://127.0.0.1:%@/?token=%@", kPort, kWebToken]];
    DSHLog(@"present %@", url.absoluteString);

    SFSafariViewControllerConfiguration *cfg = [[SFSafariViewControllerConfiguration alloc] init];
    cfg.barCollapsingEnabled = YES;
    SFSafariViewController *safari = [[SFSafariViewController alloc]
        initWithURL:url configuration:cfg];
    safari.delegate = self;
    safari.preferredBarTintColor = [UIColor colorWithRed:0.043 green:0.055 blue:0.078 alpha:1.0];
    safari.preferredControlTintColor = [UIColor whiteColor];
    safari.dismissButtonStyle = SFSafariViewControllerDismissButtonStyleClose;
    safari.modalPresentationStyle = UIModalPresentationFullScreen;
    self.safari = safari;
    [self presentViewController:safari animated:YES completion:^{
        [self.spinner stopAnimating];
    }];
}

#pragma mark SFSafariViewControllerDelegate

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    DSHLog(@"Safari 被关闭");
    self.safari = nil;
    // 关掉后重新显示连接界面，可以再打开
    [self.spinner startAnimating];
    self.status.text = @"正在连接…";
    [self poll];
}

@end

#pragma mark - AppDelegate

@implementation DSHAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[DSHRootVC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
