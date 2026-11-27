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
| `BrowserWindow` + `titleBarStyle: hidden` | 一个全屏 `WKWebView`（导航栏隐藏） |
| `vibrancy: sidebar` | web UI 自己渲染，原生不掺和 |
| 菜单栏（123 处 `Menu`） | `UIMenu`（右上角悬浮 ⋯ 按钮：会话/视图/内核/关于） |
| `dialog.showOpenDialog` | `UIDocumentPickerViewController` + 安全书签 |
| `shell.openExternal` | `UIApplication.openURL`（scheme 白名单） |
| `app.getPath` | 路径映射（home/userData/temp/documents…） |
| `window.close` | 降级为日志（iOS 无窗口概念） |
| 语音转文字（sherpa-onnx） | `SFSpeechRecognizer`（见「语音输入」） |
| 托盘 | ❌ iOS 无此概念 |
| 自动更新 | ❌ 走 Sileo |

### 外壳为什么这么薄

原生侧**只做 web UI 做不到的事**：

| 原生负责 | 为什么 web UI 做不了 |
|---|---|
| 内核进程生命周期 | 内核还没起来时页面根本加载不出来 |
| 7 个 preload API | 需要 `WKUserContentController` 注入 |
| agent 浏览器 tab | 需要真的 `WKWebView`（原生里的 iframe） |
| 语音输入 | `SFSpeechRecognizer` / `AVAudioEngine` |
| 进程枚举 | `sysctl(KERN_PROC_ALL)` |
| 启动遮罩 + 保活开关 | 同上，页面不可用 |

其余一律交给 web UI：侧边栏、会话列表、设置页、消息流。
之前那版用 `UISplitViewController` + `UITableView` 把侧边栏又写了一遍，
结果是两边不一致、web 前端改版原生侧还要跟着改 —— 已经删掉。

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
dsh-ctl status                  # 运行中 / 保活 / launchd / URL / 版本 / 外壳
dsh-ctl start                   # 启动
dsh-ctl stop                    # 停止（同时关保活）
dsh-ctl clear                   # 强制清除进程（关保活 + 杀干净 + 等端口释放）
dsh-ctl ps                      # 看内核进程（pidfile / 端口 / launchd）
dsh-ctl restart                 # 重启（不改变保活设置）
dsh-ctl enable                  # 开启后台保活
dsh-ctl disable                 # 关闭保活
dsh-ctl browser on|off|status   # agent 浏览器权限
```

**App 里的触控入口**（不需要终端）：

| 位置 | 控件 | 作用 |
|---|---|---|
| 右上角菜单 → 内核 | 启动 / 停止 / 重启 | 常规控制 |
| 右上角菜单 → 内核 | **清除进程** | 关保活 + 杀光内核进程，用于「升级后旧内核还占着端口」 |
| 右上角菜单 → 内核 | 运行自检 | 跑 `dsh-doctor` |
| 右上角菜单 → 内核 | **进程列表** | `sysctl` 原生枚举，不依赖 `ps` |
| 加载界面 | 后台保活 开关 | 只控制后台保活 |
| 加载界面 | **清除进程** 按钮 | 同菜单项 |

`clear` 与其它命令的区别：

- `stop` —— 停服务并关保活，但保留 launchd 注册（下次开机仍会自启）
- `disable` —— 只关保活，不动正在跑的进程
- `restart` —— 重启，**会恢复**原来的保活状态
- `clear` —— 关保活 + 杀进程 + **不会**恢复保活；专治「旧版本内核占着 3080」

### 内核由谁拉起：`dsh-supervise`

真机日志证明了一件很关键的事：**App 进程不允许 exec 任何外部程序**。

```
access("/var/jb/usr/bin/dsh", X_OK) → 成功
posix_spawn("/var/jb/usr/bin/dsh")  → rc=2 ENOENT
access("/bin/launchctl", X_OK)      → 失败
```

也就是说「文件存在、可执行」和「能 exec」是两回事。所以 App 里
起内核、调 `dsh-ctl`、跑 `dsh-doctor`、读 `node --version` 全部失败。

于是把「谁负责起内核」交给 launchd：

```
launchd
  └─ dsh-supervise（死循环，长期驻留）
       └─ dsh web --no-open --port 3080
