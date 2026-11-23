//
//  DSHBrowserBridge.m
//
#import "DSHBrowserBridge.h"

static NSString *const kBrowserMsgHandler = @"dshBrowser";

// ============================================================================
// 注入脚本：<webview> 元素 polyfill
//
// Electron 的 <webview> 是 Chromium 的 guest view。iOS 没有，
// 这里用一个普通 div + 原生 WKWebView 叠加来模拟。
//
// 关键设计：
//   - 每个 webview 元素在原生侧对应一个真实 WKWebView
//   - 原生 WKWebView 由 App 直接 addSubview 到宿主 WebView 的父视图上，
//     位置由 JS 上报（viewportId 元素的 getBoundingClientRect）
//   - JS 侧只保留一个透明的占位 div，用于布局和事件转发
// ============================================================================
static NSString *const kBrowserJS = @"(function () {\n"
@"  if (window.__DSH_IOS_WEBVIEW__) return;\n"
@"  window.__DSH_IOS_WEBVIEW__ = true;\n"
@"\n"
@"  var seq = 0;\n"
@"  var pending = {};\n"
@"  var instances = {};\n"
@"\n"
@"  function call(method, args) {\n"
@"    return new Promise(function (resolve, reject) {\n"
@"      var id = ++seq;\n"
@"      pending[id] = { resolve: resolve, reject: reject };\n"
@"      try {\n"
@"        window.webkit.messageHandlers.dshBrowser.postMessage(\n"
@"          { id: id, method: method, args: args || {} });\n"
@"      } catch (e) {\n"
@"        delete pending[id];\n"
@"        reject(new Error('browser bridge unavailable: ' + e.message));\n"
@"      }\n"
@"    });\n"
@"  }\n"
@"\n"
@"  // 原生回调入口\n"
@"  window.__dshBrowserReply = function (id, ok, value, error) {\n"
@"    var p = pending[id];\n"
@"    if (!p) return;\n"
@"    delete pending[id];\n"
@"    if (ok) p.resolve(value); else p.reject(new Error(error || 'native error'));\n"
@"  };\n"
@"\n"
@"  // 原生事件入口：native → 元素派发\n"
@"  window.__dshBrowserEvent = function (lease, name, detail) {\n"
@"    var el = instances[lease];\n"
@"    if (!el) return;\n"
@"    try {\n"
@"      var ev = new CustomEvent(name, { detail: detail || {} });\n"
@"      // Electron 的 did-fail-load 事件直接读 event.isMainFrame / errorCode 等\n"
@"      if (detail) {\n"
@"        Object.keys(detail).forEach(function (k) { ev[k] = detail[k]; });\n"
@"      }\n"
@"      el.dispatchEvent(ev);\n"
@"    } catch (e) {}\n"
@"  };\n"
@"\n"
@"  // ---- WebviewElement polyfill ----\n"
@"  function WebviewElement() {\n"
@"    var el = document.createElement('div');\n"
@"    el.__lease = null;\n"
@"    el.__src = 'about:blank';\n"
@"    el.__ready = false;\n"
@"    el.__rectTimer = null;\n"
@"\n"
@"    el.loadURL = function (url) {\n"
@"      var lease = el.__lease;\n"
@"      if (!lease) return Promise.reject(new Error('webview not acquired'));\n"
@"      el.__src = url;\n"
@"      return call('load', { lease: lease, url: url });\n"
@"    };\n"
@"    el.getURL = function () { return el.__url || el.__src || ''; };\n"
@"    el.getTitle = function () { return el.__title || ''; };\n"
@"    el.canGoBack = function () { return !!el.__canGoBack; };\n"
@"    el.canGoForward = function () { return !!el.__canGoForward; };\n"
@"    el.isLoading = function () { return !!el.__loading; };\n"
@"    el.clearHistory = function () { return call('clearHistory', { lease: el.__lease }); };\n"
@"    el.goBack = function () { return call('goBack', { lease: el.__lease }); };\n"
@"    el.goForward = function () { return call('goForward', { lease: el.__lease }); };\n"
@"    el.reload = function () { return call('reload', { lease: el.__lease }); };\n"
@"\n"
@"    // 位置同步：原生 WKWebView 需要跟随占位 div 的屏幕位置\n"
@"    function syncRect() {\n"
@"      var lease = el.__lease;\n"
@"      if (!lease) return;\n"
@"      var r = el.getBoundingClientRect();\n"
@"      call('setFrame', {\n"
@"        lease: lease,\n"
@"        x: r.left, y: r.top, width: r.width, height: r.height,\n"
@"        visible: r.width > 1 && r.height > 1\n"
@"      }).catch(function () {});\n"
@"    }\n"
@"    el.__syncRect = syncRect;\n"
@"\n"
@"    // 观察尺寸/位置变化\n"
@"    if (typeof ResizeObserver !== 'undefined') {\n"
@"      try { new ResizeObserver(syncRect).observe(el); } catch (e) {}\n"
@"    }\n"
@"    window.addEventListener('resize', syncRect);\n"
@"    window.addEventListener('scroll', syncRect, true);\n"
@"    el.__rectTimer = setInterval(syncRect, 500);\n"
@"\n"
@"    return el;\n"
@"  }\n"
@"\n"
@"  // 劫持 document.createElement('webview')\n"
@"  var origCreate = document.createElement.bind(document);\n"
@"  document.createElement = function (tag, opts) {\n"
@"    if (String(tag).toLowerCase() === 'webview') {\n"
@"      var el = WebviewElement();\n"
@"      el.className = 'dsh-ios-webview-placeholder';\n"
@"      el.style.cssText = 'width:100%;height:100%;display:block;background:transparent;';\n"
@"      return el;\n"
@"    }\n"
@"    return origCreate(tag, opts);\n"
@"  };\n"
@"\n"
@"  // 元素插入 DOM 后，用 name 属性（lease）建立映射\n"
@"  var origAppend = Element.prototype.appendChild;\n"
@"  Element.prototype.appendChild = function (child) {\n"
@"    var r = origAppend.call(this, child);\n"
@"    if (child && child.__lease === null && child.dataset &&\n"
@"        child.dataset.sidebarBrowserFrame === 'webview') {\n"
@"      var lease = child.getAttribute('name');\n"
@"      if (lease) {\n"
@"        child.__lease = lease;\n"
@"        instances[lease] = child;\n"
@"        // 通知原生：元素已挂载，创建 WKWebView\n"
@"        call('mount', { lease: lease, partition: child.getAttribute('partition') || 'default' })\n"
@"          .then(function () {\n"
@"            child.__ready = true;\n"
@"            window.__dshBrowserEvent(lease, 'dom-ready', {});\n"
@"            setTimeout(function () { child.__syncRect && child.__syncRect(); }, 0);\n"
@"          })\n"
@"          .catch(function (e) { console.error('webview mount failed', e); });\n"
@"      }\n"
@"    }\n"
@"    return r;\n"
@"  };\n"
@"\n"
@"  var origRemove = Element.prototype.removeChild;\n"
@"  Element.prototype.removeChild = function (child) {\n"
@"    if (child && child.__lease) {\n"
@"      var lease = child.__lease;\n"
@"      delete instances[lease];\n"
@"      if (child.__rectTimer) clearInterval(child.__rectTimer);\n"
@"      call('unmount', { lease: lease }).catch(function () {});\n"
@"    }\n"
@"    return origRemove.call(this, child);\n"
@"  };\n"
@"\n"
@"  // ---- 暴露 dshDesktop.browser ----\n"
@"  var browser = {\n"
@"    acquire: function (workspaceKey) {\n"
@"      return call('acquire', { workspaceKey: workspaceKey });\n"
@"    },\n"
@"    release: function (lease) {\n"
@"      return call('release', { lease: lease });\n"
@"    },\n"
@"    onOpenRequested: function (lease, cb) {\n"
@"      var key = 'open:' + lease;\n"
@"      window.__dshBrowserOpenCbs = window.__dshBrowserOpenCbs || {};\n"
@"      window.__dshBrowserOpenCbs[key] = cb;\n"
@"      return function () { delete window.__dshBrowserOpenCbs[key]; };\n"
@"    }\n"
@"  };\n"
@"\n"
@"  // 原生侧触发 target=_blank\n"
@"  window.__dshBrowserOpenRequested = function (lease, url) {\n"
@"    var cbs = window.__dshBrowserOpenCbs || {};\n"
@"    var cb = cbs['open:' + lease];\n"
@"    if (typeof cb === 'function') { try { cb(url); } catch (e) {} }\n"
@"  };\n"
@"\n"
@"  // 合并进已有的 dshDesktop（DSHBridge 已经建了基础对象）\n"
@"  if (!window.dshDesktop) window.dshDesktop = {};\n"
@"  window.dshDesktop.browser = browser;\n"
@"  window.dshDesktop.protocolVersion = 1;\n"
@"})();\n";

