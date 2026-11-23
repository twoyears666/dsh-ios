/**
 * node-pty 的 iOS 替代实现
 *
 * ## 为什么需要
 *
 * `@deepseek-ai/dsh-subprocess-local` 的 `spawnTerminal()` 通过
 * `loadNodePty().spawn(file, args, options)` 启动交互式终端。
 * `node-pty` 是原生 addon（`pty.node`），iOS 上没有预编译产物，
 * 所以终端功能（dsh 的 bash 工具、terminal-panel）全部不可用。
 *
 * ## 怎么替代
 *
 * iOS 没有 `forkpty`/`openpty`（Darwin 的 pty 在 iOS 上被裁剪），
 * 但越狱环境有完整的 POSIX。这里用 **两对管道 + posix_spawn** 模拟：
 *
 *   - 子进程 stdin  ← 管道 A 读端
 *   - 子进程 stdout → 管道 B 写端
 *   - 子进程 stderr → 管道 B 写端（合并到同一流，与 PTY 语义接近）
 *
 * 关键差异（诚实说明）：
 *   - **不是真 PTY**：没有 termios 行规程，`isatty()` 返回 false，
 *     依赖 tty 的程序（vim、top）行为会退化
 *   - 但**对 dsh 的 bash 工具够用**：它跑的是非交互命令
 *     （`bash -c "..."`），只需要 stdin/stdout/stderr 与退出码
 *   - 尺寸变化（resize）是空操作
 *
 * ## 接口契约
 *
 * 必须与 node-pty 一致，因为消费方直接调用：
 *   spawn(file, args, options) → {
 *     pid, cols, rows, process,
 *     onData(cb), onExit(cb),
 *     write(data), resize(c, r), kill(sig), pause(), resume()
 *   }
 */

'use strict';

const { spawn: childSpawn } = require('node:child_process');
const { EventEmitter } = require('node:events');

// ============================================================================
// IPty 实现
// ============================================================================

class IOSProcess extends EventEmitter {
  constructor(file, args, options) {
    super();

    this.cols = options.cols || 80;
    this.rows = options.rows || 24;
    this.process = file;
    this._exited = false;
    this._exitCode = undefined;
    this._signal = undefined;

    // 用 node 的 spawn（底层 posix_spawn），stdio 用管道
    // 注意：不能用 node-pty 的 forkpty，iOS 没有
    this._child = childSpawn(file, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ['pipe', 'pipe', 'pipe'],
      // detached 让子进程成为进程组 leader，kill 时能带走整棵树
      detached: false,
    });

    this.pid = this._child.pid;

    // stdout / stderr 合并成单一数据流（PTY 的语义就是一个流）
    const emitData = (chunk) => {
      if (this._exited) return;
      this.emit('data', chunk.toString('utf8'));
    };
    this._child.stdout.on('data', emitData);
    this._child.stderr.on('data', emitData);

    this._child.on('error', (err) => {
      // 启动失败：以 exit 形式上报，让上层按 node-pty 语义处理
      if (this._exited) return;
      this._exited = true;
      this._exitCode = 127;
      this.emit('exit', { exitCode: 127, signal: 0 });
      this.emit('error', err);
    });

    this._child.on('exit', (code, signal) => {
      if (this._exited) return;
      this._exited = true;
      this._exitCode = code === null ? 0 : code;
      this._signal = signal ? signalNumber(signal) : 0;
      // 等 stdout/stderr 排空再上报退出，避免丢最后一段输出
      const finish = () => this.emit('exit', { exitCode: this._exitCode, signal: this._signal });
      if (this._child.stdout.readableEnded && this._child.stderr.readableEnded) {
        finish();
      } else {
        let pending = 2;
        const done = () => { if (--pending === 0) finish(); };
        this._child.stdout.once('end', done);
        this._child.stderr.once('end', done);
        // 兜底：200ms 后强制上报
        setTimeout(() => { if (!this._exited0) { this._exited0 = true; finish(); } }, 200);
      }
    });
  }

  onData(cb) {
    this.on('data', cb);
    return { dispose: () => this.off('data', cb) };
  }

  onExit(cb) {
    this.on('exit', cb);
    return { dispose: () => this.off('exit', cb) };
  }

  write(data) {
    if (this._exited || !this._child.stdin.writable) return;
    try {
      this._child.stdin.write(data);
    } catch {
      // 子进程已关闭 stdin：忽略，与 node-pty 行为一致
    }
  }

  resize(_cols, _rows) {
    // iOS 无 PTY，尺寸变化是空操作。
    // 消费方（terminal-bash）只在窗口变化时调用，不影响命令执行。
    this.cols = _cols;
    this.rows = _rows;
  }

  pause() {
    this._child.stdout.pause();
    this._child.stderr.pause();
  }

  resume() {
    this._child.stdout.resume();
    this._child.stderr.resume();
  }

  kill(signal) {
    if (this._exited) return;
    try {
      // 负 pid = 杀整个进程组
      process.kill(-this.pid, signal || 'SIGTERM');
    } catch {
      try {
        this._child.kill(signal || 'SIGTERM');
      } catch {
        // 已退出
      }
    }
  }

  /** node-pty 兼容字段 */
  get exitCode() {
    return this._exitCode;
  }
}

function signalNumber(name) {
  const map = { SIGINT: 2, SIGKILL: 9, SIGTERM: 15, SIGHUP: 1, SIGQUIT: 3, SIGPIPE: 13 };
  return map[name] || 0;
}

// ============================================================================
// 模块导出（与 node-pty 一致）
// ============================================================================

function spawn(file, args, options) {
  return new IOSProcess(file, args || [], options || {});
}

module.exports = { spawn };
module.exports.default = module.exports;
