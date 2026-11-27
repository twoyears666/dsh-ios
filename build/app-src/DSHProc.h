//
//  DSHProc.h
//  dsh iOS 原生外壳 —— 进程枚举
//
//  为什么需要这个：
//    越狱设备上默认没有 ps / pgrep / procps，用户手上也没有终端。
//    内核跑没跑、是不是有两个内核在抢 3080、旧版本进程有没有清掉，
//    这些光看端口是看不出来的（端口只有一个赢家）。
//
//  实现：sysctl(KERN_PROC_ALL) 直接读内核进程表，不依赖任何命令行工具。
//  越狱环境带 no-sandbox entitlement，这个调用通常可用；
//  万一被拒也只是返回空列表，不会崩。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHProc : NSObject

/// 全部进程快照：[{ pid, ppid, name, path }]，按 pid 升序。
/// path 拿不到时退化成 name（KERN_PROCARGS2 需要额外权限）。
+ (NSArray<NSDictionary<NSString *, id> *> *)allProcesses;

/// 只挑出与 dsh 相关的进程（dsh / node / DSH.app），按 pid 升序。
+ (NSArray<NSDictionary<NSString *, id> *> *)dshProcesses;

/// 人类可读的进程报告，直接丢给 UIAlertController 显示。
+ (NSString *)dshProcessReport;

@end

NS_ASSUME_NONNULL_END
