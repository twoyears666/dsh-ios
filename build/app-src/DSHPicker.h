//
//  DSHPicker.h
//  目录选择器 —— 只提供 __DSH_DIRECTORY_PICKER__ 这一个 API。
//
//  为什么要它：
//    网页里「增加工作区」会调 window.__DSH_DIRECTORY_PICKER__.pick()。
//    最小外壳没有注入这个 API，于是点击没有反应（或者落到网页自己的兜底）。
//
//  行为（按用户要求）：
//    点击后先弹一个**选择菜单**，两个选项：
//      1) 系统文件选择器  —— UIDocumentPickerViewController（文件夹）
//      2) 在 Media 里选    —— 自带的目录浏览器，根目录 /var/mobile/Media
//    取消则返回 null。
//
//  注意：这是唯一保留的 JS bridge API，其余 6 个仍然不提供。
//
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHPicker : NSObject <WKScriptMessageHandler>

/// 注入到网页的脚本（定义 __DSH_DIRECTORY_PICKER__）
+ (NSString *)userScriptSource;

/// 消息名，需与脚本里一致
+ (NSString *)messageName;

- (instancetype)initWithPresenter:(UIViewController *)presenter
                              webView:(WKWebView *)webView;

@end

NS_ASSUME_NONNULL_END
