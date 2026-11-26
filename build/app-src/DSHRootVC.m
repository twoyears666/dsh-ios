//
//  DSHRootVC.m
//  dsh iOS 原生外壳 —— 还原 macOS 桌面端布局
//
//  桌面端结构（Electron main.js）：
//    BrowserWindow { titleBarStyle: "hidden", vibrancy: "sidebar" }
//      ├─ 左侧会话/工作区侧边栏
//      └─ 右侧 dsh-web-app 界面
//
//  本实现用 UISplitViewController 等价：
//    primary   = 原生会话列表（UIKit TableView，直连 dsh API）
//    secondary = WKWebView 加载同一份 dsh-web-app UI
//
#import "DSHRootVC.h"
#import "DSHBridge.h"
#import "DSHMenu.h"
#import "DSHShell.h"
#import "DSHBrowserBridge.h"
#import "DSHBrowserControl.h"

// POSIX socket：用于内核存活探测（DSHProbeKernel）
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <signal.h>    // kill()：探测 pidfile 里的内核进程是否还活着
#import <errno.h>     // EPERM
#import <stdarg.h>    // va_list（App 日志）
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - 常量

static NSString *const kDSHDefaultBaseURL = @"http://127.0.0.1:3080";
static NSString *const kDSHEnvPath = @"/var/jb/etc/dsh/dsh.env";
static NSString *const kDSHRuntimeDir = @"/var/jb/usr/lib/dsh";

#pragma mark - 工具

/// 从 dsh.env 读一个键（形如 `: "${KEY:=value}"` 或 `KEY=value`）
static NSString *DSHEnvValue(NSString *key) {
    NSString *content = [NSString stringWithContentsOfFile:kDSHEnvPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    if (content.length == 0) return nil;

    // 先找 := 形式
    NSString *needle = [NSString stringWithFormat:@"${%@:=", key];
    NSRange r = [content rangeOfString:needle];
    if (r.location != NSNotFound) {
        NSUInteger start = r.location + r.length;
        NSRange end = [content rangeOfString:@"}" options:0
                                       range:NSMakeRange(start, content.length - start)];
        if (end.location != NSNotFound) {
            return [content substringWithRange:NSMakeRange(start, end.location - start)];
        }
    }

    // 再找 KEY=value 形式
    needle = [NSString stringWithFormat:@"\n%@=", key];
    r = [content rangeOfString:needle];
    if (r.location != NSNotFound) {
        NSUInteger start = r.location + r.length;
        NSRange lineEnd = [content rangeOfString:@"\n" options:0
                                           range:NSMakeRange(start, content.length - start)];
        NSUInteger len = (lineEnd.location == NSNotFound ? content.length : lineEnd.location) - start;
        return [content substringWithRange:NSMakeRange(start, len)];
    }
    return nil;
}

/// 探测 dsh 内核是否**真正就绪**（不只是端口开着）。
///
/// 之前只做 TCP connect，端口一开就认为好了，但那时 HTTP 服务
/// 可能还没挂载完，加载页面会失败。
///
/// 现在发一个真正的 HTTP 请求：不带 token 访问 /，期望拿到
///   401  → 服务就绪（认证中间件在跑，这是正常的）
///   200  → 服务就绪
///   其它 → 未就绪
static BOOL DSHProbeKernel(NSString *host, NSInteger port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, host.UTF8String, &addr.sin_addr);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NO;
    }

    // 发一个最小 HTTP/1.1 请求
    const char *req = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    ssize_t sent = write(fd, req, strlen(req));
    if (sent <= 0) { close(fd); return NO; }

    // 读状态行：期望 "HTTP/1.x 200" 或 "HTTP/1.x 401" 或 "HTTP/1.x 303"
    char buf[256] = {0};
    ssize_t got = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (got <= 0) return NO;

    NSString *head = [[NSString alloc] initWithBytes:buf length:(NSUInteger)got
                                             encoding:NSUTF8StringEncoding];
    if (!head) return NO;
    // 只要有 HTTP/1. 状态行且不是 5xx，就认为服务在跑
    if (![head hasPrefix:@"HTTP/1."]) return NO;
    if ([head containsString:@" 5"]) return NO;   // 5xx 说明后端有问题
    return YES;
}

/// 内核是否「已经在启动中」（进程活着但端口还没起来）。
///
/// 为什么需要这个：内核在 iOS 上冷启动要 20-60 秒，这段时间端口是关的。
/// 光靠端口探测判断「没在跑」会导致重复拉起 ——
/// launchd 的 RunAtLoad 和 App 的 ensureKernelRunning 会各起一个，
/// 抢同一个端口，输的那个报 EADDRINUSE 退出，
/// 然后 launchd 因为 KeepAlive 又把它拉起来，来回抖。
///
/// launcher 一 spawn 出 node 就把 pid 写进 pidfile，所以
/// pidfile 里有活着的 pid 就说明「有人正在启动」，我们只等不抢。
static BOOL DSHKernelStarting(void) {
    NSString *path = @"/var/mobile/Media/deepseek-harness/config/kernel.pid";
    NSString *raw = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (raw.length == 0) return NO;
    pid_t pid = (pid_t)raw.intValue;
    if (pid <= 0) return NO;
    // kill(pid, 0) 只做存在性检查，不发信号
    if (kill(pid, 0) == 0) return YES;
    return errno == EPERM;   // 存在但没权限 → 也算活着
}

#pragma mark - App 日志

/// 把关键事件追加到 app.log，**不只是 NSLog**。
///
/// NSLog 在 iOS 上只进 syslog（Console.app / idevicesyslog 才看得到），
/// 用户手上没有终端，出问题时我们什么都看不到 ——
/// 之前「更新了但日志不刷新」排查了很久就是因为这个。
/// 现在 App 自己的决策过程也落盘，跟 web.log 放一起，
/// 谁都能直接翻。
static void DSHAppLog(NSString *fmt, ...) {
    static NSString *const path = @"/var/mobile/Media/deepseek-harness/logs/app.log";
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        [[NSFileManager defaultManager] createDirectoryAtPath:
            @"/var/mobile/Media/deepseek-harness/logs"
                                 withIntermediateDirectories:YES attributes:nil error:NULL];
    });

    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *line = [NSString stringWithFormat:@"%@ [app] %@\n", [df stringFromDate:[NSDate date]], msg];
    NSLog(@"[dsh] %@", msg);

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    // 超过 512 KB 就重写，只留新的一行 —— App 可能开着几天，
    // 日志无上限迟早把 /var/mobile 写满。
    if (!attrs || [attrs fileSize] > 512 * 1024) {
        [data writeToFile:path atomically:NO];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
    } @catch (NSException *e) {
        // 日志失败绝不能影响主流程
    }
    [fh closeFile];
}
#pragma mark - DSHRootVC

