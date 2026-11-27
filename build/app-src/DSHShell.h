//
//  DSHShell.h
//  iOS 上执行外部命令（NSTask 在 iOS 不可用，用 posix_spawn）
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHShell : NSObject

/// 以完全脱离的方式启动一个长期进程（不随 App 挂起被杀）。
///
/// 关键点：
///   - posix_spawn + POSIX_SPAWN_SETSID：新会话，脱离 App 的进程组
///   - 输出重定向到日志文件（不占管道）
///   - 立即返回，不等子进程结束
///
/// @param path 可执行文件
/// @param args 参数（不含 argv[0]）
/// @param logPath 输出日志路径
/// @param pidOut 返回子进程 pid（可为 NULL）
/// @return 0 成功，非 0 是 posix_spawn 错误码
+ (int)spawnDetached:(NSString *)path
                args:(nullable NSArray<NSString *> *)args
             logPath:(nullable NSString *)logPath
                 pid:(nullable pid_t *)pidOut;

/// 同上，但可指定额外环境变量（覆盖/追加到当前 environ）。
/// iOS App 的 PATH 里没有 /var/jb/usr/bin，直接 spawn 会导致
/// 脚本里的 mkdir/tail/nc 等命令找不到。
+ (int)spawnDetached:(NSString *)path
                args:(nullable NSArray<NSString *> *)args
             logPath:(nullable NSString *)logPath
                 env:(nullable NSDictionary<NSString *, NSString *> *)extraEnv
                 pid:(nullable pid_t *)pidOut;

/// 同步执行命令，返回合并的 stdout+stderr。
/// @param path 可执行文件绝对路径（如 /var/jb/usr/bin/dsh-doctor）
/// @param args 参数数组（不含 argv[0]）
/// @param timeout 超时秒数（<=0 表示不限）
+ (NSString *)run:(NSString *)path
             args:(nullable NSArray<NSString *> *)args
          timeout:(NSTimeInterval)timeout;

/// 异步执行，完成回调在主队列。
+ (void)runAsync:(NSString *)path
            args:(nullable NSArray<NSString *> *)args
         timeout:(NSTimeInterval)timeout
      completion:(void (^)(NSString *output, int status))completion;

/// 越狱根候选（按优先级）：/var/jb，以及从自身 bundle 反推出来的真实 preboot 路径。
/// iOS App 有沙盒扩展，通常只对自己 bundle 有特权；
/// /var/jb 是指向 /private/preboot/... 的符号链接，某些设备上 App 进程
/// 解析不到（posix_spawn 直接返回 ENOENT）。所以要能换条路走。
+ (NSArray<NSString *> *)jailbreakRootCandidates;

/// 在越狱根候选下找 relative（如 "usr/bin/dsh"），找到返回绝对路径。
/// @param diagnostics 非空时把每个候选的探测结果追加进去，便于写日志排查。
+ (nullable NSString *)resolveJailbreakPath:(NSString *)relative
                                diagnostics:(NSMutableString *_Nullable)diagnostics;

/// /var/jb 的解析情况、bundle 路径、launchctl 是否可用 —— 一行行文本，直接进 app.log。
+ (NSString *)jailbreakEnvironmentReport;

@end

NS_ASSUME_NONNULL_END
