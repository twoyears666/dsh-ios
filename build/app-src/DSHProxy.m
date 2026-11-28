//
//  DSHProxy.m
//
#import "DSHProxy.h"

@interface DSHProxy ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionDataTask *> *tasks;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) NSInteger hits;
@end

@implementation DSHProxy

+ (NSString *)scheme { return @"dsh"; }

+ (NSURL *)entryURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@://app/", [self scheme]]];
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.timeoutIntervalForRequest = 30;
        c.timeoutIntervalForResource = 60;
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:c];
        _tasks = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
        _port = 3080;
    }
    return self;
}

- (NSString *)keyForTask:(id<WKURLSchemeTask>)task {
    return [NSString stringWithFormat:@"%p", task];
}

#pragma mark - WKURLSchemeHandler

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURL *u = task.request.URL;
    NSURLComponents *c = [[NSURLComponents alloc] init];
    c.scheme = @"http";
    c.host = @"127.0.0.1";
    c.port = @(self.port);
    c.path = u.path.length > 0 ? u.path : @"/";
    c.query = u.query;
    NSURL *target = c.URL;
    if (target == nil) {
        [self fail:task error:[NSError errorWithDomain:@"dsh.proxy" code:-1
                                              userInfo:@{ NSLocalizedDescriptionKey: @"URL 拼接失败" }]];
        return;
    }

    // 只记前 8 个请求，避免刷屏；失败全记
    if (self.hits < 8) {
        self.hits += 1;
        if (self.onLog) self.onLog([NSString stringWithFormat:@"代理 ← %@ %@",
                                    task.request.HTTPMethod ?: @"GET", u.path]);
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:target];
    req.HTTPMethod = task.request.HTTPMethod.length > 0 ? task.request.HTTPMethod : @"GET";
    req.HTTPBody = task.request.HTTPBody;
    // 原样带上请求头，但去掉 Host（由 NSURLSession 自己填）
    for (NSString *h in task.request.allHTTPHeaderFields) {
        if ([h caseInsensitiveCompare:@"Host"] == NSOrderedSame) continue;
        [req setValue:task.request.allHTTPHeaderFields[h] forHTTPHeaderField:h];
    }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *dt = [self.session dataTaskWithRequest:req
                                              completionHandler:^(NSData *data, NSURLResponse *resp,
                                                                  NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self.lock lock];
        [self.tasks removeObjectForKey:[self keyForTask:task]];
        [self.lock unlock];

        if (error != nil) {
            [self fail:task error:error];
            return;
        }
        if (![resp isKindOfClass:[NSHTTPURLResponse class]]) {
            [self fail:task error:[NSError errorWithDomain:@"dsh.proxy" code:-2
                                                  userInfo:@{ NSLocalizedDescriptionKey: @"不是 HTTP 响应" }]];
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        NSMutableDictionary *headers = [http.allHeaderFields mutableCopy];
        // NSURLSession 已经解压过，这几个头必须去掉，否则 WebKit 会二次解压/截断
        [headers removeObjectForKey:@"Content-Encoding"];
        [headers removeObjectForKey:@"Content-Length"];
        [headers removeObjectForKey:@"Transfer-Encoding"];
        [headers removeObjectForKey:@"content-encoding"];
        [headers removeObjectForKey:@"content-length"];
        [headers removeObjectForKey:@"transfer-encoding"];

        // 用原始 dsh:// URL 构造响应 —— scheme 必须和请求一致
        NSHTTPURLResponse *out = [[NSHTTPURLResponse alloc] initWithURL:task.request.URL
                                                             statusCode:http.statusCode
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:headers];
        @try {
            [task didReceiveResponse:out];
            if (data.length > 0) [task didReceiveData:data];
            [task didFinish];
        } @catch (NSException *e) {
            // task 已被 stop，忽略
        }
    }];

    [self.lock lock];
    self.tasks[[self keyForTask:task]] = dt;
    [self.lock unlock];
    [dt resume];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    [self.lock lock];
    NSURLSessionDataTask *dt = self.tasks[[self keyForTask:task]];
    [self.tasks removeObjectForKey:[self keyForTask:task]];
    [self.lock unlock];
    [dt cancel];
}

- (void)fail:(id<WKURLSchemeTask>)task error:(NSError *)error {
    if (self.onLog) self.onLog([NSString stringWithFormat:@"代理 ✗ %@ → %@",
                                task.request.URL.path, error.localizedDescription]);
    @try {
        [task didFailWithError:error];
    } @catch (NSException *e) {
        // task 已被 stop
    }
}

@end