@implementation DSHBrowserBridge {
  __weak WKWebView *_host;
  NSMutableDictionary<NSString *, WKWebView *> *_guests;
  NSMutableDictionary<NSString *, WKWebView *> *_leases;
}

- (instancetype)init {
  if ((self = [super init])) {
    _guests = [NSMutableDictionary dictionary];
    _leases = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)attachToWebView:(WKWebView *)webView {
  _host = webView;
  WKUserContentController *ucc = webView.configuration.userContentController;
  [ucc addUserScript:[[WKUserScript alloc] initWithSource:kBrowserJS
                                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                         forMainFrameOnly:NO]];
  [ucc addScriptMessageHandler:self name:kBrowserMsgHandler];
}

- (void)disposeAll {
  for (WKWebView *wv in _guests.allValues) {
    [wv removeFromSuperview];
  }
  [_guests removeAllObjects];
  [_leases removeAllObjects];
}

#pragma mark - 消息分发

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
  if (![message.name isEqualToString:kBrowserMsgHandler]) return;
  NSDictionary *body = message.body;
  if (![body isKindOfClass:[NSDictionary class]]) return;

  NSNumber *reqId = body[@"id"];
  NSString *method = body[@"method"];
  NSDictionary *args = body[@"args"];
  if (![args isKindOfClass:[NSDictionary class]]) args = @{};

  NSString *lease = args[@"lease"];
  if (![lease isKindOfClass:[NSString class]]) lease = nil;

  // acquire
  if ([method isEqualToString:@"acquire"]) {
    NSString *key = args[@"workspaceKey"] ?: @"default";
    NSString *newLease = [self makeLease];
    NSString *partition = [@"persist:dsh-" stringByAppendingString:
                           [self sanitize:key]];
    _leases[newLease] = [NSNull null];  // 占位，mount 时才建 WKWebView
    [self reply:reqId ok:YES value:@{@"lease": newLease, @"partition": partition} error:nil];
    return;
  }

  // release
  if ([method isEqualToString:@"release"]) {
    if (lease) [self destroyGuest:lease];
    [self reply:reqId ok:YES value:nil error:nil];
    return;
  }

  // mount：元素挂载，创建真实 WKWebView
  if ([method isEqualToString:@"mount"]) {
    if (!lease) { [self reply:reqId ok:NO value:nil error:@"missing lease"]; return; }
    NSString *partition = args[@"partition"];
    [self createGuest:lease partition:partition];
    [self reply:reqId ok:YES value:nil error:nil];
    return;
  }

  // unmount
  if ([method isEqualToString:@"unmount"]) {
    if (lease) [self destroyGuest:lease];
    [self reply:reqId ok:YES value:nil error:nil];
    return;
  }

  // setFrame：跟随占位 div 的位置
  if ([method isEqualToString:@"setFrame"]) {
    WKWebView *wv = _guests[lease ?: @""];
    if (wv) {
      CGFloat x = [args[@"x"] doubleValue];
      CGFloat y = [args[@"y"] doubleValue];
      CGFloat w = [args[@"width"] doubleValue];
      CGFloat h = [args[@"height"] doubleValue];
      BOOL visible = [args[@"visible"] boolValue];
      wv.hidden = !visible;
      if (visible) wv.frame = CGRectMake(x, y, w, h);
    }
    [self reply:reqId ok:YES value:nil error:nil];
    return;
  }

  // 导航类：转发到 WKWebView
  WKWebView *wv = _guests[lease ?: @""];
  if (!wv) {
    [self reply:reqId ok:NO value:nil error:@"webview not mounted"];
    return;
  }

  if ([method isEqualToString:@"load"]) {
    NSString *urlStr = args[@"url"];
    NSURL *url = urlStr ? [NSURL URLWithString:urlStr] : nil;
    if (!url) { [self reply:reqId ok:NO value:nil error:@"invalid url"]; return; }
    [wv loadRequest:[NSURLRequest requestWithURL:url]];
    [self reply:reqId ok:YES value:nil error:nil];
    return;
  }
  if ([method isEqualToString:@"reload"]) {
    [wv reload];
    [self reply:reqId ok:YES value:nil error:nil];
    return;
  }
  if ([method isEqualToString:@"goBack"]) {
    if ([wv canGoBack]) [wv goBack];
    [self reply:reqId ok:YES value:nil error:nil];
    return;
  }
  if ([method isEqualToString:@"goForward"]) {
    if ([wv canGoForward]) [wv goForward];
    [self reply:reqId ok:YES value:nil error:nil];
    return;
  }
  if ([method isEqualToString:@"clearHistory"]) {
    // WKWebView 没有公开的 clearHistory；用重载当前页近似
    [wv reload];
    [self reply:reqId ok:YES value:nil error:nil];
    return;
  }

  [self reply:reqId ok:NO value:nil
        error:[NSString stringWithFormat:@"unknown method: %@", method]];
}

