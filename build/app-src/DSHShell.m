//
//  DSHShell.m
//
#import "DSHShell.h"
#import <spawn.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>

extern char **environ;

@implementation DSHShell

+ (NSString *)run:(NSString *)path
             args:(NSArray<NSString *> *)args
          timeout:(NSTimeInterval)timeout {
    __block NSString *result = @"";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [self runAsync:path args:args timeout:timeout completion:^(NSString *output, int status) {
        result = output ?: @"";
        dispatch_semaphore_signal(sem);
    }];

    // 超时额外宽限 2 秒，避免死等
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)((timeout > 0 ? timeout + 2 : 30) * NSEC_PER_SEC)));
    return result;
}

+ (void)runAsync:(NSString *)path
            args:(NSArray<NSString *> *)args
         timeout:(NSTimeInterval)timeout
      completion:(void (^)(NSString *, int))completion {

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int pipefd[2];
        if (pipe(pipefd) != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@"pipe() failed", -1); });
            return;
        }

        // argv[0] 必须是可执行路径
        NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:path];
        if (args) [argv addObjectsFromArray:args];

        // 转成 C 数组
        NSUInteger n = argv.count;
        char **cargv = calloc(n + 1, sizeof(char *));
        for (NSUInteger i = 0; i < n; i++) {
            cargv[i] = strdup(argv[i].UTF8String);
        }
        cargv[n] = NULL;

        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        // 把 stdout/stderr 都接到管道写端
        posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, pipefd[0]);
        posix_spawn_file_actions_addclose(&actions, pipefd[1]);

        pid_t pid = 0;
        int rc = posix_spawn(&pid, path.UTF8String, &actions, NULL, cargv, environ);

        posix_spawn_file_actions_destroy(&actions);
        for (NSUInteger i = 0; i < n; i++) free(cargv[i]);
        free(cargv);

        close(pipefd[1]);

        if (rc != 0) {
            close(pipefd[0]);
            NSString *msg = [NSString stringWithFormat:@"posix_spawn 失败 (%d): %s",
                             rc, strerror(rc)];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(msg, -1); });
            return;
        }

        // 读输出
        NSMutableData *buf = [NSMutableData data];
        char chunk[4096];
        ssize_t got;
        while ((got = read(pipefd[0], chunk, sizeof(chunk))) > 0) {
            [buf appendBytes:chunk length:(NSUInteger)got];
        }
        close(pipefd[0]);

        // 超时控制：先给宽限，再强杀
        int status = 0;
        BOOL reaped = NO;
        if (timeout > 0) {
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
            while ([deadline timeIntervalSinceNow] > 0) {
                pid_t r = waitpid(pid, &status, WNOHANG);
                if (r == pid) { reaped = YES; break; }
                usleep(50 * 1000);
            }
            if (!reaped) {
                kill(pid, SIGKILL);
                waitpid(pid, &status, 0);
                reaped = YES;
            }
        }
        if (!reaped) {
            waitpid(pid, &status, 0);
        }

        NSString *out = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
        if (!out) out = [[NSString alloc] initWithData:buf encoding:NSISOLatin1StringEncoding];
        int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(out ?: @"", exitCode);
        });
    });
}

@end
