/**
 * excluded.js —— iOS 移植的**权威剔除清单**（本地构建与 CI 共用）
 *
 * 每一项都说明「为什么不能用」和「替代方案」，方便日后维护。
 *
 * 用法：
 *   const { DROP_PACKAGES, DROP_PATHS, DROP_GLOBS, HEAVY_FILES } = require('./excluded');
 */

'use strict';

// ============================================================================
// 1. 整包剔除（平台专属，iOS 上无法运行）
// ============================================================================
const DROP_PACKAGES = new Set([
  // ---- sharp：图像处理（libvips 原生库） ----
  // 替代：shims/ios-image-shim.mjs（纯 JS 解析 PNG/JPEG/GIF/WebP 头）
  '@img/sharp-darwin-arm64',
  '@img/sharp-darwin-x64',
  '@img/sharp-linux-arm64',
  '@img/sharp-linux-x64',
  '@img/sharp-libvips-darwin-arm64',
  '@img/sharp-libvips-darwin-x64',
  '@img/sharp-libvips-linux-arm64',
  '@img/sharp-libvips-linux-x64',
  '@img/colour',                      // sharp 的依赖，无原生代码但随 sharp 一起剔除

  // ---- koffi：FFI 库 ----
  // 只被 Win32 分支调用（dsh-fs-local / dsh-session-persistence-jsonl /
  // libreoffice-kit 的 windowsPipes()），darwin/iOS 路径不碰。可安全剔除。
  '@koromix/koffi-darwin-arm64',
  '@koromix/koffi-darwin-x64',
  '@koromix/koffi-linux-arm64',
  '@koromix/koffi-linux-x64',
  '@koromix/koffi-win32-arm64',
  '@koromix/koffi-win32-x64',

  // ---- ripgrep：搜索二进制 ----
  // 替代：shims/ripgrep-index.js 解析系统 rg（/var/jb/usr/bin/rg）
  // 需要在设备上 apt install ripgrep（Procursus 有 12.1.1-1）
  '@vscode/ripgrep-darwin-arm64',
  '@vscode/ripgrep-darwin-x64',
  '@vscode/ripgrep-linux-arm64',
  '@vscode/ripgrep-linux-x64',
  '@vscode/ripgrep-linux-arm',
  '@vscode/ripgrep-linux-ppc64',
  '@vscode/ripgrep-linux-riscv64',
  '@vscode/ripgrep-linux-s390x',
  '@vscode/ripgrep-linux-ia32',
  '@vscode/ripgrep-win32-x64',
  '@vscode/ripgrep-win32-arm64',
  '@vscode/ripgrep-win32-ia32',

  // ---- sherpa-onnx：语音识别 ----
  // 无 iOS 产物。语音输入改用 iOS 原生 SFSpeechRecognizer（见 README）
  'sherpa-onnx-darwin-arm64',
  'sherpa-onnx-darwin-x64',
  'sherpa-onnx-node',

  // ---- libreoffice-kit：Office 渲染 ----
  // macOS 原生包 140MB（dsoffice 二进制）+ wasm 版 143MB（wasm+data）。
  // 两者 iOS 都用不了或太大。Office 渲染降级为「不支持」。
  // 纯文本 Office 处理可走 Python（python-docx / openpyxl / python-pptx）。
  '@deepseek-ai/libreoffice-kit-darwin-arm64',
  '@deepseek-ai/libreoffice-kit-darwin-x64',
  '@deepseek-ai/libreoffice-kit-win32-x64',
  '@deepseek-ai/libreoffice-kit-win32-arm64',
  '@deepseek-ai/libreoffice-kit-wasm',

  // ---- node-addon-system：flock 原生 addon ----
  // 替代：shims/node-addon-system__flock.js（恒成功锁，单实例无竞争）
  '@deepseek-ai/node-addon-system-darwin-arm64',
  '@deepseek-ai/node-addon-system-darwin-x64',
  '@deepseek-ai/node-addon-system-linux-arm64',
  '@deepseek-ai/node-addon-system-linux-x64',

  // ---- node-addon-require-builtin：内部模块加载 ----
  // 替代：shims/node-addon-require-builtin__index.js（--expose-internals）
  'node-addon-require-builtin-darwin-arm64',
  'node-addon-require-builtin-darwin-x64',
  'node-addon-require-builtin-linux-arm64-gnu',
  'node-addon-require-builtin-linux-arm64-musl',
  'node-addon-require-builtin-linux-x64-gnu',
  'node-addon-require-builtin-linux-x64-musl',
  'node-addon-require-builtin-win32-arm64-msvc',
  'node-addon-require-builtin-win32-ia32-msvc',
  'node-addon-require-builtin-win32-x64-msvc',

  // ---- node-pty：终端 PTY ----
  // 替代：shims/node-pty-ios/（纯 JS 管道模拟，非真 PTY）
  'node-pty',

  // ---- Windows 专属 ----
  // dsh-win32-process 用 koffi 调 Win32 API（进程/ACL），iOS 完全无关
  '@deepseek-ai/dsh-win32-process',
  '@deepseek-ai/dsh-sandbox-windows-acl',
  '@deepseek-ai/dsh-tool-pwsh',
  '@deepseek-ai/dsh-tool-pwsh-persistent',
  '@deepseek-ai/dsh-pwsh-local',
  '@deepseek-ai/dsh-pwsh-sandbox',
  'powershell-utils',
  'wsl-utils',

  // ---- 桌面专属（Electron 宿主）----
  // iOS 无 Electron，由原生 UIKit App 替代
  '@deepseek-ai/dsh-desktop-host',
  '@deepseek-ai/dsh-error',           // desktop-host 专用
  '@deepseek-ai/dsh-deepseek-chat-import',  // Electron 导入功能

  // ---- Computer Use（macOS 专属实现）----
  // iOS 无 provider。替代：yitchen 的 phone-bridge（待移植）
  '@deepseek-ai/dsh-experimental-cua-macos',
  '@deepseek-ai/dsh-cua-bundle',
]);