@interface DSHRootVC () <WKNavigationDelegate, WKUIDelegate, UITableViewDelegate, UITableViewDataSource,
                          DSHBridgeDelegate, DSHBrowserBridgeDelegate, DSHBrowserControlDelegate, UIDocumentPickerDelegate, DSHMenuDelegate>

@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) DSHBridge *bridge;
@property (nonatomic, strong) DSHMenu *menu;
@property (nonatomic, strong) DSHBrowserBridge *browserBridge;
@property (nonatomic, strong) DSHBrowserControl *browserControl;
@property (nonatomic, strong) UISplitViewController *splitVC;
@property (nonatomic, strong) UINavigationController *rightNav;
@property (nonatomic, strong) NSMutableDictionary<NSString *, WKWebView *> *agentTabs;
@property (nonatomic, strong) UITableView *sidebar;
@property (nonatomic, strong) UIRefreshControl *refresh;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *reloadButton;
@property (nonatomic, strong) UISwitch *keepAliveSwitch;
@property (nonatomic, strong) UILabel *keepAliveLabel;
@property (nonatomic, strong) UIButton *clearProcessButton;
@property (nonatomic, strong) UIView *loadingOverlay;

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *sessions;
@property (nonatomic, assign) BOOL kernelReady;
@property (nonatomic, assign) NSInteger kernelProbeTries;
@property (nonatomic, assign) NSInteger kernelStartAttempts;
@property (nonatomic, strong) NSTimer *loadProgressTimer;
@property (nonatomic, assign) NSInteger authRetryCount;

// 目录选择器回调
@property (nonatomic, copy, nullable) void (^pendingPickCompletion)(NSString *_Nullable);

// 内部方法前向声明：供 block / 后台队列调用
- (void)startBrowserControlIfNeeded;
- (nullable WKWebView *)agentTab:(nullable NSString *)tabId;
- (WKWebView *)createAgentTabWithURL:(NSURL *)url tabId:(NSString *)tabId;
- (void)keepAliveSwitchChanged:(UISwitch *)sw;
- (void)ctl:(NSString *)subcommand message:(NSString *)message;
- (void)confirmStopKernel;
- (void)confirmClearProcess;
- (void)refreshMenu;
- (BOOL)keepAliveEnabled;
- (void)ensureKernelRunning;
- (void)probeKernelOnce;
- (void)handleProbeResult:(BOOL)up;
- (void)loadWithToken:(nullable NSString *)token;
- (nullable NSString *)scrapeTokenFromLog;
- (void)refreshSessions;
- (void)showLoadError:(NSError *)error;
- (void)startLoadProgressTimer;
- (void)clearAuthCookies;

@end

@implementation DSHRootVC

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    // 启动横幅：把「这次跑的到底是哪个版本」写进日志。
    // 升级后如果还是旧版本在服务，从这一行就能看出来。
    DSHAppLog(@"=== App 启动 外壳 %@ 内核 %@ ===",
              [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
              [self installedKernelVersion] ?: @"(未知)");

    self.sessions = [NSMutableArray array];
    if (!self.baseURL) {
        // DSH_WEB_URL 可能带 ?token=xxx，必须剥掉 query，
        // 否则后面再拼 ?token= 会变成 .../?token=abc/?token=xyz（无效 URL）。
        NSString *raw = DSHEnvValue(@"DSH_WEB_URL") ?: kDSHDefaultBaseURL;
        NSURLComponents *c = [NSURLComponents componentsWithString:raw];
        if (c) {
            c.query = nil;
            c.fragment = nil;
            NSString *clean = c.string;
            self.baseURL = clean.length > 0 ? clean : kDSHDefaultBaseURL;
        } else {
            self.baseURL = kDSHDefaultBaseURL;
        }
    }
    // 去掉可能的尾部斜杠，保证后面拼 /?token= 时不会出现 //
    while ([self.baseURL hasSuffix:@"/"]) {
        self.baseURL = [self.baseURL substringToIndex:self.baseURL.length - 1];
    }

    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 菜单（还原 Electron 菜单栏）
    self.menu = [[DSHMenu alloc] init];
    self.menu.delegate = self;

    [self buildLayout];
    [self observeBridgeReplies];
    [self startKernelWatch];
}

/// DSHBridge 通过通知把 JS 回注请求转过来（避免 bridge 直接持有 webView）
- (void)observeBridgeReplies {
    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter]
     addObserverForName:@"DSHBridgeEvaluateJS"
                 object:nil
                  queue:[NSOperationQueue mainQueue]
             usingBlock:^(NSNotification *note) {
        NSString *js = note.userInfo[@"js"];
        if (js.length == 0) return;
        [weakSelf.webView evaluateJavaScript:js completionHandler:nil];
    }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startBrowserControlIfNeeded];
    [self loadWorkbench];
}

#pragma mark - 布局

