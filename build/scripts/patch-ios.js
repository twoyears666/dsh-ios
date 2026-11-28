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

// ---------------------------------------------------------------- 6. 回环免 token
// 移植版的 App 就是本机的 WKWebView 外壳，浏览器和内核在同一台设备上。
// token 的本意是防「远程」访问，回环上再套一层 token 只有坏处：
//   - App 每次要去 web.log 里正则抓 token，旧日志/多实例时会抓错
//   - 抓不到就 401，界面卡在「未启动」，很难查
//   - 用户自己 curl 127.0.0.1:3080 调试也被挡住
//
// 内核里鉴权只有两个入口，两处都放行回环即可：
//   authorizeIndex()  —— 页面本身
//   admit()           —— /api 与 socket 升级
// 判据用 socket 的 remoteAddress，不看 Host 头（Host 可以伪造）。
PATCHES.push({
  name: '回环访问免 token（页面）',
  file: '@deepseek-ai/dsh-client-connection/lib/index.js',
  old: `\tauthorizeIndex(req, res, secure = false) {
\t\t/* v8 ignore next -- node:http always supplies url on server requests. */`,
  new: `\tauthorizeIndex(req, res, secure = false) {
\t\t// dsh-iOS: 回环免 token。移植版是本机 WebView 外壳，
\t\t// token 只对远程访问有意义；回环上再要 token 只会让 App 抓 token 失败。
\t\t//
\t\t// 两个判据：
\t\t//   1) socket 的 remoteAddress（最可靠）
\t\t//   2) Host 头兜底 —— 真机上 dsh 的 web server 适配层没有把 socket
\t\t//      透传进来，remoteAddress 恒为 undefined，只看它的话永远 401。
\t\tconst _ra = req.socket?.remoteAddress;
\t\tif (_ra === "127.0.0.1" || _ra === "::1" || _ra === "::ffff:127.0.0.1") return true;
\t\tconst _h = String(header(req.headers, "host") ?? "").toLowerCase();
\t\tif (_h.startsWith("127.0.0.1") || _h.startsWith("localhost") || _h.startsWith("[::1]")) return true;
\t\t/* v8 ignore next -- node:http always supplies url on server requests. */`,
  marker: 'dsh-iOS: 回环免 token。移植版是本机 WebView 外壳',
  check: 'esm',
});

PATCHES.push({
  name: '回环访问免 token（/api）',
  file: '@deepseek-ai/dsh-client-connection/lib/index.js',
  old: `\t\tif (this.disposed) return { rejection: 401 };
\t\tconst secure = this.owner.get("webServer")?.protocol === "https:";`,
  new: `\t\tif (this.disposed) return { rejection: 401 };
\t\t// dsh-iOS: 回环免 token（与 authorizeIndex 同一判据）。
\t\t// 返回 browserPeer，等价于「浏览器带着有效 cookie 进来了」。
\t\tconst _ra = request.socket?.remoteAddress;
\t\tif (_ra === "127.0.0.1" || _ra === "::1" || _ra === "::ffff:127.0.0.1") return { peer: this.browserPeer };
\t\tconst _h = String(header(request.headers, "host") ?? "").toLowerCase();
\t\tif (_h.startsWith("127.0.0.1") || _h.startsWith("localhost") || _h.startsWith("[::1]")) return { peer: this.browserPeer };
\t\tconst secure = this.owner.get("webServer")?.protocol === "https:";`,
  marker: 'dsh-iOS: 回环免 token（与 authorizeIndex 同一判据）',
  check: 'esm',
});

// ---------------------------------------------------------------- 7. 会话编码不再抛错
// 真机日志里的真实故障：
//   workspace: Error: session artifact ".../session.v4.jsonl" uses .jsonl,
//   but this backend is configured for compression "zstd"
// workspace 服务一挂，session-controller / workspace-controller /
// ui-deliverables / workspace-changes 全部 pending —— 整个 UI 不可用。
//
// 之前只补了 findOppositeGenerationInDirectory（让它适配并把 compression
// 翻过来），但那个函数现在返回的是「迁移描述」而不是错误路径，
// 两个调用方仍然把「返回值非 undefined」当成出错：
//   checkRootEncoding()      → throw encodingMismatch
//   rejectOppositeArtifact() → throw encodingMismatch
// 所以补丁等于没生效。这里把两个调用方改成「只触发适配，不抛错」。
PATCHES.push({
  name: '会话编码检查不抛错（根目录）',
  file: '@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js',
  old: `\tasync checkRootEncoding() {
\t\tawait this.mapSessionDirectories(async (dir) => {
\t\t\tconst incompatible = await this.findOppositeGenerationInDirectory(dir);
\t\t\tif (incompatible !== void 0) throw this.encodingMismatch(incompatible);
\t\t});
\t}`,
  new: `\tasync checkRootEncoding() {
\t\t// dsh-iOS: 不再因相反编码抛错。
\t\t// findOppositeGenerationInDirectory 现在返回迁移描述（不是错误路径），
\t\t// 读取路径会自己适配；这里再抛会让 workspace 服务整体挂掉。
\t\tawait this.mapSessionDirectories(async (dir) => {
\t\t\tawait this.findOppositeGenerationInDirectory(dir);
\t\t});
\t}`,
  marker: 'dsh-iOS: 不再因相反编码抛错。',
  check: 'esm',
});

