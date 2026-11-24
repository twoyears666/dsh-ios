#!/usr/bin/env node
/**
 * patch-ios.js —— 对提取后的依赖树打 iOS 适配补丁。
 *
 * 每个补丁都做「精确字符串替换 + 断言」：锚点命中不了就中止构建，
 * 绝不静默产出坏包。这是移植可维护性的关键——DSH 升级后锚点漂移会立刻暴露。
 *
 * 用法：node patch-ios.js <node_modules 目录>
 */
'use strict';
const fs = require('fs');
const path = require('path');

const NM = process.argv[2];
if (!NM || !fs.existsSync(NM)) {
  console.error('用法: node patch-ios.js <node_modules 目录>');
  process.exit(2);
}

const PATCHES = [];

// ---------------------------------------------------------------- 1. 目录选择器
// iOS 的 process.platform === "darwin"，但没有 osascript / NSOpenPanel。
// 原逻辑在 darwin 上无条件选 native 后端 → 必然失败。
PATCHES.push({
  name: '目录选择器强制 browse 后端',
  file: '@deepseek-ai/dsh-host-directory-picker-auto/lib/index.js',
  old: '\tif (facts.platform === "darwin" || facts.platform === "win32") return "native";',
  new: `\t// dsh-iOS: iOS 报 darwin 但没有 osascript/NSOpenPanel，native 后端必然失败。
\tif (facts.platform === "darwin" || facts.platform === "win32") {
\t\tconst ios = process.env.DSH_IOS === "1" || (() => {
\t\t\ttry { accessSync("/var/jb/usr/lib/dsh", constants.F_OK); return true; } catch { return false; }
\t\t})();
\t\treturn ios ? "browse" : "native";
\t}`,
  marker: 'dsh-iOS: iOS 报 darwin 但没有 osascript',
  check: 'esm',
});

// ---------------------------------------------------------------- 2. shell 路径
// iOS 没有 /bin/bash（Procursus 的 bash 在 /var/jb/usr/bin/bash）。
// terminal-bash 硬编码 DEFAULT_BASH_SHELL = "/bin/bash"，
// 不改的话终端工具直接 ENOENT。
PATCHES.push({
  name: 'shell 路径改为 iOS 实际位置',
  file: '@deepseek-ai/dsh-terminal-bash/lib/index.js',
  old: 'const DEFAULT_BASH_SHELL = "/bin/bash";',
  new: `// dsh-iOS: iOS 的 /bin/bash 不存在，用越狱环境的 bash。
// 优先 /var/jb/usr/bin/bash（Procursus），退到 /bin/sh。
const DEFAULT_BASH_SHELL = (() => {
\ttry { require("node:fs").accessSync("/var/jb/usr/bin/bash", require("node:fs").constants.X_OK); return "/var/jb/usr/bin/bash"; } catch {}
\ttry { require("node:fs").accessSync("/bin/bash", require("node:fs").constants.X_OK); return "/bin/bash"; } catch {}
\treturn "/bin/sh";
})();`,
  marker: 'dsh-iOS: iOS 的 /bin/bash 不存在',
  check: 'cjs',
});

// ---------------------------------------------------------------- 3. 会话压缩自适应
//
// 问题：dsh 默认压缩是 "zstd"。如果会话目录里已有明文 .jsonl 文件
// （旧版本 / Node 22 时代 / 从桌面端拷来的数据），会抛 encodingMismatch：
//
//   session artifact ".../session.v4.jsonl" uses .jsonl, but this backend
//   is configured for compression "zstd"
//
// 后果：workspace 服务挂掉 → session-controller / workspace-controller /
// ui-deliverables 全部 pending → 整个 UI 不可用。
//
// 抛错发生在两处：
//   1. checkRootEncoding()            —— 启动时扫根目录
//   2. findOppositeGenerationInDirectory() —— 每次按 id 找会话时
//
// 第一次只改了 1，但真实错误走的是 2（见日志栈：
//   resolveGenerationInDirectory ← findOppositeGenerationInDirectory）。
//
// 现在改 2：不再把相反格式当错误，而是**切换自身 compression 去匹配**。
// 同时保留 1 的改动，两处一致。
PATCHES.push({
  name: '会话压缩自适应（findOppositeGenerationInDirectory）',
  file: '@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js',
  old: `\t\tif (opposite.length > 0) throw this.encodingMismatch(opposite[0]);
\t\tconst latest = generations.sort((left, right) => right.version - left.version)[0];`,
  new: `\t\t// dsh-iOS: 自适应压缩，不抛 encodingMismatch。
\t\t//
\t\t// 原逻辑：目录里出现相反格式就抛错，导致 workspace 服务挂掉，
\t\t// 进而 session-controller / workspace-controller / ui-deliverables
\t\t// 全部 pending，整个 UI 不可用。
\t\t//
\t\t// 新逻辑：如果只找到相反格式（说明这个目录用的是另一种压缩），
\t\t// 切换 this.compression 并重新解析，把那些文件当作本格式的 generations。
\t\tif (opposite.length > 0 && generations.length === 0) {
\t\t\tconst flipped = this.oppositeCompression();
\t\t\tthis.compression = flipped;
\t\t\tthis.rootEncodingCheck = void 0;  // 让根检查用新格式重跑
\t\t\tthis.ctx?.logger?.info?.(
\t\t\t\t'session compression adapted to ' + flipped + ' to match existing artifacts');
\t\t\tfor (const entry of entries) {
\t\t\t\tconst version = parseGenerationLogFilename(entry.name, this.compression);
\t\t\t\tif (version !== void 0) generations.push({
\t\t\t\t\tpath: join(dir, entry.name),
\t\t\t\t\tversion
\t\t\t\t});
\t\t\t}
\t\t}
\t\tconst latest = generations.sort((left, right) => right.version - left.version)[0];`,
  marker: 'dsh-iOS: 自适应压缩，不抛 encodingMismatch',
  check: 'esm',
});

// ---------------------------------------------------------------- 执行
let ok = 0, skipped = 0, failed = 0;

for (const p of PATCHES) {
  const full = path.join(NM, p.file);
  if (!fs.existsSync(full)) {
    console.warn(`[patch] ⚠ 跳过（文件不存在）: ${p.file}`);
    skipped++;
    continue;
  }
  let src = fs.readFileSync(full, 'utf8');

  if (src.includes(p.marker)) {
    console.log(`[patch] ✓ 已打过: ${p.name}`);
    skipped++;
    continue;
  }
  if (!src.includes(p.old)) {
    console.error(`[patch] ✗ 锚点未命中: ${p.name}`);
    console.error(`        文件: ${p.file}`);
    console.error(`        期望: ${JSON.stringify(p.old.slice(0, 80))}`);
    failed++;
    continue;
  }

  src = src.replace(p.old, p.new);
  fs.writeFileSync(full, src, 'utf8');
  console.log(`[patch] ✓ 已应用: ${p.name}`);
  ok++;
}

// ---------------------------------------------------------------- 语法校验
if (failed === 0) {
  const { execFileSync } = require('child_process');
  for (const p of PATCHES) {
    const full = path.join(NM, p.file);
    if (!fs.existsSync(full)) continue;
    try {
      execFileSync(process.execPath, ['--check', full], { stdio: 'pipe' });
    } catch (e) {
      console.error(`[patch] ✗ 语法错误: ${p.file}`);
      failed++;
    }
  }
  if (failed === 0) console.log('[patch] ✓ 所有补丁语法校验通过');
}

console.log(`\n[patch] 汇总: ${ok} 应用 / ${skipped} 跳过 / ${failed} 失败`);
process.exit(failed > 0 ? 1 : 0);
