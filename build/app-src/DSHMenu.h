//
//  DSHMenu.h
//  还原 Electron 的菜单栏（main.js 里 123 处 Menu 引用）
//
//  Electron 用原生 macOS 菜单栏；iOS 上等价物是：
//    - 右侧导航栏的"更多"按钮 → UIMenu（下拉菜单）
//    - 长按上下文菜单 → UIContextMenu
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 菜单动作标识
typedef NS_ENUM(NSInteger, DSHMenuAction) {
    DSHMenuActionNewSession,
    DSHMenuActionReload,
    DSHMenuActionOpenInSafari,
    DSHMenuActionCopyURL,
    DSHMenuActionShowSessions,
    DSHMenuActionSettings,
    DSHMenuActionDoctor,
    DSHMenuActionRestartKernel,
    DSHMenuActionStartKernel,
    DSHMenuActionStopKernel,
    DSHMenuActionToggleKeepAlive,
    DSHMenuActionClearProcess,
    DSHMenuActionAbout,
};

@protocol DSHMenuDelegate <NSObject>
- (void)menuDidSelect:(DSHMenuAction)action;
@end

@interface DSHMenu : NSObject

@property (nonatomic, weak, nullable) id<DSHMenuDelegate> delegate;

/// 构造右侧导航栏的"更多"菜单
/// @param running   内核是否在跑
/// @param keepAlive 保活是否开启
- (UIMenu *)buildMainMenuRunning:(BOOL)running keepAlive:(BOOL)keepAlive;
/// 构造会话单元格的上下文菜单
- (UIMenu *)buildContextMenuForSession:(NSString *)sessionName;

@end

NS_ASSUME_NONNULL_END