// ============================================================================
// 2. 路径剔除（包内特定目录/文件）
// ============================================================================
const DROP_PATHS = [
  // inspector 的 devtools 调试资源：iOS 上用不到，体积大
  //   lighthouse_worker.js  8.8 MB
  '@deepseek-ai/dsh-experimental-inspector/lib/devtools/entrypoints/lighthouse_worker',
];

// ============================================================================
// 3. 通配剔除（CI 用 rm -rf，本地 extract.js 用前缀匹配）
// ============================================================================
const DROP_GLOBS = [
  // 所有平台的 sharp / koffi / ripgrep 二进制（除了已在 DROP_PACKAGES 列的）
  '@img/sharp-*',
  '@koromix/koffi-*',
  '@vscode/ripgrep-*',
  'sherpa-onnx-*',
  '@deepseek-ai/node-addon-system-*',
  'node-addon-require-builtin-*',
  '@deepseek-ai/libreoffice-kit-*',
];

// ============================================================================
// 4. 单文件剔除（体积大且无用）
// ============================================================================
const HEAVY_FILES = new Set([
  'dsoffice',        // libreoffice 主二进制（140MB）
  'dsoffice.wasm',   // libreoffice wasm 版（122MB）
  'dsoffice.data',   // wasm 数据（22MB）
  'rg',              // ripgrep 二进制
  'rg.exe',
  'spawn-helper',    // node-pty 的 macOS 辅助程序
  'xdg-open',        // Linux 专属
]);

// ============================================================================
// 5. .bin/ 里指向已剔除包的悬空脚本
// ============================================================================
const DROP_BIN_SCRIPTS = [
  'dsoffice',   // → libreoffice-kit-darwin-arm64（已删）
  'soffice',
  'libreoffice',
];

// ============================================================================
// 6. 保留但需过滤内容的包（剔除其中的原生二进制，保留 JS）
// ============================================================================
const FILTER_BINARY_IN = new Set([
  '@deepseek-ai/libreoffice-kit',    // frame-forwarding/*.node
  '@deepseek-ai/dsh-cua',
  '@deepseek-ai/dsh-computer-use',
]);

// ============================================================================
// 7. 功能降级说明（供 README 和 AGENTS.md 引用）
// ============================================================================
const DEGRADED_FEATURES = [
  {
    feature: '语音转文字',
    reason: 'sherpa-onnx 无 iOS 产物',
    status: 'plan',
    plan: '改用 iOS 原生 SFSpeechRecognizer（AVFoundation + Speech framework）',
  },
  {
    feature: 'Office 渲染/转换',
    reason: 'libreoffice-kit 只有 macOS 原生包（140MB）和 wasm 版（143MB）',
    status: 'unsupported',
    plan: '纯文本处理走 Python（python-docx / openpyxl / python-pptx）',
  },
  {
    feature: 'Computer Use（桌面应用操控）',
    reason: 'dsh-experimental-cua-macos 是 macOS 原生实现',
    status: 'plan',
    plan: '移植 yitchen 的 phone-bridge（SpringBoard 注入，操控整个手机）',
  },
  {
    feature: '真 PTY 终端',
    reason: 'node-pty 无 iOS 预编译产物',
    status: 'degraded',
    plan: '已用纯 JS 管道模拟；isatty()=false，TUI 程序（vim/top）行为异常',
  },
  {
    feature: 'sharp 图片处理',
    reason: 'libvips 无 iOS 产物',
    status: 'degraded',
    plan: '已用纯 JS 头解析替代；只读尺寸/格式，不做缩放转码',
  },
  {
    feature: '内核级沙箱',
    reason: 'landlock 是 Linux 专属',
    status: 'degraded',
    plan: '降级为软限制（纯 JS 检查），不要依赖它做安全边界',
  },
];

module.exports = {
  DROP_PACKAGES,
  DROP_PATHS,
  DROP_GLOBS,
  HEAVY_FILES,
  DROP_BIN_SCRIPTS,
  FILTER_BINARY_IN,
  DEGRADED_FEATURES,
};