- (void)buildLayout {
    // ---- 左：会话侧边栏 ----
    self.sidebar = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.sidebar.delegate = self;
    self.sidebar.dataSource = self;
    self.sidebar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [self.sidebar registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];

    self.refresh = [[UIRefreshControl alloc] init];
    [self.refresh addTarget:self action:@selector(refreshSessions) forControlEvents:UIControlEventValueChanged];
    self.sidebar.refreshControl = self.refresh;

    // ---- 右：WKWebView ----
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    // 允许本地 http（ATS 已在 Info.plist 放行）
    cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];

    // 注入 Electron 外壳的 7 个 API 等价实现
    self.bridge = [[DSHBridge alloc] init];
    self.bridge.delegate = self;
    [self.bridge attachToConfiguration:cfg];

    // 侧边栏浏览器：dshDesktop.browser 协议（<webview> → 原生 WKWebView）
    self.browserBridge = [[DSHBrowserBridge alloc] init];
    self.browserBridge.delegate = self;

    // agent ↔ App 的浏览器控制端点（127.0.0.1:3081）
    self.agentTabs = [NSMutableDictionary dictionary];
    self.browserControl = [[DSHBrowserControl alloc] init];
    self.browserControl.delegate = self;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    [self.browserBridge attachToWebView:self.webView];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.opaque = NO;
    self.webView.backgroundColor = [UIColor systemBackgroundColor];

    // ---- 加载遮罩 ----
    self.loadingOverlay = [[UIView alloc] init];
    self.loadingOverlay.backgroundColor = [UIColor systemBackgroundColor];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    [self.spinner startAnimating];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"正在启动 dsh 内核…";
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];

    self.reloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.reloadButton setTitle:@"重试" forState:UIControlStateNormal];
    [self.reloadButton addTarget:self action:@selector(loadWorkbench) forControlEvents:UIControlEventTouchUpInside];
    self.reloadButton.hidden = YES;

    // 保活开关：放在错误/加载界面，用户点得到
    self.keepAliveSwitch = [[UISwitch alloc] init];
    self.keepAliveSwitch.on = [self keepAliveEnabled];
    [self.keepAliveSwitch addTarget:self
                             action:@selector(keepAliveSwitchChanged:)
                   forControlEvents:UIControlEventValueChanged];

    self.keepAliveLabel = [[UILabel alloc] init];
    self.keepAliveLabel.text = @"后台保活";
    self.keepAliveLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.keepAliveLabel.textColor = [UIColor secondaryLabelColor];

    // 清除进程：紧跟在保活开关下面。
    // 用途：更新版本后旧内核还占着端口，或者内核卡死点不动了。
    // 行为：关掉保活 + 杀干净内核进程（clear 子命令），之后不会自动拉起。
    self.clearProcessButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.clearProcessButton setTitle:@"清除进程" forState:UIControlStateNormal];
    self.clearProcessButton.titleLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    [self.clearProcessButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [self.clearProcessButton addTarget:self
                                action:@selector(confirmClearProcess)
                      forControlEvents:UIControlEventTouchUpInside];

    for (UIView *v in @[self.spinner, self.statusLabel, self.reloadButton,
                        self.keepAliveSwitch, self.keepAliveLabel,
                        self.clearProcessButton]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.loadingOverlay addSubview:v];
    }
    UILayoutGuide *safe = self.loadingOverlay.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor constant:-40],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:20],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:32],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-32],

        [self.reloadButton.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:20],
        [self.reloadButton.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.reloadButton.widthAnchor constraintEqualToConstant:120],
        [self.reloadButton.heightAnchor constraintEqualToConstant:44],

        [self.keepAliveSwitch.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor constant:34],
        [self.keepAliveSwitch.topAnchor constraintEqualToAnchor:self.reloadButton.bottomAnchor constant:24],

        [self.keepAliveLabel.trailingAnchor constraintEqualToAnchor:self.keepAliveSwitch.leadingAnchor constant:-10],
        [self.keepAliveLabel.centerYAnchor constraintEqualToAnchor:self.keepAliveSwitch.centerYAnchor],

        [self.clearProcessButton.topAnchor constraintEqualToAnchor:self.keepAliveSwitch.bottomAnchor constant:12],
        [self.clearProcessButton.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.clearProcessButton.heightAnchor constraintEqualToConstant:36],
    ]];

    // ---- UISplitViewController（iPad / iPhone 自适应）----
    // 注意：不要用 leftVC.view = xxx 直接赋值 —— 那样 viewDidLoad 不会触发，
    // 且 UIKit 会警告 "loadView called ... but did not set a view"。
    // 正确做法是给一个真正的容器 VC 覆写 loadView，或把子视图 addSubview。
    UIViewController *leftVC = [[UIViewController alloc] init];
    leftVC.view = [[UIView alloc] init];
    leftVC.view.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    [leftVC.view addSubview:self.sidebar];
    [NSLayoutConstraint activateConstraints:@[
        [self.sidebar.topAnchor constraintEqualToAnchor:leftVC.view.topAnchor],
        [self.sidebar.bottomAnchor constraintEqualToAnchor:leftVC.view.bottomAnchor],
        [self.sidebar.leadingAnchor constraintEqualToAnchor:leftVC.view.leadingAnchor],
        [self.sidebar.trailingAnchor constraintEqualToAnchor:leftVC.view.trailingAnchor],
    ]];
    leftVC.title = @"会话";

    UIViewController *rightVC = [[UIViewController alloc] init];
    rightVC.view = [[UIView alloc] init];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [rightVC.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:rightVC.view.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:rightVC.view.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:rightVC.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:rightVC.view.trailingAnchor],
    ]];
    rightVC.title = @"DeepSeek Harness";

    // 导航栏右侧的"更多"菜单按钮（还原 Electron 菜单栏）
    rightVC.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                         menu:[self.menu buildMainMenuRunning:NO
                                                                    keepAlive:[self keepAliveEnabled]]];

    // 左侧导航栏标题
    leftVC.navigationItem.title = @"会话";

    UISplitViewController *split = [[UISplitViewController alloc] init];
    UINavigationController *rightNav = [[UINavigationController alloc] initWithRootViewController:rightVC];
    self.splitVC = split;
    self.rightNav = rightNav;
    split.viewControllers = @[
        [[UINavigationController alloc] initWithRootViewController:leftVC],
        rightNav,
    ];
    split.preferredDisplayMode = UISplitViewControllerDisplayModeAllVisible;
    split.preferredPrimaryColumnWidthFraction = 0.28;
    split.minimumPrimaryColumnWidth = 240;
    split.maximumPrimaryColumnWidth = 380;

    [self addChildViewController:split];
    split.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:split.view];
    [NSLayoutConstraint activateConstraints:@[
        [split.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [split.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [split.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [split.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    [split didMoveToParentViewController:self];

    // 加载遮罩覆盖全屏
    self.loadingOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.loadingOverlay];
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingOverlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.loadingOverlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.loadingOverlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.loadingOverlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

#pragma mark - 内核探测

- (void)startKernelWatch {
    self.kernelProbeTries = 0;
    // 先主动拉起内核（launchd 守护），再开始探测。
    // 不能只等 —— 用户点开 App 就是要用，不该让他自己去终端敲 dsh。
    [self ensureKernelRunning];
    [self probeKernelOnce];
}

/// 确保 dsh 内核在跑：先探测，没跑就通过 launchctl 拉起。
- (void)ensureKernelRunning {
    NSURLComponents *c = [NSURLComponents componentsWithString:self.baseURL];
    NSString *host = c.host ?: @"127.0.0.1";
    NSInteger port = c.port.integerValue ?: 3080;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (DSHProbeKernel(host, port)) return;   // 已在跑

        // 端口还没起来，但可能已经有人（launchd）在启动了。
        // 这时候再 spawn 一个就是两个内核抢一个端口，必须只等不抢。
        if (DSHKernelStarting()) {
            DSHAppLog(@"内核已在启动中（pidfile 有活进程），等待其就绪");
            return;
        }

        // 直接脱离启动，不依赖 launchctl。
        //
        // 为什么不用 launchctl：
        //   - App 沙箱里 launchctl 常被拒（即使有 no-sandbox entitlement）
        //   - bootstrap/kickstart 都需要和 launchd 通信，权限模型复杂
        //
        // 用 posix_spawn + SETSID：新会话，脱离 App 进程组，
        // App 挂起/退后台不会带走内核。
        // 用独立文件，避免和 dsh 自己写的 web.log 冲突
        // （dsh 会先清空 web.log，App 的 fd 偏移会错位）
        NSString *logPath = @"/var/mobile/Media/deepseek-harness/logs/app-spawn.log";
        pid_t pid = 0;
        // 关键：必须显式传环境变量。
        // iOS App 的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
        // 不含 /var/jb/usr/bin。dsh 脚本里的 mkdir/tail/nc 会全部 ENOENT，
        // 导致日志写不出来、内核起不来。
        NSDictionary *env = @{
            @"PATH": @"/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            @"HOME": @"/var/mobile",
            @"DSH_ROOT": @"/var/mobile/Media/deepseek-harness",
            @"DSH_HOME": @"/var/mobile/Media/deepseek-harness/data",
            @"DSH_LOG_DIR": @"/var/mobile/Media/deepseek-harness/logs",
            @"TMPDIR": @"/var/mobile/Media/deepseek-harness/cache/tmp",
            @"LANG": @"en_US.UTF-8",
        };
        int rc = [DSHShell spawnDetached:@"/var/jb/usr/bin/dsh"
                                    args:@[@"web", @"--no-open",
                                           @"--port", [NSString stringWithFormat:@"%ld", (long)port]]
                                 logPath:logPath
                                     env:env
                                     pid:&pid];

        DSHAppLog(@"spawnDetached rc=%d pid=%d log=%@", rc, pid, logPath);

        // 无论成败都交给探测循环接手（可能 launchd 那边已经在跑）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self) [self probeKernelOnce];
        });
    });
}

/// 单次探测。用方法递归代替 block 自引用 —— 原来把 block 存进局部变量
/// 再让内层 block 捕获，方法返回后 block 已释放，dispatch_after 收到 NULL，
/// libdispatch 直接 SIGTRAP（"NULL was passed where a block should have been"）。
- (void)probeKernelOnce {
    NSURLComponents *c = [NSURLComponents componentsWithString:self.baseURL];
    NSString *host = c.host ?: @"127.0.0.1";
    NSInteger port = c.port.integerValue ?: 3080;

    __weak typeof(self) weakSelf = self;
    // DSHProbeKernel 是同步 socket connect（最长阻塞 1 秒），必须离开主线程
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL up = DSHProbeKernel(host, port);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleProbeResult:up];
        });
    });
}