```

App 只用两种**不需要 exec** 的手段控制它：

| 手段 | 用在哪 |
|---|---|
| 标记文件 | `config/kernel.want` / `config/keepalive.disabled` |
| 信号 | 读 `config/kernel.pid`，`kill(pid, SIGTERM)` → `SIGKILL` |

判定逻辑（监督脚本里）：

| `kernel.want` | `keepalive.disabled` | 结果 |
|---|---|---|
| 有 | 任意 | 起（用户显式要求） |
| 无 | 无 | 起（开机自启） |
| 无 | 有 | 停 |

对应到 App 的操作：

| 操作 | 动作 |
|---|---|
| 打开 App | 写 `kernel.want` |
| 启动内核 | 写 `kernel.want` |
| 停止 / 清除进程 | 删 `kernel.want` + 写 `keepalive.disabled` + 杀 pid |
| 重启 | 写 `kernel.want` + 杀 pid（监督进程自动拉起新的） |
| 开启保活 | 删 `keepalive.disabled` + 写 `kernel.want` |
| 关闭保活 | 写 `keepalive.disabled`（内核继续跑） |

「运行自检」也不再调 `dsh-doctor`（exec 不了），改成原生自检：
越狱环境 + 版本 + pidfile + `sysctl` 进程列表。

### 打包前本地验证：`verify-payload.sh`

```sh
sh build/scripts/verify-payload.sh
```

CI 里也跑（`build-cli` 的第一步，几秒出结果）。它检查的是**两次真机事故的
模式**，不是风格问题：

| 红线 | 来自哪次事故 |
|---|---|
| 维护者脚本不许有 `set -e` | 诊断命令失败 → postinst 非 0 退出 → dpkg 半配置 → Sileo 打不开 |
| 用了 `set -u` 就必须保证变量都有定义 | `.48` 里 `set -u` + 未定义的 `$LABEL` → 脚本在 §5.3 中止 → dpkg 又一次半配置 |
| 不许 `kill "$变量"`（裸 PID） | pidfile 过期 + PID 回收 → root kill 可能命中 SpringBoard → 重启 |
| 不许 `pkill -9` | 不给进程清理机会 |
| 不许 `nohup` | 安装中拉起 300MB node，与 uicache 的 respring 叠加 |
| 必须以 `exit 0` 结束 | 同上，别让安装因为非关键步骤失败 |
| shebang 必须是 `#!/bin/sh` | iOS 上可能找不到解释器 |
| plist 的启动目标必须存在且可执行 | 否则 launchd 静默不启动 |
| `var/jb/usr/bin/*` 必须有执行位 | 否则装上去 EACCES |
| **运行期脚本**也不许裸 PID `kill`（`dsh-supervise` 以 mobile 跑，SpringBoard 也是 mobile） | 误杀 = respring |

另外还有两类提示（不阻塞）：维护者脚本里可能失败又没兜底的命令、
`control` 文件里出现 Debian 不支持的 `#` 注释。

**这个脚本本身也验证过**：往 payload 里注入 `set -e`、裸 PID `kill`、
`pkill -9`、`nohup`、`set -u` + 未定义变量，全部被拦下、退出码 1。

校验项覆盖的正是已经发生过的三次事故：

1. `set -e` → 诊断命令失败 → dpkg 半配置
2. root/mobile 下对裸 PID `kill` → 误杀系统进程 → 重启 / respring
3. `set -u` + 未定义变量 → 维护者脚本中途退出 → 又是半配置

### 两层闸门：构建时 + 装包时

同一个检查做两遍，因为它们挡的是不同来源的包：

| 层 | 位置 | 挡谁 |
|---|---|---|
| 构建时 | `build/scripts/verify-payload.sh`（CI 第一步） | 自己改出来的回归 |
| **装包时** | `DEBIAN/preinst`（设备上，dpkg 解包**之前**） | **任何来源的包**，包括别人给的、手工拼的 |

`preinst` 在 dpkg 解包前执行，这时新包的 `postinst` / `prerm` 已经被解到
`/var/jb/var/lib/dpkg/info/` 了 —— 也就是说它检查的正是**马上要生效的那一版**。
命中红线就 `exit 1`，dpkg 在解包前中止，**旧版本保持原样，不会留下半配置状态**。

所以哪怕有人塞一个带 `set -e` 或裸 PID `kill` 的 deb 进来，只要它带着
本 `preinst`，装之前就会被拦下。

设计上刻意保守：

