# dsh-ios — DeepSeek Harness 越狱 iOS 移植

把 macOS 版 DSH 的**内核 + 界面 + 外壳能力**移植到越狱 iOS/iPadOS（rootless `/var/jb`）。

包名：`com.twoyears.dsh`

## 与 Electron 版的关系

Electron 桌面端分三层：

| 层 | 内容 | iOS 处置 |
|---|---|---|
| 内核 | `dsh-base` + `dsh-web-app` + 插件市场 | ✅ 原样移植 |
| UI | 同一份 web 前端 | ✅ 原样复用 |
| 外壳 | `main.js`（848 KB，Electron） | ⚠️ **用 UIKit 重写** |

Electron 本体无法上 iOS（`platform=1 macOS`，链 `AppKit`/`Carbon`/`IOSurface`），
所以外壳的**行为**用 UIKit 复现，包括 preload 暴露的全部 7 个 API。

## 结构

```
build/
├── build.sh                主构建（本地，从 app.asar 提取）
├── build-app.sh            原生 App 编译（需 iOS SDK）
├── app-src/                UIKit 外壳源码（1446 行）
│   ├── DSHBridge.m         复现 Electron 的 7 个 preload API
│   ├── DSHMenu.m           菜单栏
│   ├── DSHRootVC.m         分栏布局 + 内核探测
│   └── DSHShell.m          posix_spawn（iOS 无 NSTask）
├── payload/                装到设备的脚本（权威来源）
├── shims/
│   ├── ios-image-shim.mjs  替代 sharp
│   ├── node-addon-system__flock.js
│   ├── node-addon-require-builtin__index.js
│   └── ripgrep-index.js
├── scripts/
│   ├── extract.js          从 app.asar 提取
│   └── patch-ios.js        iOS 适配补丁（断言式）
└── tools/
    ├── mkdeb.py            纯 Python deb 生成器
    └── verify-deb.py       deb 校验器
```

## 依赖处理

| 原生依赖 | 处置 |
|---|---|
| `sharp` | 纯 JS 头解析（PNG/JPEG/GIF/WebP） |
| `node-addon-system`（flock） | 恒成功锁 |
| `node-addon-require-builtin` | `--expose-internals` + `createRequire` |
| `@vscode/ripgrep` | 解析系统 `rg` |
| `koffi` | 只被 Win32 分支调用，剔除 |
| `node-pty` / `sherpa-onnx` / `libreoffice-kit` | 懒加载，剔除后对应功能降级 |

**0 个 `.node` 原生模块。**

## 构建

### 本地（从 mac app.asar 提取，推荐）

```sh
cd build
bash build.sh
# 产物: dist/com.twoyears.dsh_<ver>_iphoneos-arm64.deb
python3 tools/verify-deb.py dist/*.deb
```

### CI（GitHub Actions）

三个 job：

1. **build-app** — `macos-15` 编译原生 App（本机无 iOS SDK 时必须走这条）
2. **build-cli** — `ubuntu` 构建依赖树
3. **package** — 合并产出最终 deb，tag 时自动发 Release

推 tag 触发发布：

```sh
git tag v0.2.2-rc.5+ios1
git push origin --tags
```

## 安装后

```sh
dsh-doctor      # 自检
dsh-url         # 打印带 token 的 URL
dsh             # 启动 web（默认 3080）
```

桌面图标由 postinst 的 `uicache` 注册；未出现时手动 `uicache -a`。

## 关键约束

- **Node ≥ 24.9.0** 是硬门槛（`lib/bin.js` 用 `import.meta.main`）
- 启动必须带 `--expose-internals`（不能放 `NODE_OPTIONS`）
- `process.platform` 在 iOS 上仍是 `darwin`，需检测 `/var/jb` 区分
- 图片 shim 必须用 `--import` 预加载，否则老对话会 `TRANSPORT`

## 已知降级

| 功能 | 原因 |
|---|---|
| 语音转文字 | `sherpa-onnx` 无 iOS 产物 |
| Office 渲染 | `libreoffice-kit` 原生包是 macOS 的 |
| 终端 PTY | `node-pty` 无 iOS 预编译 |
| 手机操控 | 未实现（参考 yitenchen123/dsh-ios 的 phone-bridge） |
