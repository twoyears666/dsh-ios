//
//  DSHBridge.m
//
#import "DSHBridge.h"

NSString *const kDSHBridgeMessage = @"dshBridge";

// ============================================================================
// 注入脚本：复现 Electron preload 暴露的 7 个 API
//
// 关键设计：所有原生调用都通过 postMessage 走异步，用 requestId 配对 Promise，
// 这样 JS 侧拿到的是真正的 Promise，与 Electron 版语义一致。
// ============================================================================
static NSString *const kBridgeJS =
"(function () {\n"
"  if (window.__DSH_IOS_BRIDGE__) return;\n"
"  window.__DSH_IOS_BRIDGE__ = true;\n"
"\n"
"  var pending = {};\n"
"  var seq = 0;\n"
"\n"
"  function call(method, args) {\n"
"    return new Promise(function (resolve, reject) {\n"
"      var id = ++seq;\n"
"      pending[id] = { resolve: resolve, reject: reject };\n"
"      try {\n"
"        window.webkit.messageHandlers.dshBridge.postMessage({\n"
"          id: id, method: method, args: args || {}\n"
"        });\n"
"      } catch (e) {\n"
"        delete pending[id];\n"
"        reject(new Error('bridge unavailable: ' + e.message));\n"
"      }\n"
"    });\n"
"  }\n"
"\n"
"  // 原生回调入口\n"
"  window.__dshBridgeReply = function (id, ok, value, error) {\n"
"    var p = pending[id];\n"
"    if (!p) return;\n"
"    delete pending[id];\n"
"    if (ok) p.resolve(value);\n"
"    else p.reject(new Error(error || 'native error'));\n"
"  };\n"
"\n"
"  // ---- dshOnboarding ----\n"
"  window.dshOnboarding = {\n"
"    hasApiKey: function () { return call('onboarding.hasApiKey'); },\n"
"    setActive: function (v) { return call('onboarding.setActive', { active: v }); }\n"
"  };\n"
"\n"
"  // ---- __DSH_DIRECTORY_PICKER__ ----\n"
"  window.__DSH_DIRECTORY_PICKER__ = {\n"
"    pick: function (opts) { return call('picker.pick', opts || {}); }\n"
"  };\n"
"\n"
"  // ---- __DSH_HOST_PATHS__ ----\n"
"  window.__DSH_HOST_PATHS__ = {\n"
"    pathFor: function (name) { return call('hostPaths.pathFor', { name: name }); }\n"
"  };\n"
"\n"
"  // ---- dshDesktopBoot ----\n"
"  // 网页用它上报启动结果；iOS 侧记录日志\n"
"  window.dshDesktopBoot = {\n"
"    ready: function (info) { return call('boot.ready', info || {}); },\n"
"    failed: function (info) { return call('boot.failed', info || {}); }\n"
"  };\n"
"\n"
"  // ---- dshPlatform ----\n"
"  window.dshPlatform = {\n"
"    open: function (url) { return call('platform.open', { url: url }); },\n"
"    close: function () { return call('platform.close'); },\n"
"    setBounds: function (b) { return call('platform.setBounds', b || {}); }\n"
"  };\n"
"\n"
"  // ---- dshDesktop ----\n"
"  // Electron 版暴露 app 信息（版本、平台、路径）\n"
"  window.dshDesktop = {\n"
"    app: {\n"
"      getVersion: function () { return call('desktop.getVersion'); },\n"
"      getPlatform: function () { return call('desktop.getPlatform'); },\n"
"      getPath: function (name) { return call('desktop.getPath', { name: name }); },\n"
"      quit: function () { return call('desktop.quit'); }\n"
"    }\n"
"  };\n"
"\n"
"  // ---- __DSH_LOCALE__ ----\n"
"  var localeListeners = [];\n"
"  window.__DSH_LOCALE__ = {\n"
"    read: function () { return call('locale.read'); },\n"
"    onChange: function (cb) {\n"
"      if (typeof cb === 'function') localeListeners.push(cb);\n"
"      return function () {\n"
"        var i = localeListeners.indexOf(cb);\n"
"        if (i >= 0) localeListeners.splice(i, 1);\n"
"      };\n"
"    }\n"
"  };\n"
"  window.__dshLocaleChanged = function (loc) {\n"
"    localeListeners.forEach(function (cb) { try { cb(loc); } catch (e) {} });\n"
"  };\n"
"\n"
"  // 通知网页：iOS 外壳已就绪（Electron 版是 DOMContentLoaded 后派发）\n"
"  window.__DSH_IOS_SHELL__ = true;\n"
"})();";


