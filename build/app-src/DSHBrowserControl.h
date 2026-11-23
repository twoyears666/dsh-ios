//
//  DSHBrowserControl.h
//  agent ↔ App 的浏览器控制端点
//
//  dsh 内核（node 进程）和 App（UIKit）是两个独立进程，
//  agent 的工具要操作 App 里的 WKWebView，只能走 localhost。
//
//  协议：POST http://127.0.0.1:3081/browser
//        { "action": "open|snapshot|click|type|screenshot|eval", ... }
//    响应：200 + JSON
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol DSHBrowserControlDelegate <NSObject>
/// 打开 URL（新标签），返回 @{ @"tabId": ..., @"url": ..., @"title": ... }
- (NSDictionary *)controlOpenURL:(NSString *)url;
/// 取页面快照
- (NSDictionary *)controlSnapshotTab:(nullable NSString *)tabId maxChars:(NSInteger)maxChars;
/// 点击元素
- (NSDictionary *)controlClickSelector:(NSString *)selector tab:(nullable NSString *)tabId;
/// 输入文本
- (NSDictionary *)controlTypeSelector:(NSString *)selector
                                 text:(NSString *)text
                               submit:(BOOL)submit
                                  tab:(nullable NSString *)tabId;
/// 截图（base64 PNG）
- (NSDictionary *)controlScreenshotTab:(nullable NSString *)tabId;
/// 执行 JS
- (NSDictionary *)controlEvalExpression:(NSString *)expression tab:(nullable NSString *)tabId;
@end

@interface DSHBrowserControl : NSObject

@property (nonatomic, weak, nullable) id<DSHBrowserControlDelegate> delegate;

/// 启动监听（默认 127.0.0.1:3081）
- (BOOL)startOnPort:(uint16_t)port;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
