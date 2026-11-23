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

// POSIX socket：用于内核存活探测（DSHProbeKernel）
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
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

/// 探测 dsh 内核是否在监听
static BOOL DSHProbeKernel(NSString *host, NSInteger port) {
    // 用 POSIX socket 做一次 connect，避免异步等待
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, host.UTF8String, &addr.sin_addr);

    BOOL ok = (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    close(fd);
    return ok;
}

#pragma mark - DSHRootVC

@interface DSHRootVC () <WKNavigationDelegate, WKUIDelegate, UITableViewDelegate, UITableViewDataSource,
                          DSHBridgeDelegate, DSHBrowserBridgeDelegate, UIDocumentPickerDelegate, DSHMenuDelegate>

@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) DSHBridge *bridge;
@property (nonatomic, strong) DSHMenu *menu;
@property (nonatomic, strong) DSHBrowserBridge *browserBridge;
@property (nonatomic, strong) UITableView *sidebar;
@property (nonatomic, strong) UIRefreshControl *refresh;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *reloadButton;
@property (nonatomic, strong) UISwitch *keepAliveSwitch;
@property (nonatomic, strong) UILabel *keepAliveLabel;
@property (nonatomic, strong) UIView *loadingOverlay;

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *sessions;
@property (nonatomic, assign) BOOL kernelReady;
@property (nonatomic, assign) NSInteger kernelProbeTries;

// 目录选择器回调
@property (nonatomic, copy, nullable) void (^pendingPickCompletion)(NSString *_Nullable);

// 内部方法前向声明：供 block / 后台队列调用
- (void)keepAliveSwitchChanged:(UISwitch *)sw;
- (void)ctl:(NSString *)subcommand message:(NSString *)message;
- (void)confirmStopKernel;
- (void)refreshMenu;
- (BOOL)keepAliveEnabled;
- (void)ensureKernelRunning;
- (void)probeKernelOnce;
- (void)handleProbeResult:(BOOL)up;
- (void)loadWithToken:(nullable NSString *)token;
- (nullable NSString *)scrapeTokenFromLog;
- (void)refreshSessions;
- (void)showLoadError:(NSError *)error;

@end

@implementation DSHRootVC

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    self.sessions = [NSMutableArray array];
    if (!self.baseURL) {
        self.baseURL = DSHEnvValue(@"DSH_WEB_URL") ?: kDSHDefaultBaseURL;
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

    for (UIView *v in @[self.spinner, self.statusLabel, self.reloadButton,
                        self.keepAliveSwitch, self.keepAliveLabel]) {
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
                                         menu:[self.menu buildMainMenuRunning:self.kernelReady
                                                                    keepAlive:[self keepAliveEnabled]]];

    // 左侧导航栏标题
    leftVC.navigationItem.title = @"会话";

    UISplitViewController *split = [[UISplitViewController alloc] init];
    split.viewControllers = @[
        [[UINavigationController alloc] initWithRootViewController:leftVC],
        [[UINavigationController alloc] initWithRootViewController:rightVC],
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
        if (DSHProbeKernel(host, port)) {
            return;  // 已经在跑
        }

        // 1) 优先 launchctl bootstrap（launchd 守护，最干净）
        // 2) 退到 kickstart（已注册但没跑）
        // 3) 最后直接后台起 dsh（launchd 不可用时）
        NSString *cmd =
            @"launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.twoyears.dsh.plist 2>/dev/null"
             " || launchctl kickstart system/com.twoyears.dsh 2>/dev/null"
             " || launchctl load -w /var/jb/Library/LaunchDaemons/com.twoyears.dsh.plist 2>/dev/null"
             " || (nohup /var/jb/usr/bin/dsh web --no-open --port 3080 >/dev/null 2>&1 &)";

        [DSHShell runAsync:@"/bin/sh"
                      args:@[@"-c", cmd]
                   timeout:20
                completion:^(NSString *output, int status) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            NSLog(@"[dsh] ensureKernelRunning status=%d output=%@", status, output);
            // launchd 启动有延迟，稍等再让探测循环接手
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self probeKernelOnce];
            });
        }];
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
        [self.spinner stopAnimating];
        self.statusLabel.text = @"dsh 内核未启动。\n请在终端运行：\n  dsh\n\n或检查 launchd：\n  launchctl list | grep twoyears";
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
}

/// 从 dsh 的日志里抓 token（内核启动时会打印带 token 的 URL）
- (NSString *)scrapeTokenFromLog {
    NSArray<NSString *> *candidates = @[
        @"/var/jb/var/mobile/.dsh/dsh-daemon.log",
        @"/var/jb/var/mobile/.dsh/dsh-daemon.err.log",
    ];
    for (NSString *path in candidates) {
        NSString *content = [NSString stringWithContentsOfFile:path
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (content.length == 0) continue;
        NSRange r = [content rangeOfString:@"token="];
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
    self.loadingOverlay.hidden = NO;
    [self.spinner stopAnimating];
    self.statusLabel.text = [NSString stringWithFormat:@"加载失败\n%@", error.localizedDescription];
    [self.reloadButton setHidden:NO];
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

        case DSHMenuActionAbout: {
            NSString *ver = [[NSBundle mainBundle]
                             objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"DeepSeek Harness"
                                 message:[NSString stringWithFormat:
                                          @"外壳版本 %@\n内核 0.2.2-rc.5\nNode 24.19.0 (iOS arm64)", ver]
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

/// 重建导航栏菜单，反映最新状态
- (void)refreshMenu {
    UINavigationController *nav = (UINavigationController *)self.children.firstObject;
    UIViewController *right = nil;
    if ([nav isKindOfClass:[UISplitViewController class]]) {
        UISplitViewController *split = (UISplitViewController *)nav;
        if (split.viewControllers.count > 1) {
            right = split.viewControllers[1];
        }
    }
    if (!right) {
        // 从 split 里找
        for (UIViewController *child in self.children) {
            if ([child isKindOfClass:[UISplitViewController class]]) {
                UISplitViewController *sp = (UISplitViewController *)child;
                if (sp.viewControllers.count > 1) right = sp.viewControllers[1];
                break;
            }
        }
    }
    UINavigationController *rightNav = [right isKindOfClass:[UINavigationController class]]
        ? (UINavigationController *)right : nil;
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
        NSLog(@"[dsh-ctl %@] status=%d %@", subcommand, status, output);
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
