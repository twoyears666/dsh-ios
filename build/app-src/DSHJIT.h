//
//  DSHJIT.h
//  向越狱请求 JIT
//
//  为什么需要它：
//    iOS 14+ 起，JIT 需要进程带 CS_DEBUGGED 标志。App 自己带
//    dynamic-codesigning / allow-jit entitlement 还不够 ——
//    真正跑 JIT 的**子进程**（我们 spawn 出来的 node）是全新进程，
//    它既没有 CS_DEBUGGED，也没向越狱请求过 JIT，于是 V8 一开 JIT
//    就崩，只能退到 --jitless。
//
//  越狱环境里正确的做法是调 libjailbreak 的 JIT 接口，对目标 pid
//  打开 JIT。Dopamine / roothide / palera1n 暴露的符号名不完全一样，
//  所以这里做「多路径 dlopen + 多符号 dlsym」，找到哪个用哪个，
//  并且把探测结果写进日志。
//
#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHJIT : NSObject

/// 对指定 pid 请求 JIT。成功返回 YES。
/// @param pid 目标进程；传 0 表示「对自己」
+ (BOOL)enableForPid:(pid_t)pid;

/// 探测结果（人类可读），用于写进 app.log：
/// 加载到哪个库、命中哪个符号、调用返回什么。
+ (NSString *)diagnostics;

/// 是否至少找到了一个可用的 JIT 接口
+ (BOOL)available;

@end

NS_ASSUME_NONNULL_END
