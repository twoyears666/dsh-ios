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

@end

NS_ASSUME_NONNULL_END