- (void)handleProbeResult:(BOOL)up {
    if (up) {
        self.kernelReady = YES;
        self.statusLabel.text = @"内核已就绪，正在加载工作台…";
        [self loadWorkbench];
        return;
    }

    self.kernelProbeTries += 1;
    if (self.kernelProbeTries > 26) {
        // 第一轮 39 秒失败后，再尝试启动一次内核（spawn 可能失败过）
        if (self.kernelStartAttempts < 2) {
            self.kernelStartAttempts += 1;
            self.kernelProbeTries = 0;
            self.statusLabel.text = [NSString stringWithFormat:
                @"内核未响应，重新启动（第 %ld 次）…", (long)self.kernelStartAttempts];
            DSHAppLog(@"探测超时，重新 spawn（第 %ld 次）", (long)self.kernelStartAttempts);
            [self ensureKernelRunning];
            return;
        }

        [self.spinner stopAnimating];
        // 提示必须假设「用户手上没有终端」——
        // 能点的是菜单里的按钮，不是命令行。
        self.statusLabel.text =
            @"dsh 内核未启动。\n\n"
             "可以先试：右上角菜单 → 内核 → 清除进程，然后点重试。\n\n"
             "日志（用「文件」App 可直接打开）：\n"
             "  /var/mobile/Media/deepseek-harness/logs/\n"
             "    app.log        外壳自己的启动记录\n"
             "    web.log        内核输出（带访问 URL）\n"
             "    app-spawn.log  内核由 App 拉起时的输出\n"
             "    ctl.log        dsh-ctl 操作记录";
        self.reloadButton.hidden = NO;
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf probeKernelOnce];
    });
}


#pragma mark - 加载工作台

- (void)loadWorkbench {
    [self.reloadButton setHidden:YES];
    [self.spinner startAnimating];
    self.statusLabel.text = @"正在加载…";

    // token 优先级：显式属性 > dsh.env > 内核日志
    // 读日志可能涉及较大文件，放后台队列，避免阻塞主线程。
    NSString *explicitToken = self.authToken ?: DSHEnvValue(@"DSH_WEB_TOKEN");
    if (explicitToken.length > 0) {
        [self loadWithToken:explicitToken];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *scraped = [weakSelf scrapeTokenFromLog];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf loadWithToken:scraped];
        });
    });
}

- (void)loadWithToken:(NSString *)token {
    NSString *urlString;
    if (token.length > 0) {
        // 带 token 访问 → 内核 303 下发 cookie → 后续走 cookie
        urlString = [NSString stringWithFormat:@"%@/?token=%@", self.baseURL, token];
    } else {
        urlString = [NSString stringWithFormat:@"%@/", self.baseURL];
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        self.statusLabel.text = [NSString stringWithFormat:@"地址无效：%@", urlString];
        self.reloadButton.hidden = NO;
        [self.spinner stopAnimating];
        return;
    }

    NSURLRequest *req = [NSURLRequest requestWithURL:url
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:20];
    [self.webView loadRequest:req];

    // 加载进度提示：每 5 秒更新一次，避免看起来卡死
    [self startLoadProgressTimer];
}

