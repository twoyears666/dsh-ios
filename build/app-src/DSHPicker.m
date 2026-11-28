//
//  DSHPicker.m
//
#import "DSHPicker.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kMediaRoot = @"/var/mobile/Media";

#pragma mark - Media 目录浏览器

/// 在 /var/mobile/Media 里逐层选目录。
/// 自己实现而不是用系统选择器：Media 是 dsh 的数据根，用户的工作区
/// 绝大多数就在这里，直接浏览比走文件提供器快得多。
@interface DSHDirBrowser : UITableViewController
@property (nonatomic, copy) NSString *current;
@property (nonatomic, copy) void (^onPick)(NSString *_Nullable);
@property (nonatomic, strong) NSArray<NSString *> *entries;
@end

@implementation DSHDirBrowser

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.current.lastPathComponent.length ? self.current.lastPathComponent : @"Media";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"选择此文件夹"
                                        style:UIBarButtonItemStyleDone
                                       target:self action:@selector(pickHere)];
    [self reload];
}

- (void)reload {
    NSMutableArray *dirs = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:self.current error:NULL];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        NSString *full = [self.current stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) [dirs addObject:name];
    }
    [dirs sortUsingSelector:@selector(localizedStandardCompare:)];
    self.entries = dirs;
    [self.tableView reloadData];
}

- (void)cancel {
    if (self.onPick) self.onPick(nil);
}

- (void)pickHere {
    if (self.onPick) self.onPick(self.current);
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                            reuseIdentifier:@"c"];
    cell.textLabel.text = self.entries[ip.row];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    DSHDirBrowser *next = [[DSHDirBrowser alloc] initWithStyle:UITableViewStyleInsetGrouped];
    next.current = [self.current stringByAppendingPathComponent:self.entries[ip.row]];
    next.onPick = self.onPick;
    [self.navigationController pushViewController:next animated:YES];
}

@end

#pragma mark - DSHPicker

@interface DSHPicker () <UIDocumentPickerDelegate>
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, weak) WKWebView *webView;
@property (nonatomic, copy) NSString *pendingId;
@end

@implementation DSHPicker

+ (NSString *)messageName { return @"dshpick"; }

+ (NSString *)userScriptSource {
    // 只定义这一个 API。id 用于把原生结果回填到对应的 Promise。
    return @"(function(){"
            "var seq=0,pending={};"
            "window.__dshPickResolve=function(id,p){"
            "var f=pending[id];if(f){delete pending[id];f(p||null);}};"
            "window.__DSH_DIRECTORY_PICKER__={pick:function(){"
            "return new Promise(function(res){"
            "var id=String(++seq);pending[id]=res;"
            "try{window.webkit.messageHandlers.dshpick.postMessage({id:id});}"
            "catch(e){res(null);}"
            "});}};"
            "})();";
}

- (instancetype)initWithPresenter:(UIViewController *)presenter
                          webView:(WKWebView *)webView {
    if ((self = [super init])) {
        _presenter = presenter;
        _webView = webView;
    }
    return self;
}

- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
    self.pendingId = body[@"id"] ?: @"0";

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"选择工作区文件夹"
                         message:@"系统选择器可以选任意位置（如「我的 iPad」）；\nMedia 里是 dsh 的数据目录，工作区通常放这里。"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    [a addAction:[UIAlertAction actionWithTitle:@"系统文件选择器"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *_) { [self openSystemPicker]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"在 Media 里选"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *_) { [self openMediaBrowser]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消"
                                          style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *_) { [self resolve:nil]; }]];

    // iPad 上 action sheet 必须有锚点
    a.popoverPresentationController.sourceView = self.presenter.view;
    a.popoverPresentationController.sourceRect = CGRectMake(
        CGRectGetMidX(self.presenter.view.bounds),
        CGRectGetMidY(self.presenter.view.bounds), 1, 1);
    [self.presenter presentViewController:a animated:YES completion:nil];
}

- (void)openSystemPicker {
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ]];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    [self.presenter presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) { [self resolve:nil]; return; }
    // 沙盒外的目录要开安全作用域，否则子进程读不到
    [u startAccessingSecurityScopedResource];
    [self resolve:u.path];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c {
    [self resolve:nil];
}

- (void)openMediaBrowser {
    DSHDirBrowser *b = [[DSHDirBrowser alloc] initWithStyle:UITableViewStyleInsetGrouped];
    b.current = kMediaRoot;
    __weak typeof(self) weakSelf = self;
    b.onPick = ^(NSString *path) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self.presenter dismissViewControllerAnimated:YES completion:^{
            [self resolve:path];
        }];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:b];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self.presenter presentViewController:nav animated:YES completion:nil];
}

/// 把结果回填给网页里的 Promise
- (void)resolve:(nullable NSString *)path {
    NSString *id_ = self.pendingId ?: @"0";
    self.pendingId = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[ id_, path ?: [NSNull null] ]
                                                options:0 error:NULL];
    NSString *arr = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"[\"0\",null]";
    NSString *js = [NSString stringWithFormat:
        @"(function(a){window.__dshPickResolve(a[0],a[1]);})(%@)", arr];
    [self.webView evaluateJavaScript:js completionHandler:nil];
}

@end