- 只读，不改任何东西
- 没有 `grep` 就跳过检查、直接放行 —— 宁可放过，不可错杀
- 只有确认命中红线才 `exit 1`
- 日志写不了就关掉，不影响判定

`preinst` 自己含 `pkill -9` / `nohup` 这些**模式字符串**，会被构建时的
`verify-payload.sh` 误判，所以它声明了 `verify-allow-patterns` 豁免标记；
豁免只跳过模式匹配类检查，`set -e` / `exit 0` / shebang 照样查。

### 别用 `launchctl disable`

`dsh-ctl stop` / `disable` 以前会调 `launchctl disable system/com.twoyears.dsh`，
作用是「别让 launchd 再拉起它」。但这会往 launchd 的 **disabled 覆盖表**里写一条记录，
之后 `launchctl bootstrap` 会被直接拒绝 —— 而且失败被 `|| true` 吞掉，日志里什么都看不到。

真机上的表现就是：装完新版本，内核不跑、`supervise.log` 压根不存在、
`pidfile (无)`，但 deb 明明装上了。

现在：
- `stop` / `disable` 完全不碰 launchd，只写标记文件 + 杀进程
- 「该不该跑」由 `dsh-supervise` 读标记判断，不需要卸载 job
- `postinst` 注册后会打印 `launchctl print` / `print-disabled` / 端口状态到
  `logs/install.log`，并且**如果 launchd 没接住就直接把监督进程拉起来兜底**

### 回环免 token

内核原本对**所有**请求都要 token：访问 `/` 不带 token 直接 401。
移植版的 App 就是同一台设备上的 WKWebView 外壳，回环上再套一层 token 只有坏处：

- App 每次要去 `web.log` 里正则抓 token，旧日志 / 多实例时会抓错
- 抓不到就 401，界面卡在「未启动」，而且很难看出是认证问题
- 用户自己 `curl 127.0.0.1:3080` 调试也被挡住

所以 `patch-ios.js` 里加了两个补丁，把 `@deepseek-ai/dsh-client-connection`
的两处鉴权入口对回环放行：

| 位置 | 作用 |
|---|---|
| `authorizeIndex()` | 页面本身（`/`） |
| `admit()` | `/api` 与 socket 升级 |

判据是 `req.socket.remoteAddress`，**不看 Host 头**（Host 可以伪造）。
放行范围只有 `127.0.0.1` / `::1` / `::ffff:127.0.0.1`。

App 侧相应改成**先不带 token 加载**；只有在响应决策阶段真的收到 401
（说明跑的是没打补丁的旧内核）才回退到抓 token 的老流程。

⚠️ 安全边界：这意味着**设备上任何进程**都能不带认证访问 `127.0.0.1:3080`，
包括其它 App 和越狱插件。这是「回环免 token」本身的性质，
只在单人自用的越狱设备上成立；不要把这个 deb 装到别人也能用的机器上。

### 升级时自动停掉旧内核

`postinst` 会先执行 `dsh-ctl clear` 再重新注册 launchd。只 `bootout` 是不够的：
App 通过 `posix_spawn` + `POSIX_SPAWN_SETSID` 拉起的内核已经脱离进程组，
不归 launchd 管，`bootout` 之后照样占着 3080 端口 ——
新 App 探测到端口已通就直接复用，表现就是「更新了但没生效」。

扫描只针对**本移植版**（模式是完整安装路径
`/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js`），
不会误杀设备上用 npm 全局安装的 dsh 或别的越狱包。

### 日志

| 文件 | 内容 |
|---|---|
| `logs/app.log` | **外壳自己的启动记录**（含「=== App 启动 外壳 X 内核 Y ===」） |
| `logs/web.log` | 内核输出，含带 token 的访问 URL |
| `logs/app-spawn.log` | 内核由 App 拉起时的 stdout/stderr |
| `logs/dsh-daemon.log` | launchd 拉起时的 stdout（通常被 `web.log` 覆盖，0 字节属正常） |
| `logs/ctl.log` | 每次 `dsh-ctl` 操作的时间戳记录 |

