#!/usr/bin/env node
/**
 * check-deps.js —— 启动前自检：检查依赖树完整性
 *
 * 在 dsh 启动前跑一次，把「包被剔除但仍有包声明依赖」的情况查出来，
 * 避免像 dsh-error 那样等到运行时才发现 61 个插件全挂。
 *
 * 检查项：
 *   1. 每个包的 dependencies / peerDependencies 是否都能解析
 *   2. cordis.patch.yml 里声明的插件是否都存在
 *   3. 原生模块数量是否为 0
 *
 * 用法：node check-deps.js <node_modules 路径>
 * 退出码：0 通过，1 有致命问题，2 只有警告
 */
'use strict';

const fs = require('fs');
const path = require('path');

const NM = process.argv[2];
if (!NM || !fs.existsSync(NM)) {
  console.error('用法: node check-deps.js <node_modules 路径>');
  process.exit(2);
}

/** 枚举所有已安装的包。 */
function listInstalled(nm) {
  const out = new Map();
  for (const scope of fs.readdirSync(nm)) {
    if (scope.startsWith('.')) continue;
    const sd = path.join(nm, scope);
    let st;
    try { st = fs.statSync(sd); } catch { continue; }
    if (!st.isDirectory()) continue;
    if (scope.startsWith('@')) {
      for (const sub of fs.readdirSync(sd)) {
        const p = path.join(sd, sub);
        try { if (fs.statSync(p).isDirectory()) out.set(`${scope}/${sub}`, p); } catch {}
      }
    } else {
      out.set(scope, sd);
    }
  }
  return out;
}

const installed = listInstalled(NM);
const errors = [];
const warnings = [];

/**
 * 已知的可选依赖：缺失不影响启动。
 * 每项说明为什么可以缺。
 */
const KNOWN_OPTIONAL = new Set([
  'koffi',                                  // 只被 Win32 分支调用
  'sherpa-onnx-node',                       // 懒加载，语音功能才用
  '@deepseek-ai/libreoffice-kit',           // Office 渲染才用
  '@deepseek-ai/libreoffice-kit-darwin-arm64',
  '@deepseek-ai/dsh-win32-process',         // Windows 专属
  '@deepseek-ai/dsh-sandbox-windows-acl',   // Windows 专属
  'powershell-utils',                       // PowerShell 专属
  'wsl-utils',                              // WSL 专属
  'node-pty',                               // 已用 shim 替代
  'sharp',                                  // 已用 shim 替代
  '@vscode/ripgrep',                        // 已用 shim 替代
  '@deepseek-ai/dsh-tool-pwsh',             // PowerShell 工具，iOS 无关
  '@deepseek-ai/dsh-tool-pwsh-persistent',
  '@deepseek-ai/dsh-pwsh-local',
  '@deepseek-ai/dsh-pwsh-sandbox',
  '@deepseek-ai/dsh-cua-bundle',            // CUA，iOS 无 provider
  '@deepseek-ai/dsh-deepseek-chat-import',  // Electron 导入功能
]);

/** 判断一个 specifier 是否是「包名/子路径」形式（子路径不算缺包）。 */
function isSubpath(spec) {
  if (spec.startsWith('.') || spec.startsWith('/')) return false;
  const parts = spec.split('/');
  if (spec.startsWith('@')) return parts.length > 2;   // @scope/pkg/sub
  return parts.length > 1;                             // pkg/sub
}

/** 提取包名（去掉子路径）。 */
function pkgName(spec) {
  const parts = spec.split('/');
  if (spec.startsWith('@')) return parts.slice(0, 2).join('/');
  return parts[0];
}

