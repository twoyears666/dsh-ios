//
//  DSHApp.m
//  最小外壳：一个 WKWebView，只负责把网页显示出来。
//
//  设计原则（按用户要求「啥额外功能都不要」）：
//    · 不注入任何 JS bridge（7 个 preload API 全去掉）
//    · 没有菜单、没有语音、没有进程列表、没有浏览器控制
//    · 不做档位探测 —— 这台设备只有 nowasm 能跑（3 秒就出链接）
//    · 只保留「起内核」这一件必须由原生做的事，然后 loadRequest
//
//  为什么内核必须由 App 起：launchd 在这台设备上注册成功但从不 spawn
//  （active count 恒 0、supervise.log 从未生成）；而 App 能 exec
//  bundle 里的 node（实测 rc=0）。
//
#import "DSHApp.h"

#import <WebKit/WebKit.h>
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

static NSString *const kJB       = @"/var/jb";
static NSString *const kInstall  = @"/var/jb/usr/lib/dsh";
static NSString *const kDataRoot = @"/var/mobile/Media/deepseek-harness";
static NSString *const kPort     = @"3080";

#pragma mark - 探活

/// 端口能不能连上并且返回 HTTP 状态行。
/// 只做 TCP + 最小 HTTP 请求，不依赖任何外部工具。
static BOOL DSHProbe(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(3080);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NO;
    }
    const char *req = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    if (write(fd, req, strlen(req)) <= 0) { close(fd); return NO; }

    char buf[128] = {0};
    ssize_t got = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (got <= 0) return NO;
    NSString *head = [[NSString alloc] initWithBytes:buf length:(size_t)got
                                             encoding:NSUTF8StringEncoding];
    if (head.length == 0 || ![head hasPrefix:@"HTTP/1."]) return NO;
    if ([head containsString:@" 5"]) return NO;   // 5xx 说明后端有问题
    return YES;
}

#pragma mark - 日志

static void DSHLog(NSString *fmt, ...) {
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        [[NSFileManager defaultManager] createDirectoryAtPath:
            [kDataRoot stringByAppendingPathComponent:@"logs"]
                                 withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[dsh] %@", msg);

    NSString *path = [kDataRoot stringByAppendingPathComponent:@"logs/minimal.log"];
    NSString *line = [NSString stringWithFormat:@"%@ [min] %@\n",
                      [df stringFromDate:[NSDate date]], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [data writeToFile:path atomically:NO]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:data]; } @catch (NSException *e) {}
    [fh closeFile];
}

#pragma mark - 视图

@interface DSHWebVC : UIViewController <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, assign) NSInteger tries;
@end

@implementation DSHWebVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaNone;
    cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];

    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    self.web.navigationDelegate = self;
    self.web.opaque = NO;
    self.web.backgroundColor = [UIColor systemBackgroundColor];
    self.web.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.web];

    self.hint = [[UILabel alloc] init];
    self.hint.text = @"正在启动内核…";
    self.hint.textAlignment = NSTextAlignmentCenter;
    self.hint.numberOfLines = 0;
    self.hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.hint.textColor = [UIColor secondaryLabelColor];
    self.hint.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.hint];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.web.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.hint.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.hint.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [self.hint.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [self.hint.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],
    ]];

    [self startKernel];
}

#pragma mark 起内核

