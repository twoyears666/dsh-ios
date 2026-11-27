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

#pragma mark - 内核控制（不依赖 exec）

// App 在真机上不允许 exec 任何外部程序（posix_spawn 一律 ENOENT），
// 所以控制内核只能靠「标记文件 + 信号」。这两个是信号那一半。

/// 从 pidfile 读内核 pid，读不到返回 0。
+ (pid_t)kernelPid;

/// 校验这个 pid 确实是我们的内核（按可执行路径判断）。
/// pidfile 可能过期，PID 回收后会指向别的进程 —— 杀之前必须过这一关。
+ (BOOL)isKernelPid:(pid_t)pid;

/// 找出所有「本移植版内核」进程的 pid（按可执行路径判定，不靠 pidfile）。
/// 用于起新内核前清理占用 3080 的旧实例。
+ (NSArray<NSNumber *> *)kernelPids;

/// 杀掉所有本移植版内核进程，最多等 seconds 秒。
/// @return 杀掉的进程数
+ (int)killAllKernelsWait:(NSTimeInterval)seconds;

/// 停内核：SIGTERM → 等 → SIGKILL。返回 YES 表示确认已退出。
/// 只对同 uid 的进程有效 —— 内核由 launchd 以 mobile 身份启动，App 也是 mobile。
+ (BOOL)stopKernelWait:(NSTimeInterval)seconds;

@end

NS_ASSUME_NONNULL_END