// ---------------------------------------------------------------- 1. 依赖解析
console.log('=== 检查依赖解析 ===');
let missingCount = 0;
for (const [name, dir] of installed) {
  const pj = path.join(dir, 'package.json');
  if (!fs.existsSync(pj)) continue;
  let pkg;
  try { pkg = JSON.parse(fs.readFileSync(pj, 'utf8')); } catch { continue; }

  const deps = {
    ...(pkg.dependencies || {}),
    ...(pkg.peerDependencies || {}),
  };
  for (const dep of Object.keys(deps)) {
    if (dep.startsWith('node:')) continue;
    if (pkg.peerDependenciesMeta?.[dep]?.optional) continue;
    if (isSubpath(dep)) continue;                     // 子路径导入，不是缺包
    if (KNOWN_OPTIONAL.has(dep)) continue;            // 已知可选
    if (!installed.has(dep)) {
      missingCount++;
      const isCore = dep.startsWith('@deepseek-ai/dsh') && !dep.match(/-(darwin|win32|linux)/);
      const line = `${name} 依赖 ${dep}`;
      if (isCore) errors.push(line);
      else warnings.push(line);
    }
  }
}
if (missingCount === 0) {
  console.log('  ✅ 所有依赖都能解析');
} else {
  console.log(`  ⚠ ${missingCount} 个依赖无法解析`);
}

// ---------------------------------------------------------------- 2. cordis.patch.yml
console.log('\n=== 检查 cordis.patch.yml 声明的插件 ===');
let patchMissing = 0;
for (const [name, dir] of installed) {
  for (const f of ['cordis.patch.yml', 'presets/cordis.patch.yml']) {
    const p = path.join(dir, f);
    if (!fs.existsSync(p)) continue;
    const text = fs.readFileSync(p, 'utf8');
    // 匹配 name: '@scope/pkg' 或 name: "@scope/pkg"
    const re = /name:\s*['"]?(@?[a-z0-9][\w./-]*)['"]?/gi;
    let m;
    while ((m = re.exec(text)) !== null) {
      const pkg = m[1];
      if (!pkg.includes('/')) continue;
      if (pkg.startsWith('.')) continue;
      if (isSubpath(pkg)) continue;               // 子路径导入
      if (KNOWN_OPTIONAL.has(pkg)) continue;      // 已知可选
      if (!installed.has(pkg)) {
        patchMissing++;
        const isCore = pkg.startsWith('@deepseek-ai/dsh') && !pkg.match(/-(pwsh|win32|darwin|linux)/);
        const line = `${name}/${f} 声明了 ${pkg}`;
        if (isCore) errors.push(line);
        else warnings.push(line);
      }
    }
  }
}
if (patchMissing === 0) {
  console.log('  ✅ 所有声明的插件都存在');
} else {
  console.log(`  ⚠ ${patchMissing} 个声明的插件不存在`);
}

// ---------------------------------------------------------------- 3. 原生模块
console.log('\n=== 检查原生模块 ===');
const natives = [];
(function walk(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) { walk(full); continue; }
    if (/\.(node|dylib|so|dll)$/.test(e.name)) natives.push(path.relative(NM, full));
  }
})(NM);
if (natives.length === 0) {
  console.log('  ✅ 0 个原生模块');
} else {
  console.log(`  ❌ ${natives.length} 个原生模块`);
  for (const n of natives.slice(0, 5)) errors.push(`原生模块残留: ${n}`);
}

// ---------------------------------------------------------------- 报告
console.log('\n=== 结果 ===');
if (errors.length > 0) {
  console.error(`❌ ${errors.length} 个致命问题：`);
  for (const e of errors.slice(0, 20)) console.error(`     ${e}`);
  if (errors.length > 20) console.error(`     ... 还有 ${errors.length - 20} 个`);
}
if (warnings.length > 0) {
  console.log(`⚠ ${warnings.length} 个警告（可选依赖，不影响启动）：`);
  for (const w of warnings.slice(0, 10)) console.log(`     ${w}`);
  if (warnings.length > 10) console.log(`     ... 还有 ${warnings.length - 10} 个`);
}

if (errors.length > 0) process.exit(1);
if (warnings.length > 0) process.exit(2);
console.log('✅ 依赖树完整');
process.exit(0);
