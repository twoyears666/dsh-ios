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
#import "DSHPicker.h"
#import "DSHProxy.h"

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

@interface DSHWebVC : UIViewController <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, assign) NSInteger tries;
@property (nonatomic, strong) DSHPicker *picker;
/// 主文档是否已经加载完成（用于 15 秒看门狗）
@property (nonatomic, assign) BOOL finished;
/// 当前是否走 dsh:// 代理（YES）还是直接 http（NO）
@property (nonatomic, assign) BOOL useProxy;
@property (nonatomic, strong) DSHProxy *proxy;
@property (nonatomic, assign) NSInteger nativeStatus;
@end

@implementation DSHWebVC

- (void)viewDidLoad {
    [super viewDidLoad];

    // 记下系统版本 —— 判断前端兼容性全靠它
    UIDevice *dev = [UIDevice currentDevice];
    DSHLog(@"启动：iOS %@ / %@ / 外壳 %@",
           dev.systemVersion, dev.model,
           [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?");
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];

    // 抓页面里的 JS 报错。
    //
    // 现象是「Safari 打不开、换个浏览器能打开」—— 服务端没问题，
    // 说明 WebKit 上页面脚本炸了。但 WKWebView 默认拿不到 console，
    // 所以注入一段钩子：window.onerror / unhandledrejection /
    // console.error 全部转发到原生，写进 minimal.log。
    // 这是诊断代码，不提供任何给网页用的能力。
    NSString *hook =
        @"(function(){"
         "function send(k,m){try{window.webkit.messageHandlers.dsherr.postMessage(k+': '+m);}catch(e){}}"
         "window.addEventListener('error',function(e){"
         "send('error',(e.message||'?')+' @ '+(e.filename||'?')+':'+(e.lineno||0));},true);"
         "window.addEventListener('unhandledrejection',function(e){"
         "send('rejection',String(e.reason&&e.reason.stack||e.reason));},true);"
         "var ce=console.error;console.error=function(){"
         "try{send('console.error',Array.prototype.map.call(arguments,String).join(' '));}catch(x){}"
         "return ce.apply(console,arguments);};"
         "})();";
    [cfg.userContentController addUserScript:
        [[WKUserScript alloc] initWithSource:hook
                               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                            forMainFrameOnly:NO]];
    [cfg.userContentController addScriptMessageHandler:(id<WKScriptMessageHandler>)self
                                                  name:@"dsherr"];

    // Electron preload 的 7 个 API，影响使用的都补回来。
    //
    // 能同步的（版本 / 平台 / 路径 / 语言 / 引导状态）直接在脚本里给常量，
    // 不来回发消息；只有 ready/failed/quit 需要通知原生，复用 dsherr 通道。
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.0.0";
    NSString *bridge =
        [NSString stringWithFormat:
         @"(function(){"
          "var root='%@';"
          "var paths={home:'/var/mobile',userData:root+'/data',temp:root+'/cache/tmp',"
          "documents:root+'/workspaces',logs:root+'/logs'};"
          "function post(m){try{window.webkit.messageHandlers.dsherr.postMessage('bridge: '+m);}catch(e){}}"
          "window.__DSH_HOST_PATHS__={pathFor:function(k){return paths[k]||root}};"
          "window.__DSH_LOCALE__={read:function(){return 'zh-CN'},onChange:function(){return function(){}}};"
          "window.dshOnboarding={hasApiKey:function(){return true},setActive:function(){}};"
          "window.dshDesktop={app:{"
          "getVersion:function(){return '%@'},"
          "getPlatform:function(){return 'ios'},"
          "getPath:function(k){return paths[k]||root},"
          "quit:function(){post('quit')}}};"
          "window.dshPlatform={open:function(){},close:function(){post('close')},setBounds:function(){}};"
          "window.dshDesktopBoot={"
          "ready:function(){post('ready')},"
          "failed:function(e){post('failed: '+(e&&e.message||e))}};"
          "})();", kDataRoot, ver];
    [cfg.userContentController addUserScript:
        [[WKUserScript alloc] initWithSource:bridge
                               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                            forMainFrameOnly:YES]];

    // 唯一保留的 bridge API：目录选择器（「增加工作区」要用）
    [cfg.userContentController addUserScript:
        [[WKUserScript alloc] initWithSource:[DSHPicker userScriptSource]
                               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                            forMainFrameOnly:YES]];

    // 注册 dsh:// —— 页面和所有子资源都走 App 自己的网络栈，
    // 绕开「WebKit 网络进程访问不了 127.0.0.1」这个坑。
    self.proxy = [[DSHProxy alloc] init];
    self.proxy.port = kPort.integerValue;
    __weak typeof(self) weakSelf = self;
    self.proxy.onLog = ^(NSString *line) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self) DSHLog(@"%@", line);
    };
    [cfg setURLSchemeHandler:self.proxy forURLScheme:[DSHProxy scheme]];
    self.useProxy = YES;

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

    // picker 需要 webView，所以放在 webView 创建之后
    self.picker = [[DSHPicker alloc] initWithPresenter:self webView:self.web];
    [cfg.userContentController addScriptMessageHandler:self.picker
                                                  name:[DSHPicker messageName]];

    [self startKernel];
}

#pragma mark 起内核

/// 当前装的版本（deb payload 里的 VERSION 戳）
- (nullable NSString *)installedVersion {
    for (NSString *p in @[ [kInstall stringByAppendingPathComponent:@"VERSION"],
                           [kDataRoot stringByAppendingPathComponent:@"config/installed.version"] ]) {
        NSString *v = [NSString stringWithContentsOfFile:p
                                                encoding:NSUTF8StringEncoding error:NULL];
        v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (v.length > 0) return v;
    }
    return nil;
}

