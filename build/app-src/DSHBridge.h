//
//  DSHBridge.h
//  Electron 外壳的 iOS 等价实现
//
//  Electron 版通过 contextBridge.exposeInMainWorld 向网页暴露 7 个 API：
//    dshOnboarding          { hasApiKey, setActive }
//    __DSH_DIRECTORY_PICKER__ { pick }
//    __DSH_HOST_PATHS__     { pathFor }
//    dshDesktopBoot         { ready, failed }
//    dshPlatform            { open, close, setBounds }
//    dshDesktop             { app }
//    __DSH_LOCALE__         { read, onChange }
//
//  本类用 WKUserContentController 注入等价实现，让同一份 web 前端
//  在 iOS 上无需改动即可工作。
//
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 桥接消息名（JS → Native）
extern NSString *const kDSHBridgeMessage;

@protocol DSHBridgeDelegate <NSObject>
/// 原生侧请求打开外部链接
- (void)bridgeOpenURL:(NSString *)url;
/// 原生侧请求关闭（最小化）窗口
- (void)bridgeClose;
/// 目录选择器：返回选中路径，取消返回 nil
- (void)bridgePickDirectory:(void (^)(NSString *_Nullable path))completion;
@end

@interface DSHBridge : NSObject <WKScriptMessageHandler>

@property (nonatomic, weak, nullable) id<DSHBridgeDelegate> delegate;

/// 构造注入脚本（在页面加载前注入到 WKWebView）
- (WKUserScript *)userScript;

/// 注册到 WKWebView 的 configuration
- (void)attachToConfiguration:(WKWebViewConfiguration *)config;

@end

NS_ASSUME_NONNULL_END