#pragma mark - Guest 生命周期

- (NSString *)makeLease {
  return [[NSUUID UUID].UUIDString lowercaseString];
}

- (NSString *)sanitize:(NSString *)s {
  NSMutableString *out = [NSMutableString string];
  for (NSUInteger i = 0; i < s.length && out.length < 40; i++) {
    unichar c = [s characterAtIndex:i];
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
      [out appendFormat:@"%C", c];
    } else if (c >= 'A' && c <= 'Z') {
      [out appendFormat:@"%C", (unichar)(c - 'A' + 'a')];
    }
  }
  return out.length ? out : @"default";
}

- (void)createGuest:(NSString *)lease partition:(NSString *)partition {
  if (_guests[lease]) return;

  WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
  cfg.allowsInlineMediaPlayback = YES;
  // 每个 lease 独立数据分区（对应 Electron 的 partition）
  if (partition.length > 0) {
    cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
  }
  // 允许 target=_blank：拦截后交给上层开新标签
  cfg.preferences.javaScriptCanOpenWindowsAutomatically = YES;

  WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
  wv.navigationDelegate = self;
  wv.allowsBackForwardNavigationGestures = YES;
  wv.opaque = NO;
  wv.backgroundColor = [UIColor systemBackgroundColor];
  wv.hidden = YES;

  // 挂到宿主 WebView 的父视图（这样能盖在 UI 上）
  UIView *container = _host.superview ?: _host;
  [container addSubview:wv];

  _guests[lease] = wv;
  _leases[lease] = wv;

  NSLog(@"[dsh-browser] guest created lease=%@ partition=%@", lease, partition);
}

