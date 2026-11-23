//
//  DSHBrowserBridge.h
//  dshDesktop.browser 协议的 iOS 实现
//
//  Electron 桌面端用 <webview> 标签承载侧边栏浏览器；
//  iOS 没有 <webview>，这里做两件事：
//
//  1) 原生侧：实现 acquire / release / onOpenRequested，
//     每个 lease 对应一个真实 WKWebView（独立 WKWebsiteDataStore 分区）。
//  2) JS 侧：注入一个 <webview> 元素的 polyfill，
//     把它的方法/事件转发到原生 WKWebView。
//
//  协议契约（从 sidebar-browser/lib/client.js 反推）：
//    bridge.acquire(workspaceKey) → { lease, partition }
//    bridge.release(lease)       → Promise<void>
//    bridge.onOpenRequested(lease, cb) → unsubscribe
//
//    webview 元素事件：
//      dom-ready, did-navigate, did-navigate-in-page,
//      did-start-navigation, did-fail-load,
//      did-start-loading, did-stop-loading, page-title-updated,
//      render-process-gone, destroyed
//
//    webview 元素方法：
//      loadURL(url) → Promise, getURL(), getTitle(),
//      canGoBack(), canGoForward(), isLoading(),
//      clearHistory(), goBack(), goForward(), reload()
//
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol DSHBrowserBridgeDelegate <NSObject>
/// 原生侧请求把 URL 作为新标签打开（target=_blank 等）
- (void)browserBridgeOpenRequested:(NSString *)url lease:(NSString *)lease;
@end

@interface DSHBrowserBridge : NSObject <WKScriptMessageHandler, WKNavigationDelegate>

@property (nonatomic, weak, nullable) id<DSHBrowserBridgeDelegate> delegate;

/// 挂载到一个宿主 WKWebView（dsh 的 UI 页面）
- (void)attachToWebView:(WKWebView *)webView;

/// 清理所有 lease
- (void)disposeAll;

@end

NS_ASSUME_NONNULL_END
