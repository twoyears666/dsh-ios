# dsh-ios — DeepSeek Harness 越狱 iOS 移植

把 macOS 版 DSH 移植到越狱 iOS/iPadOS（rootless `/var/jb`）。

包名：`com.twoyears.dsh`

---

## 快速开始

```sh
# 装完
dsh-doctor                      # 自检
dsh-ctl status                  # 看内核状态
dsh-url                         # 拿带 token 的 URL
```

桌面图标：`DSH.app`（未出现则 `uicache -a`）

---

## 架构

macOS 版分三层，iOS 上只有第三层需要重写：

| 层 | 内容 | iOS 处置 |
|---|---|---|
| ① 内核 | `dsh-base` + `dsh-web-app` + 插件市场 | ✅ 原样移植 |
| ② UI | 同一份 web 前端 | ✅ 原样复用 |
| ③ 外壳 | `main.js`（848 KB Electron） | ⚠️ **用 UIKit 重写** |

### 为什么 Electron 不能上 iOS

```
Electron Framework: 285 MB, platform=1 (macOS)
  链接 AppKit / Carbon / IOSurface / AuthenticationServices
```

`platform` 是编译期常量，`ldid` 改不了；`AppKit`/`Carbon` 在 iOS SDK 里不存在。

所以外壳的**行为**用 UIKit 复现，包括 Electron preload 暴露的全部 7 个 API。

### 关键证据：桌面端和 web 是同一个东西

`dsh-desktop-host` 启动的是：

```js
runProfile({ profile: "desktop", args: ["--no-open", "--host", "127.0.0.1", ...] })
```

`desktop` profile 的 bundles 是 `dsh-base + dsh-web-app + 插件市场 + forge` ——
**和 `dsh web` 完全一样**。差别 100% 在外壳层。

---

## 已实现

### 外壳层

| Electron 能力 | iOS 实现 |
|---|---|
| `BrowserWindow` + `titleBarStyle: hidden` | `UISplitViewController` |
| `vibrancy: sidebar` | `secondarySystemBackgroundColor` |
| 菜单栏（123 处 `Menu`） | `UIMenu`（会话/视图/内核/关于） |
| `dialog.showOpenDialog` | `UIDocumentPickerViewController` + 安全书签 |
| `shell.openExternal` | `UIApplication.openURL`（scheme 白名单） |
| `app.getPath` | 路径映射（home/userData/temp/documents…） |
| `window.close` | 降级为日志（iOS 无窗口概念） |
| 托盘 | ❌ iOS 无此概念 |
| 自动更新 | ❌ 走 Sileo |

### Electron preload 的 7 个 API（全部复现）

```
dshOnboarding            { hasApiKey, setActive }
__DSH_DIRECTORY_PICKER__ { pick }
__DSH_HOST_PATHS__       { pathFor }
dshDesktopBoot           { ready, failed }
dshPlatform              { open, close, setBounds }
dshDesktop               { app: { getVersion, getPlatform, getPath, quit } }
__DSH_LOCALE__           { read, onChange }
```

### 侧边栏浏览器（`dshDesktop.browser` 协议）

Electron 用 `<webview>` 标签；iOS 没有，所以：

- **原生侧**：每个 lease 对应一个真实 `WKWebView`，独立 frame
- **JS 侧**：劫持 `document.createElement('webview')`，返回带 Electron 方法的 div
- 8 种导航事件转发、`target=_blank` 拦截

协议：

```js
bridge.acquire(workspaceKey) → { lease, partition }
bridge.release(lease)        → Promise
bridge.onOpenRequested(lease, cb) → unsubscribe
```

### Agent 浏览器工具（`browser_*`）

默认**关闭**，需手动开启：

```sh
dsh-ctl browser on && dsh-ctl restart
```

| 工具 | 用途 |
|---|---|
| `browser_open(url)` | 打开网页（用户可见），返回 tabId |
| `browser_snapshot()` | 渲染后正文 + 可交互元素选择器 |
| `browser_click(selector)` | 点击 |
| `browser_type(sel, text, submit)` | 输入 |
| `browser_screenshot()` | base64 PNG |
| `browser_eval(expression)` | 页面内执行 JS |

架构：

```
agent → browser_*  →  HTTP POST 127.0.0.1:3081/browser
                          ↓
                   DSHBrowserControl（App 内手写 HTTP server）
                          ↓
                   WKWebView（显示在用户眼前）
```

走 HTTP 是因为 dsh 内核（node）和 App（UIKit）是两个独立进程。