- (void)startKernel {
    // 先判断「已经在跑的那个内核是不是当前这一版」。
    //
    // 之前的做法是无条件杀掉所有内核再起新的 —— 每次打开 App 都重启内核，
    // 进行中的任务全丢。而如果反过来完全不管，升级后旧内核会一直占着 3080，
    // 表现就是「更新了但没生效」。
    //
    // 正确做法：版本一致就复用，不一致才停掉重开。
    NSString *installed = [self installedVersion];
    pid_t running = [DSHProc kernelPid];
    BOOL alive = (running > 0) && (kill(running, 0) == 0);

    if (alive) {
        NSString *runningVer = [DSHProc recordedKernelVersion];
        if (installed.length > 0 && runningVer.length > 0
            && [runningVer isEqualToString:installed]) {
            DSHLog(@"内核已在运行且版本一致（%@ pid=%d），直接复用", runningVer, running);
            [self poll];
            return;
        }
        DSHLog(@"内核在跑但版本对不上：跑的是 %@，装的是 %@ —— 停掉重开",
               runningVer ?: @"(未知)", installed ?: @"(未知)");
    } else if (installed.length > 0) {
        DSHLog(@"没有内核在跑，启动 %@", installed);
    }

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
            // pidfile 里同时记下版本，下次启动才能判断「跑的是不是这一版」
            [DSHProc writeKernelPid:pid version:[self installedVersion]];
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
        [self nativeFetchThenLoad];
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

/// 用 NSURLSession 自己取一次。
/// 目的：把「服务端是否响应 App 进程」和「WKWebView 是否响应」分开。
/// 如果这里 200、WKWebView 却收不到响应头，那就是 WebKit 那条链路的问题。
- (void)nativeFetchThenLoad {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/", kPort]];
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    c.timeoutIntervalForRequest = 8;
    NSURLSession *s = [NSURLSession sessionWithConfiguration:c];
    [[s dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]]
                       ? ((NSHTTPURLResponse *)resp).statusCode : -1;
        self.nativeStatus = code;
        DSHLog(@"原生 GET / → HTTP %ld, %lu 字节, err=%@",
               (long)code, (unsigned long)data.length, err.localizedDescription ?: @"无");
        if (data.length > 0) {
            NSString *body = [[NSString alloc] initWithData:
                              [data subdataWithRange:NSMakeRange(0, MIN((NSUInteger)200, data.length))]
                                                   encoding:NSUTF8StringEncoding];
            DSHLog(@"  响应前 200 字节: %@", [body stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self load]; });
    }] resume];
}

- (void)load {
    NSURL *url = self.useProxy
        ? [DSHProxy entryURL]
        : [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/", kPort]];
    DSHLog(@"loadRequest %@（%@）", url, self.useProxy ? @"dsh:// 代理" : @"直连 http");
    [self.web loadRequest:[NSURLRequest requestWithURL:url
                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                       timeoutInterval:30]];

    // 看门狗：WKWebView 有时候既不给 didFinish 也不给 didFail，
    // 就这么一直白着。15 秒还没完成就把状态画在页面上，别让人干等。
    self.finished = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.finished) return;
        if (self.useProxy) {
            DSHLog(@"⚠ dsh:// 代理 15 秒未完成，改试直连 http");
            self.useProxy = NO;
            self.finished = NO;
            [self load];
            return;
        }
        DSHLog(@"⚠ 15 秒仍未完成（isLoading=%d），显示诊断页", self.web.isLoading);
        [self showDiagnosticPage];
    });
}

- (void)showDiagnosticPage {
    NSString *html = [NSString stringWithFormat:
        @"<!doctype html><meta name=viewport content='width=device-width'>"
         "<body style='font:16px -apple-system;padding:24px;line-height:1.7'>"
         "<h3>页面没有加载出来</h3>"
         "<p>内核在监听 <code>127.0.0.1:%@</code>，但这个 WebView 收不到响应。</p>"
         "<p>WebView isLoading = %d</p>"
         "<p>dsh:// 代理和直连 http 都试过了</p>"
         "<p>原生 GET / 返回 HTTP %ld</p>"
         "<p>可能原因：WKWebView 的网络进程访问不了回环地址。</p>"
         "<p><button onclick=\"location.href='http://127.0.0.1:%@/'\" "
         "style='font-size:16px;padding:10px 18px'>重试</button></p>"
         "</body>", kPort, self.web.isLoading, self.nativeStatus, kPort];
    [self.web loadHTMLString:html baseURL:nil];
}

#pragma mark WKNavigationDelegate

- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    DSHLog(@"页面报错 %@", message.body);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    DSHLog(@"开始请求：%@", webView.URL.absoluteString);
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    DSHLog(@"收到响应，开始渲染");
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    DSHLog(@"加载失败(didFail)：%@ (%@)", error.localizedDescription, @(error.code));
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.finished = YES;
    DSHLog(@"页面加载完成：%@", webView.URL.absoluteString);
    // 白屏时最需要知道的两件事：标题有没有、正文有多长
    [webView evaluateJavaScript:
        @"JSON.stringify({title:document.title,"
         "textLen:(document.body?document.body.innerText.length:-1),"
         "htmlLen:document.documentElement.outerHTML.length,"
         "scripts:document.scripts.length})"
        completionHandler:^(id result, NSError *error) {
        DSHLog(@"页面状态 %@ %@", result ?: @"(nil)", error ? error.localizedDescription : @"");
    }];
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
