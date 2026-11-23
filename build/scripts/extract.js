#!/usr/bin/env node
/**
 * extract.js —— 从 mac 版 app.asar 提取 iOS 可移植的 dsh 依赖树。
 *
 * 原则（依据调研结论）：
 *   保留：纯 JS/JSON/资源文件（.js/.mjs/.cjs/.json/.wasm/.webp/.svg/...）
 *   剔除：macOS/iOS 平台专属二进制、macOS .app、dylib、darwin-* 预编译包
 *   替换：node-addon-system/lib/flock.js 与 node-addon-require-builtin/lib/index.js
 *         换成纯 JS shim
 *   裁剪：.d.ts/.map/.md/.ts/.tsx 等开发期文件（省 ~50 MB）
 *
 * 用法：
 *   node extract.js <app.asar> <out-dir> [--keep-dev] [--keep-libreoffice]
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ASAR = process.argv[2];
const OUT = process.argv[3];
const KEEP_DEV = process.argv.includes('--keep-dev');
const KEEP_LO = process.argv.includes('--keep-libreoffice');

if (!ASAR || !OUT) {
  console.error('用法: node extract.js <app.asar> <out-dir> [--keep-dev] [--keep-libreoffice]');
  process.exit(2);
}

// ---- 1. 读 asar 头 ----
const fd = fs.openSync(ASAR, 'r');
const hb16 = Buffer.alloc(16);
fs.readSync(fd, hb16, 0, 16, 0);
const headerSize = hb16.readUInt32LE(12);
const hb = Buffer.alloc(headerSize);
fs.readSync(fd, hb, 0, headerSize, 16);
const HDR = JSON.parse(hb.toString('utf8').replace(/\0+$/, ''));
const DATA_OFFSET = 16 + headerSize;
const FILE_TOTAL = fs.fstatSync(fd).size;

function readFile(relPath) {
  let node = HDR;
  for (const seg of relPath.split('/').filter(Boolean)) {
    if (!node.files || !node.files[seg]) return null;
    node = node.files[seg];
  }
  if (!node || node.offset === undefined) return null;
  const off = DATA_OFFSET + Number(node.offset);
  if (off + node.size > FILE_TOTAL) return null;
  const buf = Buffer.alloc(node.size);
  fs.readSync(fd, buf, 0, node.size, off);
  return buf;
}

// ---- 2. 平台包剔除规则 ----
// 这些包只含 macOS/Windows/Linux 预编译产物，iOS 上永不使用
const DROP_PACKAGES = new Set([
  '@img/sharp-darwin-arm64',
  '@img/sharp-darwin-x64',
  '@img/sharp-libvips-darwin-arm64',
  '@img/sharp-libvips-darwin-x64',
  '@koromix/koffi-darwin-arm64',
  '@koromix/koffi-darwin-x64',
  '@vscode/ripgrep-darwin-arm64',
  '@vscode/ripgrep-darwin-x64',
  'sherpa-onnx-darwin-arm64',
  'sherpa-onnx-node',
  'node-pty',
  '@deepseek-ai/libreoffice-kit-darwin-arm64',
  '@deepseek-ai/node-addon-system-darwin-arm64',
  '@deepseek-ai/node-addon-system-darwin-x64',
  'node-addon-require-builtin-darwin-arm64',
  'node-addon-require-builtin-darwin-x64',
  // 桌面专属
  '@deepseek-ai/dsh-desktop-host',
  '@deepseek-ai/dsh-experimental-cua-macos',
  '@deepseek-ai/dsh-cua-bundle',
]);
if (!KEEP_LO) {
  DROP_PACKAGES.add('@deepseek-ai/libreoffice-kit-darwin-arm64');
}

// 需要保留但内容要过滤的包（剔除其中的二进制，保留 JS）
const FILTER_BINARY_IN = new Set([
  '@deepseek-ai/libreoffice-kit',
  '@deepseek-ai/dsh-cua',
  '@deepseek-ai/dsh-computer-use',
]);

// ---- 3. 扩展名规则 ----
const DROP_EXT_DEV = new Set(['.ts', '.tsx', '.cts', '.mts', '.map']);
const DROP_NAMES = new Set(['.DS_Store', 'Thumbs.db']);
const DROP_EXT_BIN = new Set(['.dylib', '.so', '.dll', '.a', '.lib', '.o', '.node']);

function isDevFile(name) {
  if (DROP_EXT_DEV.has(path.extname(name).toLowerCase())) return true;
  const lower = name.toLowerCase();
  if (lower.endsWith('.d.ts') || lower.endsWith('.d.cts') || lower.endsWith('.d.mts')) return true;
  if (lower === 'readme.md' || lower.startsWith('changelog') || lower.endsWith('.md')) return true;
  return false;
}

// 解析包名（含 scope）
function pkgOf(relFromDsh) {
  const parts = relFromDsh.split('/');
  // relFromDsh 形如 node_modules/@scope/name/...
  if (parts[0] !== 'node_modules') return null;
  if (parts[1] && parts[1].startsWith('@')) return parts[1] + '/' + parts[2];
  return parts[1];
}

// ---- 4. 遍历 ----
const stats = {
  written: 0, bytes: 0,
  skippedDev: 0, skippedDevBytes: 0,
  skippedBin: 0, skippedBinBytes: 0,
  skippedPkg: 0, skippedPkgBytes: 0,
  replaced: [],
};
const writtenPaths = [];

function mkdirp(p) { fs.mkdirSync(p, { recursive: true }); }

function walk(node, rel) {
  // rel 相对于 dsh/ 根
  if (node.files) {
    for (const k of Object.keys(node.files)) {
      walk(node.files[k], rel ? rel + '/' + k : k);
    }
    return;
  }
  if (node.link) return; // 符号链接暂不处理

  const pkg = pkgOf(rel);
  if (pkg && DROP_PACKAGES.has(pkg)) {
    stats.skippedPkg++; stats.skippedPkgBytes += node.size || 0;
    return;
  }

  const base = path.basename(rel);
  if (DROP_NAMES.has(base)) { stats.skippedBin++; stats.skippedBinBytes += node.size || 0; return; }

  const ext = path.extname(base).toLowerCase();
  if (DROP_EXT_BIN.has(ext)) {
    // 例外：libreoffice-kit 的 frame-forwarding 是 darwin 原生，iOS 无用
    stats.skippedBin++; stats.skippedBinBytes += node.size || 0;
    return;
  }
  // macOS .app 目录内的二进制（无扩展名但含 Mach-O）
  if (rel.includes('.app/Contents/MacOS/') || rel.endsWith('spawn-helper') || rel.endsWith('xdg-open')) {
    stats.skippedBin++; stats.skippedBinBytes += node.size || 0;
    return;
  }

  if (!KEEP_DEV && isDevFile(base)) {
    stats.skippedDev++; stats.skippedDevBytes += node.size || 0;
    return;
  }

  // 大文件保护：dsoffice 等
  if (base === 'dsoffice' || base === 'rg' || base === 'rg.exe') {
    stats.skippedBin++; stats.skippedBinBytes += node.size || 0;
    return;
  }

  const buf = readFile('dsh/' + rel);
  if (buf === null) { stats.skippedBin++; return; }

  const dest = path.join(OUT, rel);
  mkdirp(path.dirname(dest));
  fs.writeFileSync(dest, buf);
  // 保留可执行位（脚本类）
  if (base.endsWith('.sh') || base === 'node') fs.chmodSync(dest, 0o755);
  stats.written++;
  stats.bytes += buf.length;
  writtenPaths.push(rel);
}

// 只处理 dsh/ 子树
if (!HDR.files.dsh) { console.error('asar 里没有 dsh/ 子树'); process.exit(1); }
mkdirp(OUT);
walk(HDR.files.dsh, '');

// ---- 5. 打补丁：两个纯 JS shim ----
const SHIMS = {
  '@deepseek-ai/node-addon-system/lib/flock.js': `// dsh-iOS shim —— 覆盖 @deepseek-ai/node-addon-system/lib/flock.js
//
// 原实现在首次 session 持久化时加载 per-platform 原生 .node 调用 POSIX flock。
// iOS arm64 无对应产物，headless profile 会报
//   "Cannot find module '@deepseek-ai/node-addon-system-linux-x64/package.json'"。
//
// 单实例终端场景下不存在多进程争抢同一个 session 文件，锁恒成功即等价语义。
export async function tryLockExclusive(_fd) { return; }
export async function tryLockShared(_fd) { return; }
`,
  'node-addon-require-builtin/lib/index.js': `"use strict";
// dsh-iOS shim —— 覆盖 node_modules/node-addon-require-builtin/lib/index.js
//
// 原实现通过 node-addon-native-custom-loader 加载一个 per-platform 原生 .node，
// 用来 require() Node 的私有内部模块（internal/modules/*）。
// iOS arm64 没有对应的预编译产物，dsh-app-boot 会在 host preparation 阶段直接抛错。
//
// Node 自带的 --expose-internals 可以让普通 createRequire() 直接加载这些内部模块，
// 因此这里用纯 JS 等价实现三个导出函数。启动脚本 /var/jb/usr/bin/dsh 已带该参数。
const { createRequire } = require("node:module");
const _req = createRequire(__filename);

function requireBuiltin(moduleId) {
    return _req(moduleId);
}

function isAllowedInternalId(moduleId) {
    return typeof moduleId === "string" &&
        (moduleId.startsWith("internal/") || moduleId.startsWith("node:internal/"));
}

function getBindingInfo() {
    return Object.freeze({
        mode: "expose-internals",
        product: "dsh-ios-shim",
        backend: "js",
        abi: String(process.versions.modules),
        bindingPath: __filename,
        bindingSource: "shim",
        localBindingPath: "",
        optionalPackageName: "",
        optionalBinaryRelativePath: "",
        platformPackageSuffix: ""
    });
}

const api = { requireBuiltin, isAllowedInternalId, getBindingInfo };
module.exports = Object.assign(api, { __esModule: true, default: api });
`,
};

// 需要从外部 shims/ 目录读取的替换文件
const SHIM_FILES = {
  '@vscode/ripgrep/lib/index.js': 'ripgrep-index.js',
};

// 注意：依赖树的根是 OUT/node_modules（dsh/node_modules），
// 而 OUT 顶层只放 dsh 自己的 package.json / desktop-runtime.json。
const NM_ROOT = path.join(OUT, 'node_modules');
for (const [rel, content] of Object.entries(SHIMS)) {
  const dest = path.join(NM_ROOT, rel);
  mkdirp(path.dirname(dest));
  const before = fs.existsSync(dest) ? fs.statSync(dest).size : 0;
  fs.writeFileSync(dest, content);
  stats.replaced.push(`${rel}  (${before} → ${Buffer.byteLength(content)} B)`);
}

// 从外部 shims/ 目录读取的替换（ripgrep 等）
const SHIMS_DIR = path.join(__dirname, '..', 'shims');
for (const [rel, srcFile] of Object.entries(SHIM_FILES)) {
  const src = path.join(SHIMS_DIR, srcFile);
  if (!fs.existsSync(src)) {
    console.warn(`[extract] 跳过 ${rel}：找不到 ${src}`);
    continue;
  }
  const dest = path.join(NM_ROOT, rel);
  mkdirp(path.dirname(dest));
  const before = fs.existsSync(dest) ? fs.statSync(dest).size : 0;
  fs.copyFileSync(src, dest);
  stats.replaced.push(`${rel}  (${before} → ${fs.statSync(dest).size} B)`);
}

// ---- 6. 报告 ----
console.log('=== 提取完成 ===');
console.log(`  写入:        ${stats.written} 文件 / ${(stats.bytes / 1048576).toFixed(1)} MiB`);
console.log(`  裁开发文件:  ${stats.skippedDev} / ${(stats.skippedDevBytes / 1048576).toFixed(1)} MiB`);
console.log(`  剔二进制:    ${stats.skippedBin} / ${(stats.skippedBinBytes / 1048576).toFixed(1)} MiB`);
console.log(`  剔平台包:    ${stats.skippedPkg} / ${(stats.skippedPkgBytes / 1048576).toFixed(1)} MiB`);
console.log(`  打 shim:     ${stats.replaced.length} 个`);
for (const r of stats.replaced) console.log(`      ${r}`);
fs.writeFileSync(path.join(OUT, '..', 'extract-report.json'), JSON.stringify(stats, null, 2));
