#!/usr/bin/env node
/**
 * prune.js —— 裁剪 npm 装的依赖树（CI 用）
 *
 * 与 extract.js 共用同一份剔除清单（scripts/excluded.js），
 * 保证本地构建（从 asar 提取）和 CI（npm install）产出相同的包集合。
 *
 * 用法：node prune.js <node_modules 路径>
 */
'use strict';

const fs = require('fs');
const path = require('path');
const {
  DROP_PACKAGES,
  DROP_PATHS,
  DROP_GLOBS,
  HEAVY_FILES,
  DROP_BIN_SCRIPTS,
} = require('./excluded');

const NM = process.argv[2];
if (!NM || !fs.existsSync(NM)) {
  console.error('用法: node prune.js <node_modules 路径>');
  process.exit(2);
}

const DROP_PREFIXES = DROP_GLOBS.filter((g) => g.endsWith('*')).map((g) => g.slice(0, -1));

const stats = {
  removedPkgs: 0,
  removedPkgBytes: 0,
  removedFiles: 0,
  removedFileBytes: 0,
  removedDev: 0,
  removedDevBytes: 0,
};

function dirSize(p) {
  let total = 0;
  try {
    for (const e of fs.readdirSync(p, { withFileTypes: true })) {
      const full = path.join(p, e.name);
      if (e.isDirectory()) total += dirSize(full);
      else if (e.isFile()) {
        try { total += fs.statSync(full).size; } catch {}
      }
    }
  } catch {}
  return total;
}

function rmPkg(full, label) {
  const sz = dirSize(full);
  fs.rmSync(full, { recursive: true, force: true });
  stats.removedPkgs++;
  stats.removedPkgBytes += sz;
  console.log(`  - ${label}  (${(sz / 1048576).toFixed(1)} MiB)`);
}

// ---------------------------------------------------------------- 1. 整包剔除
console.log('=== 剔除平台专属包 ===');
for (const name of fs.readdirSync(NM)) {
  if (name.startsWith('.')) continue;
  const full = path.join(NM, name);
  let isDir = false;
  try { isDir = fs.statSync(full).isDirectory(); } catch { continue; }
  if (!isDir) continue;

  if (name.startsWith('@')) {
    for (const sub of fs.readdirSync(full)) {
      const pkgName = `${name}/${sub}`;
      const pkgFull = path.join(full, sub);
      if (DROP_PACKAGES.has(pkgName)) {
        rmPkg(pkgFull, pkgName);
      } else if (DROP_PREFIXES.some((p) => pkgName.startsWith(p))) {
        rmPkg(pkgFull, pkgName);
      }
    }
    // scope 目录空了就删
    try {
      if (fs.readdirSync(full).length === 0) fs.rmdirSync(full);
    } catch {}
  } else if (DROP_PACKAGES.has(name)) {
    rmPkg(full, name);
  } else if (DROP_PREFIXES.some((p) => name.startsWith(p))) {
    rmPkg(full, name);
  }
}

// ---------------------------------------------------------------- 2. 路径剔除
console.log('\n=== 剔除包内特定目录 ===');
for (const rel of DROP_PATHS) {
  const full = path.join(NM, rel);
  if (fs.existsSync(full)) {
    const sz = dirSize(full);
    fs.rmSync(full, { recursive: true, force: true });
    stats.removedPkgs++;
    stats.removedPkgBytes += sz;
    console.log(`  - ${rel}  (${(sz / 1048576).toFixed(1)} MiB)`);
  }
}

// ---------------------------------------------------------------- 3. 单文件剔除
console.log('\n=== 剔除大文件/原生二进制 ===');
(function walk(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) { walk(full); continue; }
    if (!e.isFile()) continue;
    if (HEAVY_FILES.has(e.name)) {
      let sz = 0;
      try { sz = fs.statSync(full).size; } catch {}
      fs.rmSync(full, { force: true });
      stats.removedFiles++;
      stats.removedFileBytes += sz;
      console.log(`  - ${path.relative(NM, full)}  (${(sz / 1048576).toFixed(1)} MiB)`);
    }
  }
})(NM);

// ---------------------------------------------------------------- 4. 开发文件
console.log('\n=== 裁剪开发文件 ===');
const DEV_EXT = new Set(['.map', '.d.ts', '.d.cts', '.d.mts']);
(function walk(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      // 删测试/文档目录
      if (['test', 'tests', '__tests__', 'docs', '.github', 'prebuilds'].includes(e.name)) {
        const sz = dirSize(full);
        fs.rmSync(full, { recursive: true, force: true });
        stats.removedDev++;
        stats.removedDevBytes += sz;
        continue;
      }
      walk(full);
      continue;
    }
    if (!e.isFile()) continue;
    const lower = e.name.toLowerCase();
    const isDev = DEV_EXT.has(path.extname(lower))
      || lower.endsWith('.d.ts') || lower.endsWith('.d.cts') || lower.endsWith('.d.mts')
      || lower.endsWith('.md') || lower.startsWith('readme') || lower.startsWith('changelog');
    if (isDev) {
      let sz = 0;
      try { sz = fs.statSync(full).size; } catch {}
      fs.rmSync(full, { force: true });
      stats.removedDev++;
      stats.removedDevBytes += sz;
    }
  }
})(NM);

// ---------------------------------------------------------------- 5. .bin 悬空脚本
console.log('\n=== 清理 .bin 悬空脚本 ===');
const binDir = path.join(NM, '.bin');
if (fs.existsSync(binDir)) {
  for (const name of fs.readdirSync(binDir)) {
    const full = path.join(binDir, name);
    if (DROP_BIN_SCRIPTS.includes(name)) {
      fs.rmSync(full, { force: true });
      console.log(`  - .bin/${name}（显式剔除）`);
      continue;
    }
    // 指向不存在目标的悬空链接
    try {
      const real = fs.realpathSync(full);
      if (!fs.existsSync(real)) {
        fs.rmSync(full, { force: true });
        console.log(`  - .bin/${name}（悬空）`);
      }
    } catch {
      fs.rmSync(full, { force: true });
      console.log(`  - .bin/${name}（不可解析）`);
    }
  }
}

// ---------------------------------------------------------------- 报告
const finalSize = dirSize(NM);
console.log('\n=== 裁剪完成 ===');
console.log(`  剔除包:      ${stats.removedPkgs} 个 / ${(stats.removedPkgBytes / 1048576).toFixed(1)} MiB`);
console.log(`  剔除大文件:  ${stats.removedFiles} 个 / ${(stats.removedFileBytes / 1048576).toFixed(1)} MiB`);
console.log(`  剔除开发文件: ${stats.removedDev} 个 / ${(stats.removedDevBytes / 1048576).toFixed(1)} MiB`);
console.log(`  最终体积:    ${(finalSize / 1048576).toFixed(1)} MiB`);

// 校验：不应有任何原生模块
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

if (natives.length > 0) {
  console.error(`\n❌ 仍有 ${natives.length} 个原生模块：`);
  for (const n of natives.slice(0, 10)) console.error(`     ${n}`);
  process.exit(1);
}
console.log('  ✅ 0 个原生模块');