@implementation DSHBridge

- (WKUserScript *)userScript {
    return [[WKUserScript alloc] initWithSource:kBridgeJS
                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                forMainFrameOnly:NO];
}

- (void)attachToConfiguration:(WKWebViewConfiguration *)config {
    [config.userContentController addUserScript:[self userScript]];
    [config.userContentController addScriptMessageHandler:self
                                                     name:kDSHBridgeMessage];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kDSHBridgeMessage]) return;

    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;

    NSNumber *reqId = body[@"id"];
    NSString *method = body[@"method"];
    NSDictionary *args = body[@"args"];
    if (![reqId isKindOfClass:[NSNumber class]] || ![method isKindOfClass:[NSString class]]) return;
    if (![args isKindOfClass:[NSDictionary class]]) args = @{};

    [self dispatch:method args:args reply:^(BOOL ok, id _Nullable value, NSString *_Nullable error) {
        [self replyTo:reqId ok:ok value:value error:error];
    }];
}

#pragma mark - 方法分发

- (void)dispatch:(NSString *)method
            args:(NSDictionary *)args
           reply:(void (^)(BOOL ok, id _Nullable value, NSString *_Nullable error))reply {

    // ---- onboarding ----
    if ([method isEqualToString:@"onboarding.hasApiKey"]) {
        // iOS：检查 $DSH_HOME/.credentials.yaml 是否存在
        BOOL has = [[NSFileManager defaultManager]
                    fileExistsAtPath:[self dshHomePath:@".credentials.yaml"]];
        reply(YES, @(has), nil);
        return;
    }
    if ([method isEqualToString:@"onboarding.setActive"]) {
        reply(YES, nil, nil);
        return;
    }

    // ---- directory picker ----
    if ([method isEqualToString:@"picker.pick"]) {
        id<DSHBridgeDelegate> d = self.delegate;
        if (!d) { reply(NO, nil, @"no delegate"); return; }
        [d bridgePickDirectory:^(NSString *path) {
            if (path.length > 0) reply(YES, path, nil);
            else reply(YES, [NSNull null], nil);   // 用户取消
        }];
        return;
    }

    // ---- host paths ----
    if ([method isEqualToString:@"hostPaths.pathFor"]) {
        NSString *name = args[@"name"];
        if (![name isKindOfClass:[NSString class]]) { reply(NO, nil, @"bad name"); return; }
        NSString *p = [self hostPathFor:name];
        reply(YES, p ?: [NSNull null], nil);
        return;
    }

    // ---- boot ----
    if ([method isEqualToString:@"boot.ready"]) {
        NSLog(@"[dsh] web boot ready: %@", args);
        reply(YES, nil, nil);
        return;
    }
    if ([method isEqualToString:@"boot.failed"]) {
        NSLog(@"[dsh] web boot FAILED: %@", args);
        reply(YES, nil, nil);
        return;
    }

    // ---- platform ----
    if ([method isEqualToString:@"platform.open"]) {
        NSString *url = args[@"url"];
        if (![url isKindOfClass:[NSString class]]) { reply(NO, nil, @"bad url"); return; }
        [self.delegate bridgeOpenURL:url];
        reply(YES, nil, nil);
        return;
    }
    if ([method isEqualToString:@"platform.close"]) {
        [self.delegate bridgeClose];
        reply(YES, nil, nil);
        return;
    }
    if ([method isEqualToString:@"platform.setBounds"]) {
        // iOS 没有窗口边界概念，忽略（返回成功避免前端报错）
        reply(YES, nil, nil);
        return;
    }

    // ---- desktop ----
    if ([method isEqualToString:@"desktop.getVersion"]) {
        NSString *v = [[NSBundle mainBundle]
                       objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.0.0";
        reply(YES, v, nil);
        return;
    }
    if ([method isEqualToString:@"desktop.getPlatform"]) {
        reply(YES, @"ios", nil);
        return;
    }
    if ([method isEqualToString:@"desktop.getPath"]) {
        NSString *name = args[@"name"];
        if (![name isKindOfClass:[NSString class]]) { reply(NO, nil, @"bad name"); return; }
        reply(YES, [self hostPathFor:name] ?: [NSNull null], nil);
        return;
    }
    if ([method isEqualToString:@"desktop.quit"]) {
        reply(YES, nil, nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            exit(0);
        });
        return;
    }

    // ---- locale ----
    if ([method isEqualToString:@"locale.read"]) {
        NSString *lang = [NSLocale preferredLanguages].firstObject ?: @"en";
        reply(YES, lang, nil);
        return;
    }

    reply(NO, nil, [NSString stringWithFormat:@"unknown method: %@", method]);
}

