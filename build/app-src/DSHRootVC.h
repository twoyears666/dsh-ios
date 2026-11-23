//
//  DSHRootVC.h
//  桌面端布局：左侧会话栏 + 右侧 WKWebView
//
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHRootVC : UIViewController

/// dsh 内核地址，默认 http://127.0.0.1:3080
@property (nonatomic, copy) NSString *baseURL;

/// 从 /var/jb/etc/dsh/dsh.env 或命令行读出的 token
@property (nonatomic, copy, nullable) NSString *authToken;

@end

NS_ASSUME_NONNULL_END
