//
//  DSHMenu.m
//
#import "DSHMenu.h"

@implementation DSHMenu

- (UIAction *)action:(NSString *)title
               image:(NSString *)symbol
                act:(DSHMenuAction)a
           disabled:(BOOL)disabled {
    __weak typeof(self) weakSelf = self;
    UIAction *act = [UIAction actionWithTitle:title
                                       image:[UIImage systemImageNamed:symbol]
                                  identifier:nil
                                     handler:^(__kindof UIAction *_) {
        [weakSelf.delegate menuDidSelect:a];
    }];
    act.attributes = disabled ? UIMenuElementAttributesDisabled : 0;
    return act;
}

- (UIMenu *)buildMainMenu {
    // 兼容旧调用：默认按「运行中 + 保活开启」
    return [self buildMainMenuRunning:YES keepAlive:YES];
}

- (UIMenu *)buildMainMenuRunning:(BOOL)running keepAlive:(BOOL)keepAlive {
    UIMenu *session = [UIMenu menuWithTitle:@"会话"
                                     image:[UIImage systemImageNamed:@"bubble.left.and.bubble.right"]
                                identifier:nil
                                   options:UIMenuOptionsDisplayInline
                                  children:@[
        // 会话相关操作全部交给 web UI（它自己就有侧边栏和会话列表），
        // 原生菜单只留「新会话」这一个常用入口。
        [self action:@"新会话" image:@"plus.bubble" act:DSHMenuActionNewSession disabled:NO],
    ]];

    UIMenu *view = [UIMenu menuWithTitle:@"视图"
                                   image:[UIImage systemImageNamed:@"eye"]
                              identifier:nil
                                 options:UIMenuOptionsDisplayInline
                                children:@[
        [self action:@"重新加载" image:@"arrow.clockwise" act:DSHMenuActionReload disabled:NO],
        [self action:@"在 Safari 打开" image:@"safari" act:DSHMenuActionOpenInSafari disabled:NO],
        [self action:@"复制 URL" image:@"doc.on.doc" act:DSHMenuActionCopyURL disabled:NO],
        // 语音输入：mac 桌面端走 sherpa-onnx，iOS 没有产物，
        // 这里用系统 SFSpeechRecognizer（不占体积、中文可用）
        [self action:@"语音输入" image:@"mic" act:DSHMenuActionVoice disabled:NO],
        // V8 启动档位：默认是设备探测出来的（通常是 nowasm / --jitless）
        [self action:@"V8 启动档位" image:@"speedometer" act:DSHMenuActionTier disabled:NO],
    ]];

    UIMenu *system = [UIMenu menuWithTitle:@"内核"
                                    image:[UIImage systemImageNamed:@"gearshape.2"]
                               identifier:nil
                                  options:UIMenuOptionsDisplayInline
                                 children:@[
        // 启动 / 停止：按当前状态只显示可用的那个
        running
            ? [self action:@"停止内核" image:@"stop.circle" act:DSHMenuActionStopKernel disabled:NO]
            : [self action:@"启动内核" image:@"play.circle" act:DSHMenuActionStartKernel disabled:NO],
        [self action:@"重启内核" image:@"arrow.triangle.2.circlepath" act:DSHMenuActionRestartKernel disabled:NO],
        // 保活开关：标题随状态变化
        [self action:(keepAlive ? @"关闭后台保活" : @"开启后台保活")
                image:(keepAlive ? @"moon.zzz" : @"bolt.circle")
                  act:DSHMenuActionToggleKeepAlive
             disabled:NO],
        [self action:@"运行自检" image:@"stethoscope" act:DSHMenuActionDoctor disabled:NO],
        // 清除进程：比「停止内核」更狠，用于旧版本内核占着端口的情况
        [self action:@"清除进程" image:@"xmark.bin" act:DSHMenuActionClearProcess disabled:NO],
        // 进程列表：设备上没有 ps，走 sysctl 原生枚举
        [self action:@"进程列表" image:@"list.bullet.rectangle" act:DSHMenuActionProcessList disabled:NO],
        [self action:@"设置" image:@"gearshape" act:DSHMenuActionSettings disabled:NO],
    ]];

    UIMenu *about = [UIMenu menuWithTitle:@""
                                   image:nil
                              identifier:nil
                                 options:UIMenuOptionsDisplayInline
                                children:@[
        [self action:@"关于" image:@"info.circle" act:DSHMenuActionAbout disabled:NO],
    ]];

    return [UIMenu menuWithTitle:@"" children:@[session, view, system, about]];
}

- (UIMenu *)buildContextMenuForSession:(NSString *)sessionName {
    __weak typeof(self) weakSelf = self;
    UIAction *open = [UIAction actionWithTitle:@"打开"
                                        image:[UIImage systemImageNamed:@"arrow.up.forward.app"]
                                   identifier:nil
                                      handler:^(__kindof UIAction *_) {
        [weakSelf.delegate menuDidSelect:DSHMenuActionReload];
    }];
    return [UIMenu menuWithTitle:sessionName ?: @"" children:@[open]];
}

@end