/// 从 dsh 的日志里抓 token（内核启动时会打印带 token 的 URL）
- (NSString *)scrapeTokenFromLog {
    // 数据目录已迁到 Media（/var/mobile/Media/deepseek-harness），
    // 旧路径保留作为兼容回退。
    NSArray<NSString *> *candidates = @[
        // dsh 入口写这里（含 token）
        @"/var/mobile/Media/deepseek-harness/logs/web.log",
        // App 直接 spawn 时的输出
        @"/var/mobile/Media/deepseek-harness/logs/app-spawn.log",
        // launchd 守护
        @"/var/mobile/Media/deepseek-harness/logs/dsh-daemon.log",
        @"/var/mobile/Media/deepseek-harness/logs/dsh-daemon.err.log",
        // 旧路径兼容
        @"/var/jb/var/mobile/.dsh/dsh-daemon.log",
        @"/var/jb/var/mobile/.dsh/dsh-daemon.err.log",
    ];
    for (NSString *path in candidates) {
        NSString *content = [NSString stringWithContentsOfFile:path
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (content.length == 0) continue;
        // 日志可能记录多次启动，取最后一个 token（最新）
        NSRange r = [content rangeOfString:@"token=" options:NSBackwardsSearch];
        if (r.location == NSNotFound) continue;
        NSUInteger start = r.location + r.length;
        NSUInteger i = start;
        while (i < content.length) {
            unichar ch = [content characterAtIndex:i];
            BOOL ok = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')
                   || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_';
            if (!ok) break;
            i++;
        }
        if (i > start) {
            return [content substringWithRange:NSMakeRange(start, i - start)];
        }
    }
    return nil;
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.authRetryCount = 0;   // 成功则重置
    [self.loadProgressTimer invalidate];
    [self.spinner stopAnimating];
    self.loadingOverlay.hidden = YES;
    [self refreshSessions];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self showLoadError:error];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self showLoadError:error];
}

- (void)showLoadError:(NSError *)error {
    // 401 说明 token 失效或 cookie 不对：重新从日志抓 token 重试。
    // 这很常见 —— 内核重启后 token 会变，旧 URL 就失效了。
    BOOL isAuthFailure = (error.code == 401)
        || [error.localizedDescription containsString:@"401"]
        || [error.localizedDescription containsString:@"authentication"];

    if (isAuthFailure && self.authRetryCount < 2) {
        self.authRetryCount += 1;
        DSHAppLog(@"认证失败，重新抓 token 重试（第 %ld 次）", (long)self.authRetryCount);
        self.statusLabel.text = @"重新获取认证…";
        [self.spinner startAnimating];
        // 清掉 cookie，强制用新 token 重新握手
        [self clearAuthCookies];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self loadWorkbench];
        });
        return;
    }

    self.loadingOverlay.hidden = NO;
    [self.spinner stopAnimating];
    self.statusLabel.text = [NSString stringWithFormat:@"加载失败\n%@", error.localizedDescription];
    [self.reloadButton setHidden:NO];
}

/// 加载进度提示（web UI 在 iOS 上首屏可能要 10-30 秒）
- (void)startLoadProgressTimer {
    [self.loadProgressTimer invalidate];
    __block NSInteger secs = 0;
    __weak typeof(self) weakSelf = self;
    self.loadProgressTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                            repeats:YES
                                                              block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { [t invalidate]; return; }
        secs += 5;
        if (self.loadingOverlay.hidden) { [t invalidate]; return; }
        self.statusLabel.text = [NSString stringWithFormat:
            @"正在加载工作台… %ld 秒\n\n首次加载较慢（iOS 上 10-30 秒）", (long)secs];
    }];
}

/// 清掉 dsh 的认证 cookie，让下一次请求重新走 token 换 cookie
- (void)clearAuthCookies {
    WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        for (NSHTTPCookie *c in cookies) {
            if ([c.name hasPrefix:@"dsh-auth"]) {
                [store deleteCookie:c completionHandler:nil];
            }
        }
    }];
}

#pragma mark - 会话列表

- (void)refreshSessions {
    // dsh 的会话数据在 $DSH_HOME/sessions 下，这里先做目录级展示；
    // 完整会话元数据走 /api，等内核就绪后再接。
    [self.refresh endRefreshing];

    NSString *sessionsDir = @"/var/jb/var/mobile/.dsh/sessions";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:sessionsDir error:NULL];

    [self.sessions removeAllObjects];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        NSString *full = [sessionsDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
        [self.sessions addObject:@{
            @"name": name,
            @"path": full,
            @"date": attrs[NSFileModificationDate] ?: [NSDate date],
        }];
    }
    [self.sessions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];
    }];
    [self.sidebar reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX((NSInteger)self.sessions.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sessions.count ? @"最近会话" : @"暂无会话";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    if (self.sessions.count == 0) {
        cell.textLabel.text = @"打开工作台开始对话";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSDictionary *s = self.sessions[indexPath.row];
        cell.textLabel.text = s[@"name"];
        cell.textLabel.textColor = [UIColor labelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.sessions.count == 0) return;
    // 会话切换交给 web UI 自己处理（它有自己的路由）
    [self loadWorkbench];
}

#pragma mark - DSHBridgeDelegate

/// 网页请求打开外部链接（对应 Electron 的 shell.openExternal）
- (void)bridgeOpenURL:(NSString *)url {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return;
    // 只允许 http/https/mailto，避免任意 scheme
    NSString *scheme = u.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]
        && ![scheme isEqualToString:@"mailto"]) {
        NSLog(@"[dsh] 拒绝打开非白名单 scheme: %@", scheme);
        return;
    }
    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
}

/// 网页请求关闭窗口（对应 Electron 的 window.close）
- (void)bridgeClose {
    // iOS 没有"关窗口"语义。Electron 版关的是 BrowserWindow；
    // 这里退化为：让用户回到主屏（不做任何破坏性操作）。
    // 不用 suspend（私有 API，审核和签名都会拒）。
    NSLog(@"[dsh] bridgeClose: iOS 无窗口概念，忽略");
}

