//
//  DSHProc.m
//
#import "DSHProc.h"

#import <sys/sysctl.h>
#import <sys/types.h>
#import <string.h>
#import <stdlib.h>

@implementation DSHProc

/// 读某个进程的可执行路径（KERN_PROCARGS2）。
///
/// 越狱环境通常允许，但被拒也不算异常 —— 拿不到就返回 nil，
/// 上层退化成显示 comm。绝不因为查不到路径就崩掉整个列表。
static NSString *DSHExecutablePath(pid_t pid) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) return nil;

    char *buf = malloc(size);
    if (!buf) return nil;
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) {
        free(buf);
        return nil;
    }

    // 布局：[int argc][exec_path\0][若干 \0 填充][argv...]
    int argc = 0;
    if (size < sizeof(argc)) { free(buf); return nil; }
    memcpy(&argc, buf, sizeof(argc));

    char *p = buf + sizeof(argc);
    char *end = buf + size;
    while (p < end && *p == '\0') p++;
    NSString *path = (p < end) ? [NSString stringWithUTF8String:p] : nil;

    free(buf);
    return path.length > 0 ? path : nil;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)allProcesses {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return @[];

    // 两次 sysctl 之间进程数会变，多要 20% 余量，避免 ENOMEM 直接失败
    size = size + size / 5 + 1024;
    void *buf = malloc(size);
    if (!buf) return @[];
    if (sysctl(mib, 4, buf, &size, NULL, 0) != 0) {
        free(buf);
        return @[];
    }

    size_t count = size / sizeof(struct kinfo_proc);
    struct kinfo_proc *procs = (struct kinfo_proc *)buf;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];

    for (size_t i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 0) continue;

        char comm[MAXCOMLEN + 1] = { 0 };
        strlcpy(comm, procs[i].kp_proc.p_comm, sizeof(comm));
        NSString *name = [NSString stringWithUTF8String:comm] ?: @"?";

        [out addObject:@{
            @"pid":  @(pid),
            @"ppid": @(procs[i].kp_eproc.e_ppid),
            @"name": name,
            @"path": DSHExecutablePath(pid) ?: @"",
        }];
    }

    free(buf);
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"pid"] compare:b[@"pid"]];
    }];
}

+ (NSArray<NSDictionary<NSString *, id> *> *)dshProcesses {
    NSArray *all = [self allProcesses];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in all) {
        NSString *name = p[@"name"] ?: @"";
        NSString *path = p[@"path"] ?: @"";
        BOOL hit = [name isEqualToString:@"node"]
                || [name isEqualToString:@"DSH"]
                || [name isEqualToString:@"dsh"]
                || [name hasPrefix:@"dsh"]
                || [path containsString:@"/dsh/"]
                || [path containsString:@"DSH.app"]
                || [path containsString:@"/var/jb/usr/bin/dsh"];
        if (hit) [out addObject:p];
    }
    return out;
}

+ (NSString *)dshProcessReport {
    NSArray *all = [self allProcesses];
    if (all.count == 0) {
        return @"读不到进程表（sysctl 被拒）。\n"
                "可以用 dsh-ctl status 看内核和端口状态。";
    }

    NSArray *list = [self dshProcesses];
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"系统共 %lu 个进程，其中 dsh 相关 %lu 个\n\n",
        (unsigned long)all.count, (unsigned long)list.count];

    if (list.count == 0) {
        [s appendString:@"没有 dsh 相关进程。\n内核没在跑（或者刚被清除）。"];
        return s;
    }

    for (NSDictionary *p in list) {
        NSString *show = p[@"path"];
        if (show.length == 0) show = p[@"name"] ?: @"?";
        // 路径太长，只留最后两段，否则一屏放不下
        NSArray *parts = [show componentsSeparatedByString:@"/"];
        if (parts.count > 3) {
            show = [NSString stringWithFormat:@"…/%@/%@",
                    parts[parts.count - 2], parts[parts.count - 1]];
        }
        [s appendFormat:@"pid %-6d ppid %-6d  %@\n",
            [p[@"pid"] intValue], [p[@"ppid"] intValue], show];
    }
    return s;
}

#pragma mark - 内核控制

static NSString *const kKernelPidFile = @"/var/mobile/Media/deepseek-harness/config/kernel.pid";

+ (pid_t)kernelPid {
    NSString *raw = [NSString stringWithContentsOfFile:kKernelPidFile
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (raw.length == 0) return 0;
    long pid = strtol(raw.UTF8String, NULL, 10);
    return (pid > 0 && pid < 1000000) ? (pid_t)pid : 0;
}

+ (BOOL)stopKernelWait:(NSTimeInterval)seconds {
    pid_t pid = [self kernelPid];
    if (pid <= 0) {
        // 没有 pidfile 也可能是内核在跑（旧版本没写），交给调用方用端口判断
        return YES;
    }
    if (kill(pid, 0) != 0) {
        // 已经不在
        [[NSFileManager defaultManager] removeItemAtPath:kKernelPidFile error:NULL];
        return YES;
    }

    kill(pid, SIGTERM);

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0) {
        if (kill(pid, 0) != 0) {
            [[NSFileManager defaultManager] removeItemAtPath:kKernelPidFile error:NULL];
            return YES;
        }
        usleep(200 * 1000);
    }

    kill(pid, SIGKILL);
    usleep(500 * 1000);
    BOOL gone = (kill(pid, 0) != 0);
    if (gone) [[NSFileManager defaultManager] removeItemAtPath:kKernelPidFile error:NULL];
    return gone;
}

@end
