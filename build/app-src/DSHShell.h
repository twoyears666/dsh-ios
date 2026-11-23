//
//  DSHShell.h
//  iOS 上执行外部命令（NSTask 在 iOS 不可用，用 posix_spawn）
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHShell : NSObject

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