/// 目录选择器（对应 Electron 的 dialog.showOpenDialog）
- (void)bridgePickDirectory:(void (^)(NSString *_Nullable))completion {
    self.pendingPickCompletion = completion;

    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc]
                  initForOpeningContentTypes:@[UTTypeFolder]
                                       asCopy:NO];
    } else {
        picker = [[UIDocumentPickerViewController alloc]
                  initWithDocumentTypes:@[@"public.folder"]
                                 inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;

    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *picked = urls.firstObject;
    NSString *path = picked.path;

    // 安全作用域资源：iOS 沙箱外目录需要显式开启访问
    if (picked && [picked startAccessingSecurityScopedResource]) {
        // 生成一个书签，供后续会话复用
        NSError *err = nil;
        NSData *bookmark = [picked bookmarkDataWithOptions:0
                           includingResourceValuesForKeys:nil
                                            relativeToURL:nil
                                                    error:&err];
        if (bookmark) {
            NSString *home = @"/var/jb/var/mobile/.dsh";
            [[NSFileManager defaultManager] createDirectoryAtPath:home
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
            NSString *bmPath = [home stringByAppendingPathComponent:@"dir-bookmarks.plist"];
            NSMutableDictionary *map = [NSMutableDictionary dictionary];
            NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:bmPath];
            if (existing) [map addEntriesFromDictionary:existing];
            map[path] = bookmark;
            [map writeToFile:bmPath atomically:YES];
        }
        [picked stopAccessingSecurityScopedResource];
    }

    void (^cb)(NSString *) = self.pendingPickCompletion;
    self.pendingPickCompletion = nil;
    if (cb) cb(path);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    void (^cb)(NSString *) = self.pendingPickCompletion;
    self.pendingPickCompletion = nil;
    if (cb) cb(nil);
}

#pragma mark - DSHBrowserBridgeDelegate

/// 侧边栏浏览器里 target=_blank / window.open：开成新标签
- (void)browserBridgeOpenRequested:(NSString *)url lease:(NSString *)lease {
    if (url.length == 0) return;
    // 交给 web UI 自己开新标签（它监听 openTab）
    NSString *js = [NSString stringWithFormat:
        @"window.__dshBrowserOpenRequested && window.__dshBrowserOpenRequested(%@, %@);",
        [self jsLiteral:lease], [self jsLiteral:url]];
    [self.webView evaluateJavaScript:js completionHandler:nil];
}

- (NSString *)jsLiteral:(NSString *)s {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s ?: @""] options:0 error:NULL];
    if (!d) return @"\"\"";
    NSString *arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
}


#pragma mark - DSHBrowserControlDelegate（agent 操作浏览器）

/// 启动控制端点（在 viewDidAppear 里调，只启动一次）
- (void)startBrowserControlIfNeeded {
  static BOOL started = NO;
  if (started) return;
  started = YES;
  // 只在 agent 权限开启时才监听，避免无谓暴露端口
  // 默认关闭：只有 enabled 标记存在才启动端点
  BOOL enabled = [[NSFileManager defaultManager]
      fileExistsAtPath:@"/var/mobile/Media/deepseek-harness/config/browser-agent.enabled"];
  if (!enabled) {
    NSLog(@"[dsh-browser-ctl] agent 浏览器权限已关闭，不启动端点");
    return;
  }
  [self.browserControl startOnPort:3081];
}

/// 取指定 tab 的 WKWebView；tabId 为空则用第一个 agent tab
- (nullable WKWebView *)agentTab:(nullable NSString *)tabId {
  if (tabId.length > 0) return self.agentTabs[tabId];
  return self.agentTabs.allValues.firstObject;
}

/// 新建一个 agent 标签（叠在主 WebView 之上，用户可见）
- (WKWebView *)createAgentTabWithURL:(NSURL *)url tabId:(NSString *)tabId {
  WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
  cfg.allowsInlineMediaPlayback = YES;
  cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];

  WKWebView *wv = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
  wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  wv.backgroundColor = [UIColor systemBackgroundColor];

  // 盖在主界面之上；用户能看见 agent 在做什么
  [self.view addSubview:wv];
  self.agentTabs[tabId] = wv;

  [wv loadRequest:[NSURLRequest requestWithURL:url]];
  return wv;
}

- (NSDictionary *)controlOpenURL:(NSString *)url {
  NSURL *u = [NSURL URLWithString:url];
  if (!u || ![u.scheme.lowercaseString hasPrefix:@"http"]) {
    return @{ @"error": @"只支持 http/https" };
  }
  NSString *tabId = [[NSUUID UUID].UUIDString lowercaseString];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self createAgentTabWithURL:u tabId:tabId];
  });
  // 等一小会儿让导航起步，再回标题（拿不到就返回 URL）
  return @{ @"tabId": tabId, @"url": url, @"title": @"" };
}

- (NSDictionary *)controlSnapshotTab:(NSString *)tabId maxChars:(NSInteger)maxChars {
  WKWebView *wv = [self agentTab:tabId];
  if (!wv) return @{ @"error": @"没有打开的标签页" };

  // 提取可见文本 + 可交互元素选择器
  NSString *js =
    @"(function(){"
     "var t=document.body?document.body.innerText:'';"
     "var els=[];"
     "document.querySelectorAll('a,button,input,textarea,select,[role=button]').forEach(function(e,i){"
       "if(i>200)return;"
       "var sel=e.tagName.toLowerCase();"
       "if(e.id)sel+='#'+e.id;"
       "else if(e.className&&typeof e.className==='string'){"
         "var c=e.className.trim().split(/\\s+/)[0];if(c)sel+='.'+c;}"
       "els.push({selector:sel,tag:e.tagName.toLowerCase(),"
         "text:(e.innerText||e.value||'').slice(0,80),type:e.type||''});"
     "});"
     "return JSON.stringify({url:location.href,title:document.title,text:t,interactive:els});"
    "})();";

  __block NSDictionary *out = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    [wv evaluateJavaScript:js completionHandler:^(id result, NSError *err) {
      if ([result isKindOfClass:[NSString class]]) {
        NSData *d = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([j isKindOfClass:[NSDictionary class]]) {
          NSMutableDictionary *m = [j mutableCopy];
          NSString *text = m[@"text"] ?: @"";
          if (text.length > (NSUInteger)maxChars) {
            m[@"text"] = [text substringToIndex:(NSUInteger)maxChars];
            m[@"truncated"] = @YES;
          } else {
            m[@"truncated"] = @NO;
          }
          out = m;
        }
      }
      dispatch_semaphore_signal(sem);
    }];
  });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
  return out ?: @{ @"error": @"快照超时或失败" };
}

