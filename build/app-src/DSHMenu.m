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
    UIMenu *session = [UIMenu menuWithTitle:@"会话"
                                     image:[UIImage systemImageNamed:@"bubble.left.and.bubble.right"]
                                identifier:nil
                                   options:UIMenuOptionsDisplayInline
                                  children:@[
        [self action:@"新会话" image:@"plus.bubble" act:DSHMenuActionNewSession disabled:NO],
        [self action:@"会话列表" image:@"list.bullet" act:DSHMenuActionShowSessions disabled:NO],
    ]];

    UIMenu *view = [UIMenu menuWithTitle:@"视图"
                                   image:[UIImage systemImageNamed:@"eye"]
                              identifier:nil
                                 options:UIMenuOptionsDisplayInline
                                children:@[
        [self action:@"重新加载" image:@"arrow.clockwise" act:DSHMenuActionReload disabled:NO],
        [self action:@"在 Safari 打开" image:@"safari" act:DSHMenuActionOpenInSafari disabled:NO],
        [self action:@"复制 URL" image:@"doc.on.doc" act:DSHMenuActionCopyURL disabled:NO],
    ]];

    UIMenu *system = [UIMenu menuWithTitle:@"内核"
                                    image:[UIImage systemImageNamed:@"gearshape.2"]
                               identifier:nil
                                  options:UIMenuOptionsDisplayInline
                                 children:@[
        [self action:@"重启内核" image:@"arrow.triangle.2.circlepath" act:DSHMenuActionRestartKernel disabled:NO],
        [self action:@"运行自检" image:@"stethoscope" act:DSHMenuActionDoctor disabled:NO],
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
