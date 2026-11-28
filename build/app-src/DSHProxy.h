//
//  DSHProxy.h
//  dsh:// 自定义 scheme 代理
//
//  为什么需要它：
//    真机上 WKWebView 加载 http://127.0.0.1:3080/ 时**连响应头都收不到**
//    （没有 didFinish、没有 didFail、没有 HTTP 状态），而同一个进程里用
//    NSURLSession 请求是正常的。说明 WebKit 自己的网络进程访问不了回环地址。
//
//  解法：不让 WebKit 去发请求。页面从 dsh://app/ 加载，所有子资源请求
//  都进到我们的 WKURLSchemeHandler，由 App 用 NSURLSession 转发到
//  127.0.0.1:3080 —— 走的是 App 进程的网络栈，绕开 WebKit 那套。
//
//  前端用的是相对路径（./assets/...），所以只要 base 是 dsh://app/，
//  所有资源都会自动走这里，不需要改前端。
//
//  已知限制：WKURLSchemeHandler 不支持 WebSocket。
//  如果页面靠 WS 推流，聊天流会不工作 —— 到时候再单独走原生。
//
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHProxy : NSObject <WKURLSchemeHandler>

/// scheme 名（dsh）
+ (NSString *)scheme;

/// 页面入口 URL（dsh://app/）
+ (NSURL *)entryURL;

/// 转发目标端口，默认 3080
@property (nonatomic, assign) NSInteger port;

@end

NS_ASSUME_NONNULL_END
