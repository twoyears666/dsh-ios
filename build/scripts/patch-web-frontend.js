#!/usr/bin/env node
/**
 * patch-web-frontend.js —— 把前端产物降级到老 WebKit 能解析的语法
 *
 * 背景（真机现象）：
 *   同一份 dsh web UI，在 Renard（Gecko/Firefox 内核）里能正常显示，
 *   在 Safari / WKWebView 里白屏，且**没有任何 JS 报错**。
 *
 *   原因是 index-*.js 里用了 class static blocks：
 *       class X { static { ... } }
 *   `static {}` 需要 Safari 16.4+，而 Firefox 从 93 就支持。
 *   老 WebKit 解析到这个语法直接抛 SyntaxError —— 是**解析期**错误，
 *   所以 window.onerror 也抓不到，表现就是纯白屏。
 *
 * 做法：
 *   static { BODY }
 *     ↓
 *   static _sbN=(()=>{ BODY })()
 *
 *   两者语义完全一致：都在类定义时执行、`this` 都是类本身、
 *   都能引用外部已定义的绑定。静态字段（static field）从 Safari 14.1
 *   就支持，覆盖范围大得多。
 *
 * 另外给 index.html 注入一小段 polyfill，补上 Object.hasOwn（Safari 15.4+），
 * 有就跳过，没有就补 —— 对老系统是无害的。
 *
 * 用法：node patch-web-frontend.js <dsh-web-frontend/dist 目录>
 */
'use strict';

const fs = require('fs');
const path = require('path');

const DIST = process.argv[2];
if (!DIST) {
  console.error('用法: node patch-web-frontend.js <dsh-web-frontend/dist>');
  process.exit(2);
}
if (!fs.existsSync(DIST)) {
  // 上游可能改目录结构；这种情况下不能静默通过，也不能硬失败
  console.log(`[web] ⚠ 目录不存在，跳过: ${DIST}`);
  process.exit(0);
}

const MARKER = 'dsh-iOS: static block 降级';
let changed = 0;

/** 从 `static{` 的 `{` 开始做花括号配对，返回右括号下标 */
function matchBrace(src, openIdx) {
  let depth = 0;
  let i = openIdx;
  let inStr = null;      // ' " `
  let inTpl = 0;
  while (i < src.length) {
    const c = src[i];
    if (inStr) {
      if (c === '\\') { i += 2; continue; }
      if (c === inStr) inStr = null;
      i++;
      continue;
    }
    if (c === '"' || c === "'" || c === '`') { inStr = c; i++; continue; }
    if (c === '{') depth++;
    else if (c === '}') {
      depth--;
      if (depth === 0) return i;
    }
    i++;
  }
  return -1;
}

/** 把文件里所有 class static block 换成 static field IIFE */
function convertStaticBlocks(src) {
  let out = '';
  let pos = 0;
  let n = 0;
  const re = /static\s*\{/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    const openIdx = m.index + m[0].length - 1;   // `{` 的位置
    const closeIdx = matchBrace(src, openIdx);
    if (closeIdx < 0) continue;                   // 配不上就跳过，绝不硬改
    const body = src.slice(openIdx + 1, closeIdx);
    out += src.slice(pos, m.index);
    // 压缩代码里类成员之间没有分隔符，必须自己补分号，
    // 否则会拼成 `...call(this)constructor(){...}` → 语法错误
    out += `static _sb${n++}=(function(){${body}}).call(this);`;
    pos = closeIdx + 1;
    re.lastIndex = pos;
  }
  out += src.slice(pos);
  return { text: out, count: n };
}

// ---------------------------------------------------------------- 1. JS
const assets = path.join(DIST, 'assets');
const dirs = [DIST, assets].filter((d) => fs.existsSync(d));
const jsFiles = [];
for (const d of dirs) {
  for (const f of fs.readdirSync(d)) {
    if (f.endsWith('.js')) jsFiles.push(path.join(d, f));
  }
}

for (const file of jsFiles) {
  let src = fs.readFileSync(file, 'utf8');
  if (src.includes(MARKER)) {
    console.log(`[web] 已打过: ${path.basename(file)}`);
    continue;
  }
  if (!/static\s*\{/.test(src)) continue;

  const { text, count } = convertStaticBlocks(src);
  if (count === 0) {
    console.log(`[web] ⚠ ${path.basename(file)}: 有 static{ 但没配上花括号，跳过`);
    continue;
  }
  // 头部加标记注释，方便下次判断是否已处理
  fs.writeFileSync(file, `/* ${MARKER} */\n` + text, 'utf8');
  console.log(`[web] ✓ ${path.basename(file)}: 降级 ${count} 处 static block`);
  changed += count;
}

// ---------------------------------------------------------------- 2. index.html polyfill
const indexPath = path.join(DIST, 'index.html');
if (fs.existsSync(indexPath)) {
  let html = fs.readFileSync(indexPath, 'utf8');
  if (!html.includes('dsh-ios-polyfill')) {
    // Object.hasOwn 是 Safari 15.4+；老系统上补一个等价实现
    const polyfill =
      '<script id="dsh-ios-polyfill">' +
      'if(!Object.hasOwn){Object.hasOwn=function(o,k){' +
      'return Object.prototype.hasOwnProperty.call(o,k)}}' +
      '</script>';
    html = html.replace('<head>', '<head>\n    ' + polyfill);
    fs.writeFileSync(indexPath, html, 'utf8');
    console.log('[web] ✓ index.html 注入 Object.hasOwn polyfill');
  } else {
    console.log('[web] 已打过: index.html polyfill');
  }
}

// 复查：打完补丁后不能还有 class static block，
// 否则老 WebKit 依然白屏 —— 这种情况必须让构建失败，不能静默通过
let leftover = 0;
for (const file of jsFiles) {
  const src = fs.readFileSync(file, 'utf8');
  const m = src.match(/static\s*\{/g);
  if (m) {
    console.error(`[web] ✗ ${path.basename(file)} 仍有 ${m.length} 处 static block`);
    leftover += m.length;
  }
}
console.log(`[web] 汇总: 降级 ${changed} 处 static block，残留 ${leftover} 处`);
process.exit(leftover === 0 ? 0 : 1);