- (void)destroyGuest:(NSString *)lease {
  WKWebView *wv = _guests[lease];
  if (wv) {
    [wv stopLoading];
    wv.navigationDelegate = nil;
    [wv removeFromSuperview];
    [_guests removeObjectForKey:lease];
  }
  [_leases removeObjectForKey:lease];
}

/// 由 lease 反查（事件回调时用）
- (nullable NSString *)leaseForWebView:(WKWebView *)wv {
  for (NSString *key in _guests) {
    if (_guests[key] == wv) return key;
  }
  return nil;
}

#pragma mark - 事件转发到 JS

- (void)emit:(NSString *)name lease:(NSString *)lease detail:(NSDictionary *)detail {
  if (!lease) return;
  NSData *d = [NSJSONSerialization dataWithJSONObject:(detail ?: @{}) options:0 error:NULL];
  NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
  NSString *js = [NSString stringWithFormat:
                  @"window.__dshBrowserEvent && window.__dshBrowserEvent(%@, %@, %@);",
                  [self jsStr:lease], [self jsStr:name], json];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self->_host evaluateJavaScript:js completionHandler:nil];
  });
}

- (NSString *)jsStr:(NSString *)s {
  NSData *d = [NSJSONSerialization dataWithJSONObject:@[s ?: @""] options:0 error:NULL];
  if (!d) return @"\"\"";
  NSString *arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  NSString *lease = [self leaseForWebView:webView];
  if (!lease) return;
  NSDictionary *detail = @{
    @"url": webView.URL.absoluteString ?: @"",
    @"title": webView.title ?: @"",
    @"canGoBack": @(webView.canGoBack),
    @"canGoForward": @(webView.canGoForward),
  };
  [self emit:@"did-navigate" lease:lease detail:detail];
  [self emit:@"did-stop-loading" lease:lease detail:detail];
  [self emit:@"page-title-updated" lease:lease detail:detail];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
  NSString *lease = [self leaseForWebView:webView];
  if (!lease) return;
  [self emit:@"did-start-navigation" lease:lease
      detail:@{@"isMainFrame": @YES, @"url": webView.URL.absoluteString ?: @""}];
  [self emit:@"did-start-loading" lease:lease detail:@{}];
}