#pragma mark - 路径解析（对应 Electron 的 app.getPath）

- (NSString *)dshHomePath:(NSString *)sub {
    NSString *home = @"/var/jb/var/mobile/.dsh";
    return sub.length ? [home stringByAppendingPathComponent:sub] : home;
}

- (nullable NSString *)hostPathFor:(NSString *)name {
    // 对应 Electron app.getPath(name) 的常用取值
    if ([name isEqualToString:@"home"])      return @"/var/mobile";
    if ([name isEqualToString:@"userData"])  return @"/var/jb/var/mobile/.dsh";
    if ([name isEqualToString:@"appData"])   return @"/var/jb/var/mobile/.dsh";
    if ([name isEqualToString:@"temp"])      return NSTemporaryDirectory();
    if ([name isEqualToString:@"documents"]) {
        return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    }
    if ([name isEqualToString:@"downloads"]) return @"/var/mobile/Downloads";
    if ([name isEqualToString:@"desktop"])   return @"/var/mobile/Desktop";
    if ([name isEqualToString:@"logs"])      return @"/var/jb/var/mobile/.dsh";
    if ([name isEqualToString:@"crashDumps"]) return @"/var/mobile/Library/Logs/CrashReporter";
    return nil;
}

#pragma mark - 回复

- (void)replyTo:(NSNumber *)reqId ok:(BOOL)ok value:(id)value error:(NSString *)error {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"id"] = reqId;
    payload[@"ok"] = @(ok);
    if (value) payload[@"value"] = value;
    if (error) payload[@"error"] = error;

    NSError *jsonErr = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonErr];
    if (!data) {
        NSLog(@"[dsh-bridge] 序列化失败: %@", jsonErr);
        return;
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    // 回注到 JS：调用 __dshBridgeReply(id, ok, value, error)
    NSString *js = [NSString stringWithFormat:
                    @"window.__dshBridgeReply && window.__dshBridgeReply(%@, %@, %@, %@);",
                    reqId,
                    ok ? @"true" : @"false",
                    [self jsLiteral:value],
                    error ? [self jsStringLiteral:error] : @"null"];

    dispatch_async(dispatch_get_main_queue(), ^{
        // 通过 WKWebView 执行（由 DSHRootVC 提供，这里用通知解耦）
        [[NSNotificationCenter defaultCenter]
         postNotificationName:@"DSHBridgeEvaluateJS"
                       object:nil
                     userInfo:@{@"js": js}];
    });
}

- (NSString *)jsLiteral:(id)value {
    if (!value || value == [NSNull null]) return @"null";
    if ([value isKindOfClass:[NSString class]]) return [self jsStringLiteral:value];
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
        if (d) return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    }
    return [self jsStringLiteral:[value description]];
}

- (NSString *)jsStringLiteral:(NSString *)s {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s] options:0 error:NULL];
    if (!d) return @"\"\"";
    NSString *arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    // arr 形如 ["..."]，去掉方括号
    return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
}

@end