### 内核控制

```sh
dsh-ctl status                  # 运行中 / 保活 / launchd / URL
dsh-ctl start                   # 启动
dsh-ctl stop                    # 停止（同时关保活）
dsh-ctl restart                 # 重启（不改变保活设置）
dsh-ctl enable                  # 开启后台保活
dsh-ctl disable                 # 关闭保活
dsh-ctl browser on|off|status   # agent 浏览器权限
```

App 里也有触控入口：右上角菜单 + 加载界面的保活开关。

---

## 依赖替换

### 纯 JS shim（原生 addon 的替代）

| 原生包 | 替代方案 | 文件 |
|---|---|---|
| `@deepseek-ai/node-addon-system`（flock） | 恒成功锁（单实例无竞争） | `shims/node-addon-system__flock.js` |
| `node-addon-require-builtin` | `--expose-internals` + `createRequire` | `shims/node-addon-require-builtin__index.js` |
| `@vscode/ripgrep` | 解析系统 `rg` | `shims/ripgrep-index.js` |
| `sharp` | 纯 JS 解析 PNG/JPEG/GIF/WebP 头 | `shims/ios-image-shim.mjs` |
| `node-pty` | 纯 JS 管道模拟（非真 PTY） | `shims/node-pty-ios/` |

### 代码补丁（`scripts/patch-ios.js`）

| 补丁 | 原因 |
|---|---|
| 目录选择器强制 `browse` 后端 | iOS 报 `darwin` 但无 `osascript`/NSOpenPanel |
| shell 路径 `/var/jb/usr/bin/bash` | iOS 无 `/bin/bash` |
| 会话压缩自适应 | 兼容旧的 `.jsonl` 明文会话，避免 `encodingMismatch` 挂掉 UI |

---

## ⚠️ 功能降级清单

以下功能在 iOS 上**不可用或降级**，代码里已剔除对应依赖（见 `build/scripts/excluded.js`）。

### 完全不可用

| 功能 | 原因 | 计划 |
|---|---|---|
| **Office 渲染/转换** | `libreoffice-kit` 只有 macOS 原生包（140 MB `dsoffice`）和 wasm 版（143 MB `dsoffice.wasm` + `dsoffice.data`） | 纯文本处理走 Python（`python-docx` / `openpyxl` / `python-pptx`） |
| **语音转文字** | `sherpa-onnx` 无 iOS 产物 | 改用 iOS 原生 `SFSpeechRecognizer`（Speech framework） |
| **Computer Use**（桌面应用操控） | `dsh-experimental-cua-macos` 是 macOS 原生实现 | 移植 yithcen 的 `phone-bridge`（SpringBoard 注入，操控整个手机） |
| **托盘图标** | iOS 无托盘概念 | 用灵动岛/角标替代 |
| **自动更新** | iOS 无 autoUpdater | 走 Sileo |

### 降级可用

| 功能 | 降级表现 | 说明 |
|---|---|---|
| **终端 PTY** | `isatty()` 返回 `false` | 纯 JS 管道模拟；`vim`/`top` 等 TUI 程序行为异常，但 `bash -c "..."` 正常 |
| **图片处理** | 只读尺寸/格式 | 不做缩放、转码、滤镜；超过请求尺寸时按原图返回 |
| **内核级沙箱** | 软限制（纯 JS） | 无 landlock（Linux 专属）；不要依赖它做安全边界 |
| **搜索（grep/glob）** | 依赖系统 `rg` | 需 `apt install ripgrep`（Procursus 有 12.1.1-1） |

### 平台专属（不算缺失）

这些包在 mac 上有但 iOS 上**本来就不该有**，已剔除：

| 包 | 说明 |
|---|---|
| `@img/sharp-darwin-arm64` | macOS 原生 libvips |
| `@koromix/koffi-darwin-arm64` | 只被 Win32 分支调用 |
| `@vscode/ripgrep-darwin-arm64` | 换系统 rg |
| `@deepseek-ai/dsh-desktop-host` | Electron 宿主 |
| `@deepseek-ai/dsh-error` | desktop-host 专用 |
| `@deepseek-ai/dsh-deepseek-chat-import` | Electron 导入功能 |

---

## 数据目录

```
/var/mobile/Media/deepseek-harness/
├── workspaces/     工作区（新建项目放这里）
├── config/         配置（dsh.env / credentials / profiles）
├── data/           会话 / 附件 / 存储 / AGENTS.md
├── cache/          pnpm / npm / tmp（可清理）
└── logs/           日志（web.log / app-spawn.log / dsh-daemon.log）
```

