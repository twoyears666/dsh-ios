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

// ---------------------------------------------------------------- 3. 会话压缩
// Node 22.12 之前没有 node:zlib 的 zstd 系列。用 Node 24 时原生支持，
// 无需降级；但若会话文件要与桌面端互通则保持 zstd。这里不动。
//
// 保留钩子位：若将来改用 Node 22，在此加
//   const DEFAULT_COMPRESSION = "zstd"  →  "none"

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