- (NSDictionary *)controlClickSelector:(NSString *)selector tab:(NSString *)tabId {
  WKWebView *wv = [self agentTab:tabId];
  if (!wv) return @{ @"error": @"没有打开的标签页" };

  NSString *js = [NSString stringWithFormat:
    @"(function(){var e=document.querySelector(%@);"
     "if(!e)return JSON.stringify({clicked:false});"
     "e.scrollIntoView({block:'center'});e.click();"
     "return JSON.stringify({clicked:true,url:location.href,title:document.title});})();",
    [self jsLiteral:selector]];

  __block NSDictionary *out = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    [wv evaluateJavaScript:js completionHandler:^(id result, NSError *err) {
      if ([result isKindOfClass:[NSString class]]) {
        NSData *d = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([j isKindOfClass:[NSDictionary class]]) out = j;
      }
      dispatch_semaphore_signal(sem);
    }];
  });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
  return out ?: @{ @"clicked": @NO };
}

- (NSDictionary *)controlTypeSelector:(NSString *)selector
                                 text:(NSString *)text
                               submit:(BOOL)submit
                                  tab:(NSString *)tabId {
  WKWebView *wv = [self agentTab:tabId];
  if (!wv) return @{ @"error": @"没有打开的标签页" };

  NSString *js = [NSString stringWithFormat:
    @"(function(){var e=document.querySelector(%@);"
     "if(!e)return JSON.stringify({typed:false});"
     "e.focus();e.value=%@;"
     "e.dispatchEvent(new Event('input',{bubbles:true}));"
     "e.dispatchEvent(new Event('change',{bubbles:true}));"
     "%@"
     "return JSON.stringify({typed:true,url:location.href});})();",
    [self jsLiteral:selector],
    [self jsLiteral:text],
    submit ? @"if(e.form){if(e.form.requestSubmit)e.form.requestSubmit();else e.form.submit();}"
           : @"if(e.form&&e.form.querySelector('[type=submit]')){var b=e.form.querySelector('[type=submit]');b.click();}" ];

  __block NSDictionary *out = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    [wv evaluateJavaScript:js completionHandler:^(id result, NSError *err) {
      if ([result isKindOfClass:[NSString class]]) {
        NSData *d = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([j isKindOfClass:[NSDictionary class]]) out = j;
      }
      dispatch_semaphore_signal(sem);
    }];
  });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
  return out ?: @{ @"typed": @NO };
}

- (NSDictionary *)controlScreenshotTab:(NSString *)tabId {
  WKWebView *wv = [self agentTab:tabId];
  if (!wv) return @{ @"error": @"没有打开的标签页" };

  __block NSDictionary *out = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    WKSnapshotConfiguration *cfg = [[WKSnapshotConfiguration alloc] init];
    [wv takeSnapshotWithConfiguration:cfg completionHandler:^(UIImage *img, NSError *err) {
      if (img) {
        NSData *png = UIImagePNGRepresentation(img);
        out = @{
          @"mediaType": @"image/png",
          @"data": [png base64EncodedStringWithOptions:0],
          @"width": @((NSInteger)img.size.width),
          @"height": @((NSInteger)img.size.height),
        };
      }
      dispatch_semaphore_signal(sem);
    }];
  });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
  return out ?: @{ @"error": @"截图失败" };
}

- (NSDictionary *)controlEvalExpression:(NSString *)expression tab:(NSString *)tabId {
  WKWebView *wv = [self agentTab:tabId];
  if (!wv) return @{ @"error": @"没有打开的标签页" };

  NSString *js = [NSString stringWithFormat:
    @"(function(){try{var v=(%@);return JSON.stringify({ok:true,result:v});}"
     "catch(e){return JSON.stringify({ok:false,error:String(e)});}})();",
    expression];

  __block NSDictionary *out = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    [wv evaluateJavaScript:js completionHandler:^(id result, NSError *err) {
      if ([result isKindOfClass:[NSString class]]) {
        NSData *d = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([j isKindOfClass:[NSDictionary class]]) out = j;
      } else if (err) {
        out = @{ @"ok": @NO, @"error": err.localizedDescription ?: @"" };
      }
      dispatch_semaphore_signal(sem);
    }];
  });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
  return out ?: @{ @"ok": @NO, @"error": @"执行超时" };
}

#pragma mark - DSHMenuDelegate

- (void)menuDidSelect:(DSHMenuAction)action {
    switch (action) {
        case DSHMenuActionNewSession:
            // 交给 web UI 的新建会话路由
            [self.webView evaluateJavaScript:
             @"(function(){var b=document.querySelector('[data-testid=\"new-session\"],button[aria-label*=\"New\"],button[aria-label*=\"新\"]');if(b)b.click();})();"
                                 completionHandler:nil];
            break;

        case DSHMenuActionReload:
            [self loadWorkbench];
            break;

        case DSHMenuActionOpenInSafari: {
            NSString *url = [self currentURLString];
            if (url.length) {
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]
                                                   options:@{}
                                         completionHandler:nil];
            }
            break;
        }

        case DSHMenuActionCopyURL: {
            NSString *url = [self currentURLString];
            if (url.length) {
                [UIPasteboard generalPasteboard].string = url;
                [self toast:@"URL 已复制"];
            }
            break;
        }

        case DSHMenuActionShowSessions:
            [self refreshSessions];
            break;

        case DSHMenuActionSettings: {
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"设置"
                                 message:[NSString stringWithFormat:
                                          @"内核：%@\n端口：3080\nDSH_HOME：/var/jb/var/mobile/.dsh",
                                          self.baseURL]
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            break;
        }

        case DSHMenuActionDoctor:
            [self runDoctor];
            break;

        case DSHMenuActionRestartKernel:
            [self restartKernel];
            break;

        case DSHMenuActionStartKernel:
            [self ctl:@"start" message:@"正在启动内核…"];
            break;

        case DSHMenuActionStopKernel:
            [self confirmStopKernel];
            break;

        case DSHMenuActionToggleKeepAlive: {
            BOOL on = [self keepAliveEnabled];
            [self ctl:(on ? @"disable" : @"enable")
              message:(on ? @"正在关闭保活…" : @"正在开启保活…")];
            break;
        }

        case DSHMenuActionClearProcess:
            [self confirmClearProcess];
            break;

        case DSHMenuActionAbout: {
            NSString *ver = [[NSBundle mainBundle]
                             objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
            // 内核版本从安装戳里读，不写死 —— 写死的话升级后
            // 「关于」页显示的还是老版本，反而误导排查。
            NSString *kernelVer = [self installedKernelVersion] ?: @"?";
            NSString *nodeVer = [self nodeVersionString] ?: @"?";
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"DeepSeek Harness"
                                 message:[NSString stringWithFormat:
                                          @"外壳版本 %@\n内核 %@\nNode %@ (iOS arm64)",
                                          ver, kernelVer, nodeVer]
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            break;
        }
    }
}