`dsh-ctl status` 会把 `版本`（装的是哪个 deb）和 `外壳`（App 上次启动记录的内核号）
并排打出来；两者对不上就说明跑着的还是旧内核。

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
| **Computer Use**（桌面应用操控） | `dsh-experimental-cua-macos` 是 macOS 原生实现 | 移植 yithcen 的 `phone-bridge`（SpringBoard 注入，操控整个手机） |
| **托盘图标** | iOS 无托盘概念 | 用灵动岛/角标替代 |
| **自动更新** | iOS 无 autoUpdater | 走 Sileo |

### 语音输入（已实现，替代 sherpa-onnx）

mac 桌面端的语音转文字用 `sherpa-onnx`，没有 iOS 产物。
iOS 上改用系统自带的 **Speech framework**（`SFSpeechRecognizer`）：

| 项 | 说明 |
|---|---|
| 入口 | 右上角菜单 → 视图 → **语音输入**（再点一次结束） |
| 录音 | `AVAudioEngine` + `AVAudioSession`（`PlayAndRecord` / `Measurement`） |
| 识别 | `SFSpeechRecognizer`，优先 `zh-CN`，没有中文模型时退回系统语言 |
| 结果 | 边说边出字；最终文字插进当前聚焦的输入框 |
| 插不进去 | 自动复制到剪贴板并提示「长按粘贴」 |
| 体积 | 0 —— 不带任何模型文件，也不加依赖 |

限制：

- 需要联网（除非系统装了本地识别模型）
- 单次识别约 60 秒上限（系统限制），说完再点一次即可
- 需要 `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`，
  缺任一条 iOS 会直接 crash —— `build-app.sh` 会在编译期拦住

### 降级可用

| 功能 | 降级表现 | 说明 |
|---|---|---|
| **终端 PTY** | `isatty()` 返回 `false` | 纯 JS 管道模拟；`vim`/`top` 等 TUI 程序行为异常，但 `bash -c "..."` 正常 |
| **图片处理** | 只读尺寸/格式 | 不做缩放、转码、滤镜；超过请求尺寸时按原图返回 |
| **内核级沙箱** | 软限制（纯 JS） | 无 landlock（Linux 专属）；不要依赖它做安全边界 |
| **搜索（grep/glob）** | 依赖系统 `rg` | 需 `apt install ripgrep`（Procursus 有 12.1.1-1） |
| **语音输入** | 走系统识别服务 | 不占体积，但受系统 60 秒 / 联网限制；见上节 |

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
cat /var/mobile/Media/deepseek-harness/logs/app.log
```

### `spawn rc=2` / `posix_spawn 失败 (2): No such file or directory`

真机上出现过：App 里点任何需要执行命令的功能（启动内核、清除进程、自检、
关于页的 Node 版本）全部失败，而内核本身跑得好好的（launchd 起的）。

原因：iOS 给 App 的沙盒扩展通常只覆盖它自己的 bundle。
`/var/jb` 是指向 `/private/preboot/<hash>/.../procursus` 的符号链接，
**App 进程解析不到这条链接**，`access()` / `posix_spawn()` 直接 ENOENT；
而 launchd（root）和 postinst（root）都能正常解析。

所以现在：
- 启动时把 `/var/jb`、bundle 路径、`/bin/launchctl` 以及
  `usr/bin/dsh`、`usr/bin/dsh-ctl`、`usr/lib/dsh/bin/node` 的探测结果
  全部写进 `app.log`（`=== 越狱环境 ===` / `=== 工具解析 ===`）
- 工具路径按候选解析：`/var/jb/<rel>`，再从自身 bundle 反推
  `<root>/Applications/DSH.app` → `<root>/<rel>`
- `dsh-doctor` 起不来时，「运行自检」自动退化成**原生自检**
  （越狱环境 + 版本 + pidfile + 进程列表），不会弹空框

### 更新了但没生效（还是旧界面 / 日志不刷新）

典型症状：Sileo 显示已装新版本，但 App 打开还是老样子，
`web.log` 的修改时间停在升级之前。

原因：旧内核进程没死。App 探测到 3080 端口已通就直接复用，
于是新 App 连的是老内核。App 用 `posix_spawn` 拉起的内核脱离了进程组，
`launchctl bootout` 管不到它。

处理（不用终端）：

1. 右上角菜单 → 内核 → **清除进程**
2. 重新打开 App

`postinst` 现在会在安装时自动做这一步，正常情况下不该再遇到；
遇到了就是有别的进程占着 3080，`dsh-ctl status` 会提示
`⚠ 端口 3080 仍在监听，可能有其它实例`。

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