**为什么放 Media**：
- 卸载重装**数据不丢**（`/var/jb` 会清空）
- Finder / iTunes 可见，方便导出
- 路径稳定，不随 rootless 前缀变化

`postinst` 会自动从旧路径 `/var/jb/var/mobile/.dsh` 迁移。

---

## 构建

### 本地（从 mac app.asar 提取，推荐）

```sh
cd build
bash build.sh
python3 tools/verify-deb.py dist/*.deb
```

依赖：macOS + DeepSeek Harness.app + node + python3

### CI（GitHub Actions）

三个 job：

1. **build-app** — `macos-15` 编译原生 App（本机无 iOS SDK 时必须走这条）
2. **build-cli** — `ubuntu` 用 npm 装依赖树
3. **package** — 合并产出 deb，tag 时发 Release

推 tag 发正式版：

```sh
git tag v0.2.2-rc.5+ios1
git push origin --tags
```

main 分支自动更新 `latest` Release。

### 剔除规则

**单一真相源**：`build/scripts/excluded.js`

- `extract.js`（本地，从 asar 提取）用它
- `prune.js`（CI，从 npm 装）用它

这样本地和 CI 产出相同的包集合。

---

## 关键约束

- **Node ≥ 24.9.0** 是硬门槛（`lib/bin.js` 用 `import.meta.main`）
- 启动必须带 `--expose-internals`（不能放 `NODE_OPTIONS`）
- `process.platform` 在 iOS 上仍是 `darwin`，需检测 `/var/jb` 区分
- 图片 shim 必须用 `--import` 预加载，否则老对话会 `TRANSPORT`
- `actions/upload-artifact` 默认跳过隐藏文件（`include-hidden-files: true` 必须开）

---

## 已知问题排查

### `zsh: bus error`

iOS 的 `pthread_jit_write_protect_np` 按线程生效，V8 后台线程编译 WASM 时写可执行页被拒。

**自动处理**：`tier.sh` 会探测 5 档，默认 `nowasm`（`--jitless` + `fetch-shim.cjs`）优先。

手动指定：

```sh
DSH_TIER=nowasm dsh
```

### UI 全部 pending

会话压缩格式不匹配：

```
session artifact ".../session.v4.jsonl" uses .jsonl,
but this backend is configured for compression "zstd"
```

**自动处理**：`checkRootEncoding` 和 `findOppositeGenerationInDirectory` 已改成自适应，
检测目录实际格式并切换。

### App 连不上 / 显示未启动

token 抓取路径或 URL 拼接问题。App 会：
1. 从 `Media/deepseek-harness/logs/web.log` 抓 token
2. 剥掉 `baseURL` 的 query（避免 `?token=a/?token=b`）
3. 401 时清 cookie 重抓 token 重试

排查：

```sh
cat /var/mobile/Media/deepseek-harness/logs/web.log
cat /var/mobile/Media/deepseek-harness/logs/app-spawn.log
```

---

## 结构

```
build/
├── build.sh                主构建（本地，从 asar 提取）
├── build-app.sh            原生 App 编译（需 iOS SDK）
├── app-src/                UIKit 外壳（~2000 行）
│   ├── DSHBridge.m         Electron 7 个 preload API
│   ├── DSHBrowserBridge.m  侧边栏浏览器（dshDesktop.browser）
│   ├── DSHBrowserControl.m agent 浏览器 HTTP 端点
│   ├── DSHMenu.m           菜单栏
│   ├── DSHRootVC.m         分栏布局 + 内核探测 + token 处理
│   └── DSHShell.m          posix_spawn（iOS 无 NSTask）
├── payload/                装到设备的脚本（权威来源）
│   ├── DEBIAN/             postinst / prerm
│   └── var/                dsh / dsh-ctl / dsh-doctor / dsh-url / dsh.env / launchd
├── scripts/
│   ├── excluded.js         ⭐ 剔除清单（单一真相源）
│   ├── extract.js          从 app.asar 提取
│   ├── prune.js            CI 裁剪 npm 树
│   └── patch-ios.js        iOS 适配补丁（断言式）
├── shims/                  纯 JS 替代实现
└── tools/
    ├── mkdeb.py            纯 Python deb 生成器
    └── verify-deb.py       deb 校验
```

---

## 相关仓库

- **python-ios** — https://github.com/twoyears666/python-ios
  原生 CPython + pip 交叉编译（独立仓库，编译 30-60 分钟不拖累主项目 CI）