#pragma mark - 辅助

/// 保活是否开启（读 dsh-ctl 写的标记文件）
- (BOOL)keepAliveEnabled {
    return ![[NSFileManager defaultManager]
             fileExistsAtPath:@"/var/mobile/Media/deepseek-harness/config/keepalive.disabled"];
}

/// 已安装的内核版本。
/// 优先读 postinst 写的 installed.version（不受内核是否在跑影响），
/// 退回读 VERSION（deb 自带）。都没有就返回 nil。
- (nullable NSString *)installedKernelVersion {
    NSArray<NSString *> *candidates = @[
        @"/var/mobile/Media/deepseek-harness/config/installed.version",
        @"/var/jb/usr/lib/dsh/VERSION",
    ];
    for (NSString *path in candidates) {
        NSString *s = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
        s = [s stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length > 0) return s;
    }
    return nil;
}

/// Node 版本。直接问 node 自己，避免和实际运行时漂移。
- (nullable NSString *)nodeVersionString {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *out = [DSHShell run:@"/var/jb/usr/lib/dsh/bin/node"
                                  args:@[@"--version"]
                               timeout:5];
        out = [out stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // node --version 输出带 v 前缀，去掉更自然
        if ([out hasPrefix:@"v"]) out = [out substringFromIndex:1];
        if (out.length > 0) cached = [out copy];
    });
    return cached;
}

/// 重建导航栏菜单，反映最新状态
- (void)refreshMenu {
    // 直接用手上持有的右栏 nav，不去遍历 childViewControllers
    UINavigationController *rightNav = self.rightNav;
    if (!rightNav) return;
    rightNav.topViewController.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                         menu:[self.menu buildMainMenuRunning:self.kernelReady
                                                                    keepAlive:[self keepAliveEnabled]]];
}

- (nullable NSString *)currentURLString {
    return self.webView.URL.absoluteString;
}

- (void)toast:(NSString *)text {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                              message:text
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [a dismissViewControllerAnimated:YES completion:nil]; });
}

/// 运行 dsh-doctor 并把结果展示出来
- (void)runDoctor {
    [DSHShell runAsync:@"/var/jb/usr/bin/dsh-doctor"
                  args:nil
               timeout:30
            completion:^(NSString *output, int status) {
        NSString *text = output.length ? output : @"(无输出)";
        if (text.length > 2000) text = [text substringToIndex:2000];
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"dsh-doctor"
                             message:text
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }];
}

/// 保活开关变化
- (void)keepAliveSwitchChanged:(UISwitch *)sw {
    [self ctl:(sw.on ? @"enable" : @"disable")
      message:(sw.on ? @"正在开启保活…" : @"正在关闭保活…")];
}

/// 调用 dsh-ctl 子命令，完成后刷新状态
- (void)ctl:(NSString *)subcommand message:(NSString *)message {
    [self toast:message];
    __weak typeof(self) weakSelf = self;
    [DSHShell runAsync:@"/var/jb/usr/bin/dsh-ctl"
                  args:@[subcommand]
               timeout:30
            completion:^(NSString *output, int status) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        DSHAppLog(@"dsh-ctl %@ → status=%d %@", subcommand, status,
                  [output stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        [self toast:output.length > 0 ? output : [NSString stringWithFormat:@"dsh-ctl %@ 完成", subcommand]];
        // 状态可能变了，等内核起稳再刷新
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf refreshMenu];
            weakSelf.keepAliveSwitch.on = [weakSelf keepAliveEnabled];
            [weakSelf probeKernelOnce];
        });
    }];
}

/// 停止内核前确认（避免误触把正在跑的任务中断）
- (void)confirmStopKernel {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"停止内核"
                         message:@"正在运行的任务会被中断。同时会关闭后台保活。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"停止" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *_) {
        [self ctl:@"stop" message:@"正在停止内核…"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 需要 popover 锚点
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:a animated:YES completion:nil];
}

/// 清除进程前确认
- (void)confirmClearProcess {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"清除进程"
                         message:@"会关闭后台保活，并强制杀掉所有内核进程。\n"
                                 @"正在运行的任务会被中断，之后不会自动拉起。\n"
                                 @"适用场景：更新版本后旧内核还占着端口。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *_) {
        [self ctl:@"clear" message:@"正在清除内核进程…"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad popover 必须有锚点。按钮在覆盖层里时才用它，
    // 从菜单进来（按钮不可见）就退回到导航栏按钮。
    if (self.clearProcessButton.window) {
        a.popoverPresentationController.sourceView = self.clearProcessButton;
        a.popoverPresentationController.sourceRect = self.clearProcessButton.bounds;
    } else {
        a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    [self presentViewController:a animated:YES completion:nil];
}

/// 重启 dsh 内核（launchctl kickstart）
- (void)restartKernel {
    [DSHShell runAsync:@"/bin/sh"
                  args:@[@"-c",
        @"launchctl kickstart -k system/com.twoyears.dsh 2>&1 || "
        @"(launchctl unload /var/jb/Library/LaunchDaemons/com.twoyears.dsh.plist; "
        @"launchctl load /var/jb/Library/LaunchDaemons/com.twoyears.dsh.plist)"]
               timeout:15
            completion:^(NSString *output, int status) {
        [self toast:status == 0 ? @"内核已重启" : [NSString stringWithFormat:@"重启返回 %d", status]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self loadWorkbench]; });
    }];
}

@end
