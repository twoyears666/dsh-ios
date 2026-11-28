//
//  DSHJIT.m
//
#import "DSHJIT.h"

#import <dlfcn.h>
#import <signal.h>
#import <errno.h>
#import <string.h>
#import <sys/types.h>

// iOS SDK 不提供 <sys/ptrace.h>，但 libsystem 里有 ptrace 的实现。
// 手动声明即可（PT_TRACE_ME = 0 是 BSD 的固定值）。
#if __has_include(<sys/ptrace.h>)
#import <sys/ptrace.h>
#else
#ifndef PT_TRACE_ME
#define PT_TRACE_ME 0
#endif
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);
#endif

// 不同越狱/不同版本暴露的库路径
static const char *kLibCandidates[] = {
    "/var/jb/usr/lib/libjailbreak.dylib",
    "/var/jb/usr/lib/libjailbreak/libjailbreak.dylib",
    "/var/jb/usr/lib/libroothide.dylib",
    "/usr/lib/libjailbreak.dylib",
    "/var/jb/basebin/libjailbreak.dylib",
};

// 不同越狱/不同版本暴露的符号名
static const char *kSymbolCandidates[] = {
    "jbclient_jit_enable",
    "jbdJITEnable",
    "jbdJITEnableProcess",
    "jbd_jit_enable",
    "jailbreakd_jit_enable",
    "enable_jit",
    "JITEnable",
    "jitEnable",
};

typedef int (*DSHJITFunc)(pid_t);

@implementation DSHJIT

+ (nullable DSHJITFunc)findFunction:(NSMutableString *)diag {
    for (size_t i = 0; i < sizeof(kLibCandidates) / sizeof(kLibCandidates[0]); i++) {
        const char *path = kLibCandidates[i];
        void *handle = dlopen(path, RTLD_NOW);
        if (handle == NULL) {
            if (diag) [diag appendFormat:@"  dlopen %s → 失败 (%s)\n", path, dlerror()];
            continue;
        }
        if (diag) [diag appendFormat:@"  dlopen %s → OK\n", path];

        for (size_t j = 0; j < sizeof(kSymbolCandidates) / sizeof(kSymbolCandidates[0]); j++) {
            const char *sym = kSymbolCandidates[j];
            void *fn = dlsym(handle, sym);
            if (fn != NULL) {
                if (diag) [diag appendFormat:@"    dlsym %s → 找到\n", sym];
                return (DSHJITFunc)fn;
            }
        }
        if (diag) [diag appendFormat:@"    这个库里没有已知的 JIT 符号\n"];
    }
    return NULL;
}

+ (BOOL)available {
    return [self findFunction:nil] != NULL;
}

+ (BOOL)enableForPid:(pid_t)pid {
    NSMutableString *diag = [NSMutableString string];

    // 1) 越狱提供的 JIT 接口
    DSHJITFunc fn = [self findFunction:diag];
    if (fn != NULL) {
        errno = 0;
        int rc = fn(pid);
        [diag appendFormat:@"  调用 jit(pid=%d) → rc=%d errno=%d (%s)\n",
             pid, rc, errno, strerror(errno)];
        NSLog(@"[dsh-jit] %@", diag);
        if (rc == 0) return YES;
    }

    // 2) 兜底：对自己用 ptrace(PT_TRACE_ME) 设 CS_DEBUGGED。
    //    只对「当前进程」有效，对子进程没用，但聊胜于无，
    //    而且能说明这台设备是否允许这条老路。
    if (pid == 0 || pid == getpid()) {
        errno = 0;
        int rc = ptrace(PT_TRACE_ME, 0, 0, 0);
        [diag appendFormat:@"  ptrace(PT_TRACE_ME) → rc=%d errno=%d (%s)\n",
             rc, errno, strerror(errno)];
        NSLog(@"[dsh-jit] %@", diag);
        return rc == 0;
    }

    NSLog(@"[dsh-jit] 无法为 pid=%d 打开 JIT\n%@", pid, diag);
    return NO;
}

+ (NSString *)diagnostics {
    NSMutableString *diag = [NSMutableString string];
    DSHJITFunc fn = [self findFunction:diag];
    if (fn == NULL) {
        [diag appendString:@"  结论：没有找到可用的 JIT 接口\n"];
    } else {
        [diag appendString:@"  结论：找到 JIT 接口，可以给子进程开 JIT\n"];
    }
    return diag;
}

@end