- (void)startKernel {
    DSHLog(@"启动：先清理旧实例");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int killed = [DSHProc killAllKernelsWait:3];
        DSHLog(@"清理 %d 个旧实例", killed);
        usleep(600 * 1000);

        NSString *node = [self nodePath];
        if (node.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.hint.text = @"找不到 node（DSH.app/runtime/node）";
            });
            return;
        }

        NSString *binJS = [kInstall stringByAppendingPathComponent:
                           @"node_modules/@deepseek-ai/dsh/lib/bin.js"];
        NSString *shim  = [kInstall stringByAppendingPathComponent:@"fetch-shim.cjs"];
        NSString *img   = [kInstall stringByAppendingPathComponent:@"ios-image-shim.mjs"];

        // 只保留 nowasm 一档：这台设备 native/single 都起不来，
        // 而 nowasm 3 秒就能出链接，没必要探测。
        NSMutableArray *args = [NSMutableArray arrayWithArray:
                                @[ @"--jitless", @"--require", shim ]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:img]) {
            [args addObjectsFromArray:@[ @"--import", img ]];
        }
        [args addObjectsFromArray:@[ @"--expose-internals", binJS,
                                     @"web", @"--no-open", @"--port", kPort ]];

        NSString *logPath = [kDataRoot stringByAppendingPathComponent:@"logs/app-spawn.log"];
        pid_t pid = 0;
        int rc = [DSHShell spawnDetached:node args:args logPath:logPath
                                     env:[self kernelEnv] suspended:YES pid:&pid];
        DSHLog(@"spawn rc=%d pid=%d", rc, pid);

        if (rc == 0 && pid > 0) {
            BOOL jit = [DSHJIT enableForPid:pid];
            DSHLog(@"请求 JIT → %@", jit ? @"成功" : @"失败");
            kill(pid, SIGCONT);
            [DSHProc rememberSpawnedPid:pid];
            NSString *pf = [kDataRoot stringByAppendingPathComponent:@"config/kernel.pid"];
            [[NSFileManager defaultManager] createDirectoryAtPath:
                [kDataRoot stringByAppendingPathComponent:@"config"]
                                     withIntermediateDirectories:YES attributes:nil error:NULL];
            [[NSString stringWithFormat:@"%d\n", pid] writeToFile:pf atomically:NO
                                                        encoding:NSUTF8StringEncoding error:NULL];
        }

        dispatch_async(dispatch_get_main_queue(), ^{ [self poll]; });
    });
}

- (nullable NSString *)nodePath {
    NSString *inBundle = [[[NSBundle mainBundle] bundlePath]
                          stringByAppendingPathComponent:@"runtime/node"];
    if (access(inBundle.fileSystemRepresentation, X_OK) == 0) return inBundle;
    NSString *legacy = [kInstall stringByAppendingPathComponent:@"bin/node"];
    if (access(legacy.fileSystemRepresentation, X_OK) == 0) return legacy;
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

#pragma mark 等端口

- (void)poll {
    self.tries += 1;
    if (DSHProbe()) {
        DSHLog(@"内核就绪（第 %ld 次探测），加载网页", (long)self.tries);
        self.hint.hidden = YES;
        [self load];
        return;
    }
    if (self.tries > 120) {          // ~3 分钟
        DSHLog(@"探测超时，仍然加载（让用户看到真实报错）");
        self.hint.hidden = YES;
        [self load];
        return;
    }
    self.hint.text = [NSString stringWithFormat:
        @"正在启动内核…（已等 %ld 秒）", (long)(self.tries * 1.5)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self poll]; });
}

- (void)load {
    NSURL *url = [NSURL URLWithString:
                  [NSString stringWithFormat:@"http://127.0.0.1:%@/", kPort]];
    DSHLog(@"loadRequest %@", url);
    [self.web loadRequest:[NSURLRequest requestWithURL:url
                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                       timeoutInterval:30]];
}

#pragma mark WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    DSHLog(@"页面加载完成：%@", webView.URL.absoluteString);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    DSHLog(@"页面加载失败：%@", error.localizedDescription);
    self.hint.hidden = NO;
    self.hint.text = [NSString stringWithFormat:@"加载失败：%@", error.localizedDescription];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)resp
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))handler {
    if (resp.isForMainFrame && [resp.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger code = ((NSHTTPURLResponse *)resp.response).statusCode;
        DSHLog(@"主文档 HTTP %ld", (long)code);
        if (code >= 400) {
            // 把状态码直接显示出来 —— 401/404 的区别决定下一步查什么
            self.hint.hidden = NO;
            self.hint.text = [NSString stringWithFormat:@"服务端返回 HTTP %ld", (long)code];
        }
    }
    handler(WKNavigationResponsePolicyAllow);
}

@end

#pragma mark - AppDelegate

@implementation DSHAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[DSHWebVC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