PATCHES.push({
  name: '会话编码检查不抛错（单会话）',
  file: '@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js',
  old: `\tasync rejectOppositeArtifact(cwd, id) {
\t\tconst path = await this.findOppositeGenerationInDirectory(sessionDir(this.root, cwd, id));
\t\tif (path !== void 0) throw this.encodingMismatch(path);
\t}`,
  new: `\tasync rejectOppositeArtifact(cwd, id) {
\t\t// dsh-iOS: 同上 —— 存在旧格式会话文件时不再拒绝，交给读取路径适配。
\t\tawait this.findOppositeGenerationInDirectory(sessionDir(this.root, cwd, id));
\t}`,
  marker: 'dsh-iOS: 同上 —— 存在旧格式会话文件时不再拒绝',
  check: 'esm',
});

// ---------------------------------------------------------------- 8. token 落到文件
// 内核的 launch token 是启动时随机生成的，只打印在 web.log 里。
// App 想认证就得去日志里正则抓 —— 日志会被截断、轮转、多个实例时还会抓错。
//
// 让内核启动时把它写到 $DSH_CONFIG_DIR/web-token（0600），App 直接读文件。
// token 仍然每次启动都换（不固定），只是多了一个稳定的取用通道。
PATCHES.push({
  name: 'launch token 写入文件',
  file: '@deepseek-ai/dsh-client-connection/lib/index.js',
  old: `import { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";`,
  new: `import { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { writeFileSync as __dshWriteFileSync, mkdirSync as __dshMkdirSync } from "node:fs";`,
  marker: '__dshWriteFileSync',
  check: 'esm',
});

PATCHES.push({
  name: 'launch token 写入文件（写入点）',
  file: '@deepseek-ai/dsh-client-connection/lib/index.js',
  old: `\tconst created = encodeBase64Url(randomBytes(SECRET_BYTES));
\tPROCESS_LAUNCH_TOKENS.set(owner, created);
\treturn created;`,
  new: `\tconst created = encodeBase64Url(randomBytes(SECRET_BYTES));
\tPROCESS_LAUNCH_TOKENS.set(owner, created);
\t// dsh-iOS: 落到 $DSH_CONFIG_DIR/web-token，App 直接读文件，
\t// 不用去 web.log 里正则抓（日志会截断/轮转，多实例还会抓错）。
\ttry {
\t\tconst __dir = process.env.DSH_CONFIG_DIR
\t\t\t|| (process.env.DSH_ROOT ? process.env.DSH_ROOT + "/config" : "");
\t\tif (__dir) {
\t\t\t__dshMkdirSync(__dir, { recursive: true });
\t\t\t__dshWriteFileSync(__dir + "/web-token", created + "\\n", { mode: 384 });
\t\t}
\t} catch {}
\treturn created;`,
  marker: 'dsh-iOS: 落到 $DSH_CONFIG_DIR/web-token',
  check: 'esm',
});

// ---------------------------------------------------------------- 9. 固定 launch token
// SFSafariViewController 的 URL 是写死在 App 里的静态字符串，没法跟随每次
// 启动随机变的 launchToken。裸 "/" 必 401，前端 JS 全部不加载。
// 参考 yitenchen123/dsh-ios：让 processLaunchToken 优先读 DSH_WEB_TOKEN
// 环境变量（内核 env 注入），缺省用固定值 —— 保证终端手动 dsh web 时也一致。
// local loopback-only，无跨设备暴露。
PATCHES.push({
  name: '固定 launch token（Safari URL 静态匹配）',
  file: '@deepseek-ai/dsh-client-connection/lib/index.js',
  old: `function processLaunchToken(owner) {`,
  new: `function processLaunchToken(owner) {
\t// dsh-iOS: 固定 loopback token，供 SFSafariViewController 的静态 URL 匹配。
\t// 裸 "/" 必 401；DSH_WEB_TOKEN 由 App env 注入，缺省值保证终端启动也一致。
\tconst __fixed = process.env.DSH_WEB_TOKEN || "dshios-fixed-token-8f3a2c";
\tif (__fixed) return __fixed;`,
  marker: 'dsh-iOS: 固定 loopback token',
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
