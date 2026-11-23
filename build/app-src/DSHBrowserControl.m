//
//  DSHBrowserControl.m
//
#import "DSHBrowserControl.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

static const uint16_t kDefaultPort = 3081;
static const NSUInteger kMaxBodyBytes = 1024 * 1024;  // 1 MB

@implementation DSHBrowserControl {
  int _listenFd;
  dispatch_queue_t _queue;
  BOOL _running;
}

- (instancetype)init {
  if ((self = [super init])) {
    _listenFd = -1;
    _queue = dispatch_queue_create("com.twoyears.dsh.browser-control",
                                   DISPATCH_QUEUE_SERIAL);
    _running = NO;
  }
  return self;
}

- (BOOL)startOnPort:(uint16_t)port {
  if (_running) return YES;
  uint16_t p = port ?: kDefaultPort;

  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return NO;

  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  // 避免对端断开时进程收到 SIGPIPE 被杀
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));

  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(p);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 只监听 127.0.0.1

  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(fd);
    NSLog(@"[dsh-browser-ctl] bind %u 失败: %s", p, strerror(errno));
    return NO;
  }
  if (listen(fd, 8) != 0) {
    close(fd);
    return NO;
  }

  _listenFd = fd;
  _running = YES;
  NSLog(@"[dsh-browser-ctl] 监听 127.0.0.1:%u", p);

  __weak typeof(self) weakSelf = self;
  dispatch_async(_queue, ^{
    [weakSelf acceptLoop];
  });
  return YES;
}

- (void)acceptLoop {
  while (_running) {
    struct sockaddr_in peer;
    socklen_t len = sizeof(peer);
    int client = accept(_listenFd, (struct sockaddr *)&peer, &len);
    if (client < 0) {
      if (!_running) break;
      if (errno == EINTR) continue;
      usleep(50 * 1000);
      continue;
    }
    [self handleClient:client];
    close(client);
  }
}

- (void)handleClient:(int)client {
  int yes = 1;
  setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));

  // 设 10 秒超时，避免慢连接占死队列
  struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
  setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

  NSMutableData *buf = [NSMutableData data];
  char chunk[4096];
  ssize_t got;
  NSUInteger headerEnd = NSNotFound;
  NSUInteger contentLength = 0;

  while ((got = read(client, chunk, sizeof(chunk))) > 0) {
    [buf appendBytes:chunk length:(NSUInteger)got];
    if (buf.length > kMaxBodyBytes) break;

    if (headerEnd == NSNotFound) {
      NSRange r = [buf rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                           options:0 range:NSMakeRange(0, buf.length)];
      if (r.location != NSNotFound) {
        headerEnd = r.location + r.length;
        // 解析 Content-Length
        NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, headerEnd)]
                                               encoding:NSUTF8StringEncoding];
        for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
          if ([line.lowercaseString hasPrefix:@"content-length:"]) {
            contentLength = (NSUInteger)[[line substringFromIndex:15]
                                stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]].integerValue;
            break;
          }
        }
      }
    }

    if (headerEnd != NSNotFound) {
      NSUInteger bodyLen = buf.length - headerEnd;
      if (bodyLen >= contentLength) break;
    }
  }

  if (headerEnd == NSNotFound || headerEnd > buf.length) {
    [self respond:client status:400 json:@{@"error": @"bad request"}];
    return;
  }

  NSData *bodyData = [buf subdataWithRange:NSMakeRange(headerEnd, buf.length - headerEnd)];
  NSDictionary *req = nil;
  if (bodyData.length > 0) {
    req = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:NULL];
  }
  if (![req isKindOfClass:[NSDictionary class]]) {
    [self respond:client status:400 json:@{@"error": @"invalid JSON body"}];
    return;
  }

  NSString *action = req[@"action"];
  NSString *tabId = [req[@"tabId"] isKindOfClass:[NSString class]] ? req[@"tabId"] : nil;
  id<DSHBrowserControlDelegate> d = self.delegate;
  if (!d) {
    [self respond:client status:503 json:@{@"error": @"browser control not ready"}];
    return;
  }

  NSDictionary *result = nil;
  @try {
    if ([action isEqualToString:@"open"]) {
      NSString *url = req[@"url"];
      if (![url isKindOfClass:[NSString class]] || url.length == 0) {
        [self respond:client status:400 json:@{@"error": @"missing url"}];
        return;
      }
      result = [d controlOpenURL:url];
    } else if ([action isEqualToString:@"snapshot"]) {
      NSInteger maxChars = [req[@"maxChars"] integerValue];
      if (maxChars <= 0) maxChars = 20000;
      result = [d controlSnapshotTab:tabId maxChars:maxChars];
    } else if ([action isEqualToString:@"click"]) {
      NSString *sel = req[@"selector"];
      if (![sel isKindOfClass:[NSString class]] || sel.length == 0) {
        [self respond:client status:400 json:@{@"error": @"missing selector"}];
        return;
      }
      result = [d controlClickSelector:sel tab:tabId];
    } else if ([action isEqualToString:@"type"]) {
      NSString *sel = req[@"selector"];
      NSString *text = req[@"text"];
      if (![sel isKindOfClass:[NSString class]] || ![text isKindOfClass:[NSString class]]) {
        [self respond:client status:400 json:@{@"error": @"missing selector or text"}];
        return;
      }
      result = [d controlTypeSelector:sel text:text submit:[req[@"submit"] boolValue] tab:tabId];
    } else if ([action isEqualToString:@"screenshot"]) {
      result = [d controlScreenshotTab:tabId];
    } else if ([action isEqualToString:@"eval"]) {
      NSString *expr = req[@"expression"];
      if (![expr isKindOfClass:[NSString class]] || expr.length == 0) {
        [self respond:client status:400 json:@{@"error": @"missing expression"}];
        return;
      }
      result = [d controlEvalExpression:expr tab:tabId];
    } else {
      [self respond:client status:400 json:@{@"error": @"unknown action"}];
      return;
    }
  } @catch (NSException *e) {
    [self respond:client status:500 json:@{@"error": e.reason ?: @"internal error"}];
    return;
  }

  [self respond:client status:200 json:result ?: @{}];
}

- (void)respond:(int)client status:(int)status json:(NSDictionary *)json {
  NSData *body = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
  if (!body) body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];

  NSString *statusText = status == 200 ? @"OK"
                       : status == 400 ? @"Bad Request"
                       : status == 503 ? @"Service Unavailable"
                       : @"Internal Server Error";

  NSString *head = [NSString stringWithFormat:
      @"HTTP/1.1 %d %@\r\n"
       "Content-Type: application/json\r\n"
       "Content-Length: %lu\r\n"
       "Connection: close\r\n"
       "\r\n",
      status, statusText, (unsigned long)body.length];

  NSMutableData *out = [NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
  [out appendData:body];

  const uint8_t *bytes = out.bytes;
  NSUInteger remaining = out.length;
  while (remaining > 0) {
    ssize_t n = write(client, bytes, remaining);
    if (n <= 0) break;
    bytes += n;
    remaining -= (NSUInteger)n;
  }
}

- (void)stop {
  _running = NO;
  if (_listenFd >= 0) {
    close(_listenFd);
    _listenFd = -1;
  }
}

- (void)dealloc {
  [self stop];
}

@end