- (void)webView:(WKWebView *)webView
didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
  NSString *lease = [self leaseForWebView:webView];
  if (!lease) return;
  // -3 = ERR_ABORTED，Electron 侧也忽略
  if (error.code == NSURLErrorCancelled) return;
  [self emit:@"did-fail-load" lease:lease detail:@{
    @"isMainFrame": @YES,
    @"errorCode": @(error.code),
    @"errorDescription": error.localizedDescription ?: @"",
  }];
  [self emit:@"did-stop-loading" lease:lease detail:@{}];
}

- (void)webView:(WKWebView *)webView
didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
  [self webView:webView didFailProvisionalNavigation:navigation withError:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  NSString *lease = [self leaseForWebView:webView];
  if (!lease) return;
  [self emit:@"render-process-gone" lease:lease detail:@{}];
  [self emit:@"destroyed" lease:lease detail:@{}];
}

/// target=_blank / window.open 拦截
- (WKWebView *)webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
           forNavigationAction:(WKNavigationAction *)action
                windowFeatures:(WKWindowFeatures *)features {
  if (!action.targetFrame.isMainFrame) {
    NSString *url = action.request.URL.absoluteString;
    NSString *lease = [self leaseForWebView:webView];
    if (url.length > 0) {
      [self.delegate browserBridgeOpenRequested:url lease:lease ?: @""];
    }
  }
  return nil;
}

#pragma mark - 回复

- (void)reply:(NSNumber *)reqId ok:(BOOL)ok value:(id)value error:(NSString *)error {
  NSMutableDictionary *payload = [NSMutableDictionary dictionary];
  payload[@"id"] = reqId;
  payload[@"ok"] = @(ok);
  if (value) payload[@"value"] = value;
  if (error) payload[@"error"] = error;

  NSData *d = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
  if (!d) return;
  NSString *json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];

  NSString *js = [NSString stringWithFormat:
                  @"window.__dshBrowserReply && window.__dshBrowserReply(%@, %@, %@, %@);",
                  reqId,
                  ok ? @"true" : @"false",
                  value ? [self jsValue:value] : @"null",
                  error ? [self jsStr:error] : @"null"];

  dispatch_async(dispatch_get_main_queue(), ^{
    [self->_host evaluateJavaScript:js completionHandler:nil];
  });
}

- (NSString *)jsValue:(id)value {
  if (!value || value == [NSNull null]) return @"null";
  if ([value isKindOfClass:[NSString class]]) return [self jsStr:value];
  if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
  NSData *d = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
  if (d) return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  return [self jsStr:[value description]];
}

@end
