# DSH 依赖调研：macOS 基线 → 越狱 iOS/iPadOS 移植缺口

> 调研时间：2026-11-23
> 目标机：越狱 iOS/iPadOS（rootless，`/var/jb`），**JIT 不列为限制条件**
> 基线：DeepSeek Harness Desktop `0.2.2-rc.5`（macOS 15.6.1 / arm64）
> 定位：**自研移植**，参考 `yitenchen123/dsh-ios` 的依赖搬运思路

---

## 一、macOS 侧依赖清单（基线）

### 1.1 运行时三件套（随 App 内置，非系统依赖）

来源：`/Applications/DeepSeek Harness.app/Contents/Resources/runtime/primary-runtime/runtime.json` + `runtime/versions.json`

| 组件 | 版本 | 说明 |
|---|---|---|
| Node.js | **24.21.0** | `dependencies/node/bin/node`，arm64 Mach-O |
| pnpm | **11.28.5** | `dependencies/pnpm/bin/pnpm.cjs`，`engines.node >= 22.13` |
| Python | **3.12.14** | `dependencies/python/`，172 MB，含 pip 26.2.1 |

`runtime.json` 顶层键：`desktopVersion / platform(darwin) / arch(arm64) / payloadDigest / python / node / pnpm / pythonPackages`

**内置 Python 包 13 个**（`pythonPackages` 为 dict，全部实测可 import）：

```
numpy 2.3.5          pandas 3.0.1         python-dateutil 2.9.0.post0
six 1.17.0           tzdata 2025.2        python-docx 1.2.0
python-pptx 1.0.2    openpyxl 3.1.5       Pillow 12.3.0
lxml 6.1.3           XlsxWriter 3.2.9     typing_extensions 4.16.0
et_xmlfile 2.0.0
```

> ⚠️ **注意 `platform` 字段只接受 `x64`/`arm64`**，`arch` 校验里没有 iOS 概念。移植时若照抄 `runtime.json`，`@deepseek-ai/dsh-tool-workspace-dependencies` 的 `parsePrimaryRuntime()` 会在 `platform` 校验处直接抛 `primary runtime: invalid metadata`。

### 1.2 Node 侧包依赖

| 层级 | 数量 | 说明 |
|---|---|---|
| `dsh/package.json` 声明依赖 | **337** | 全部精确锁 `0.2.2-rc.5`，无 `engines`/`os`/`cpu` |
| `dsh/node_modules` 实际顶层 | **590** | 340 个 `@deepseek-ai/*` + 250 个第三方 |
| `@deepseek-ai/dsh` 本体依赖 | **91** | `engines.node >= 24.9.0`（**硬门槛**） |

`@deepseek-ai/dsh@0.2.2-rc.5` 的 registry 元数据与本地一致：91 deps、0 optionalDeps、无 peerDeps、`unpackedSize 6230712`。

**Node 版本门槛是硬性的**：`lib/bin.js` 用 `import.meta.main`（Node 24.2+ 才有），`engines.node >= 24.9.0` 不是 advisory。历史 48 个版本扫描结果：39 个早期版本无 `engines`，8 个为 `>=24.9.0`，1 个为 `^24.22.3 || >=26.13.1`——**没有任何旧版本能在 Node 14/18 上跑**。

### 1.3 原生 `.node` 二进制（全量 10 个）

| 大小 | 路径 | 用途 |
|---|---|---|
| 297,040 | `@img/sharp-darwin-arm64/lib/sharp-darwin-arm64-0.35.5.node` | 图片解码（sharp/libvips） |
| 1,234,208 | `@koromix/koffi-darwin-arm64/darwin_arm64/koffi.node` | FFI（Win32 ACL / 文件系统） |
| 104,832 | `node-pty/prebuilds/darwin-arm64/pty.node` | 终端 PTY |
| 659,136 | `sherpa-onnx-darwin-arm64/sherpa-onnx.node` | 语音识别 |
| 70,384 | `@deepseek-ai/node-addon-system-darwin-arm64/bin/system.node` | `landlock-run` 沙箱启动器 |
| 243,232 | `node-addon-require-builtin-darwin-arm64/prebuilt/darwin-arm64-napi-v9.node` | 加载 Node 私有内部模块 |
| 197,184 | `@deepseek-ai/libreoffice-kit/.../darwin-arm64/frame-forwarding.node` | Office 渲染 |
| 182,704 | 同上 `darwin-x64` | （跨平台预置，非本机用） |
| 209,920 | 同上 `win32-arm64` | （跨平台预置，非本机用） |
| 222,720 | 同上 `win32-x64` | （跨平台预置，非本机用） |

**真正 darwin-arm64 相关的只有 7 个**（后 3 个是 win/x64 预置）。

### 1.4 外部 CLI 依赖（扫描 asar 内 11,601 个 JS 文件得出）

| 命中数 | 命令 | 用途 |
|---|---|---|
| **613** | `git` | 插件安装预检（`execa("git", ["ls-remote"])`）、仓库操作 |
| 49 | `bash` | shell 工具 |
| 27 | `zip` / 10 `tar` / 6 `unzip` | 归档 |
| 22 | `security` | macOS 钥匙串 |
| 9 | `zsh` | shell |
| 8 | `osascript` | 目录选择器 native 后端 |
| 4 | `curl` | 网络 |
| 3 | `rg` | 搜索（有 vendored 兜底） |
| 3 | `python3` | Office / workspace 依赖 |
| 2 | `sips` / `plutil` / `ffmpeg` | 图片 / plist / 媒体 |

**零命中**：`libreoffice`/`soffice`、`pdftoppm`、`magick`、`mdfind`、`say`、`launchctl`、`codesign`、`xattr`。

**`git` 是绝对主导项**（613 次引用），这是移植时最容易被低估的外部依赖。

### 1.5 Electron 层（iOS 上必然没有，不计入“缺失”）

- Electron Framework **44.7.0**（`CFBundleVersion`，该 plist 无 `CFBundleShortVersionString`）
- 主二进制 `MacOS/DeepSeek Harness`，Mach-O 64-bit arm64
- `runtime/cli/bin/dsh` 通过 `ELECTRON_RUN_AS_NODE=1 exec ... cli.js` 启动
- **关键**：`@deepseek-ai/dsh/lib/bin.js`（1,182 字节）**不含任何 Electron 引用**，Electron 耦合只在 `dsh-desktop-host/lib/cli.js` 里 → **CLI 本体不依赖 Electron**，iOS 上走 `dsh web` / `dsh headless` 是可行路径

---

## 二、iOS/iPadOS 侧现状：有什么、缺什么

### 2.1 判定方法

把 `yitenchen123/dsh-ios` 已发布的成品依赖树（`dsh-nodemodules-0.2.2-rc.1+ios1.tar.gz`，90,992,091 字节，73,200 条目）与本机 asar 逐包比对。这是目前**唯一已知的、在真机上跑通过 DSH 的 iOS 依赖树**，可作为“iOS 上究竟需要什么”的实证基准。

### 2.2 总体差距：590 → 572，只差 28 个

| | mac | iOS 成品树 |
|---|---|---|
| 顶层包总数 | **590** | **572** |
| `@deepseek-ai/*` | 340 | 330 |
| 第三方 | 250 | 242 |
| `.node` 原生文件 | **10** | **0** |
| pnpm | 二进制 | **纯 JS 发行版**（1,304 文件） |

**结论先行：iOS 树没有“少一堆包”，只少了 28 个，且全部可归类为平台专属或桌面专属。真正的难点不在包数量，而在 ① Node 版本 ② 7 个原生 `.node` ③ 外部 CLI。**

> ⚠️ **反向差异同样是版本漂移，不是 iOS 特有**：iOS 树里有 8 个 mac 树没有的包 —— `dsh-api-account-controller`、`dsh-deepseek-account-platform`、`dsh-experimental-agent-team`、`dsh-experimental-agent-team-profile`、`dsh-experimental-client-ui-agent-team`、`dsh-experimental-tool-agent-team`、`dsh-office-to-pdf`、`@earendil-works/pi-schema`。这是 **rc.1 → rc.5 之间包改名/拆分**的结果，不是平台差异。移植到 `0.2.2-rc.5` 时**以 mac 的 590 个包为准**，不要照抄 iOS 树的包名。
>
> 同理，`@deepseek-ai/dsh` 的 91 个依赖在 iOS 树里是 rc.1 版本（90 个），两者共有 89 个，其中 **81 个版本号是 `0.2.2-rc.1` 而非 `0.2.2-rc.5`**，另有包名差异（mac 独有 `dsh-cua-bundle`、`dsh-deepseek-chat-import`；iOS 独有 `dsh-experimental-agent-team-profile`）。

### 2.3 缺失清单（mac 有、iOS 树无）——28 个，按成因分类

#### A. 平台二进制包（10 个）→ iOS 永远不会有，必须替换或剔除

| 包 | 替代方案 |
|---|---|
| `@img/sharp-darwin-arm64` + `@img/sharp-libvips-darwin-arm64` + `@img/colour` | 纯 JS 图片层（见 2.4） |
| `@koromix/koffi-darwin-arm64` | koffi 只被 Win32 路径调用，可剔除 |
| `@vscode/ripgrep-darwin-arm64` | 装 Procursus `ripgrep`，或改 `rgPath` |
| `sherpa-onnx-darwin-arm64` + `sherpa-onnx-node` | 语音功能降级（按需） |
| `@deepseek-ai/libreoffice-kit-darwin-arm64` | Office 渲染降级，或走 wasm 版 |
| `@deepseek-ai/node-addon-system-darwin-arm64` | 纯 JS `flock` shim（见 2.4） |
| `node-addon-require-builtin-darwin-arm64` | `--expose-internals` + `createRequire`（见 2.4） |

#### B. 原生但非平台包（1 个）

`node-pty` —— 终端 PTY。iOS 无预编译产物，且 `requireNodePty` 是懒加载（不 spawn 终端就不加载），但一旦用到会抛错。

#### C. 桌面专属（Electron 宿主，6 个）→ iOS 不需要

`@deepseek-ai/dsh-desktop-host`（依赖 `koffi`）、`dsh-error`、`dsh-deepseek-chat-import`、`dsh-mcp-manager`、`dsh-terminal-panel`、`dsh-client-ui-account-notifications`

#### D. CUA 屏幕控制（4 个）→ iOS 上由原生 MCP 桥替代

`dsh-cua`、`dsh-cua-bundle`、`dsh-computer-use`、`dsh-experimental-cua-macos`

> iOS 侧的等价物是 `phone-bridge`：`dsh-ios-control.dylib`（812,976 字节）+ `HUDOverlay`，通过 SpringBoard 注入实现点按/滑动/输入/截图，暴露 `mcp__ios__*` 工具。

#### E. Office + Agent Team（5 个）→ 可降级

`dsh-office-kit`、`dsh-tool-office`、`dsh-agent-team`、`dsh-tool-agent-team`、`dsh-client-ui-agent-team`

> 注意：`@deepseek-ai/libreoffice-kit` **本体在 iOS 树里是存在的**（66 个文件），只是没有 `-darwin-arm64` 原生包。它还有 `@deepseek-ai/libreoffice-kit-wasm` 这个 optional 备选，但**iOS 树里也没装**。

#### F. 其他（2 个）

`@deepseek-ai/dsh-util-ripgrep`（`@vscode/ripgrep` 的包装层）、`typebox`

> 合计：10 + 1 + 6 + 4 + 5 + 2 = **28**

### 2.4 三个纯 JS shim（移植的核心技巧）

`dsh-ios` 用两个 500～1,500 字节的文件顶掉了两个原生 addon，这是最值得直接搬的部分：

**① `@deepseek-ai/node-addon-system/lib/flock.js`（548 字节）**

```js
// 原实现在首次 session 持久化时加载 per-platform 原生 .node 调用 POSIX flock。
// iOS arm64 无对应产物，headless profile 会报
//   "Cannot find module '@deepseek-ai/node-addon-system-linux-x64/package.json'"。
// 单实例终端场景下不存在多进程争抢同一个 session 文件，锁恒成功即等价语义。
export async function tryLockExclusive(_fd) { return; }
export async function tryLockShared(_fd) { return; }
```

**② `node-addon-require-builtin/lib/index.js`（1,558 字节）**

```js
// 原实现通过 node-addon-native-custom-loader 加载原生 .node，
// 用来 require() Node 的私有内部模块（internal/modules/*）。
// Node 自带的 --expose-internals 可以让普通 createRequire() 直接加载这些内部模块。
const { createRequire } = require("node:module");
const _req = createRequire(__filename);
function requireBuiltin(moduleId) { return _req(moduleId); }
function isAllowedInternalId(moduleId) {
  return typeof moduleId === "string" &&
    (moduleId.startsWith("internal/") || moduleId.startsWith("node:internal/"));
}
```

> 前提：启动脚本必须带 `--expose-internals`（不能放 `NODE_OPTIONS`，Node 会拒绝）。

**③ 图片层 `ios-image-shim.mjs`（17,117 字节）**

`sharp` 缺失的后果**不是“图片功能降级”，而是老对话直接崩**：

- `prepareImages()` 遍历历史里每一张图 → 任一图触发 sharp 加载失败 → 整个 request 抛错 → 被包成 `LlmError("DeepSeek Messages transport failed","TRANSPORT")` → 前端 **5/5 重试全失败**
- 新图上传 `saveImages() → prepareImageFile() → detectImage()/normalizeImage()` 同样要 sharp

修法：用 Node `--import` 预加载，运行时替换 `LocalAttachmentStore` 的 `readImage / readImageRequest / saveImage / saveImages / validateImage` 五个方法，纯 JS 解析 PNG/JPEG/GIF/WebP 头，对象缺失退化成 1×1 PNG。**只用 Node 内置模块、jitless 可跑、不改 node_modules**（升级 rc.x 仍生效）。

### 2.5 关键判断：哪些“缺失”其实不是缺失

| 项 | 结论 |
|---|---|
| `koffi` | **不需要**。全部调用点都在 `win32()` 分支里（`dsh-fs-local`、`dsh-session-persistence-jsonl`、`libreoffice-kit` 的 `windowsPipes()`），darwin/iOS 路径不碰 |
| `node-pty` | **只在真终端时用**。`requireNodePty` 是 `createLazyRequire` 懒加载，不 spawn 终端就不加载；但一旦用到会抛错 |
| `sherpa-onnx` | **懒加载**（`createRequire(import.meta.url)("sherpa-onnx-node")` 在 `createTranscriber()` 内），只影响语音转文字 |
| `libreoffice-kit` | 本体存在，仅缺原生包 → Office 渲染降级，不影响启动 |
| `@vscode/ripgrep` | 会在**首次搜索调用**时以 `SEARCH_FAILED` 报错（不是启动失败），可换系统 `rg` |
| PTC Python | **不需要独立 Python**。`dsh-ptc-runtime-node` 用 `process.execPath`（复用包内 node），Python 只是生成 SDK 文本的语言 flavor |

### 2.6 真正的三个硬缺口

#### 缺口 ①：Node 版本（最关键）

| 来源 | 版本 | 满足 `>=24.9.0` |
|---|---|---|
| Procursus `nodejs` | **14.13.1** | ❌ 差 10 个大版本 |
| Procursus `npm` | 6.14.8 | ❌ |
| `nodejs-mobile` 最新 iOS 产物 | **18.20.4** | ❌ |
| Node 官方 unofficial-builds | **0 个 iOS 文件** | ❌ |
| `yitenchen123/dsh-ios` 自编译 | **24.19.0** | ✅ 唯一可用 |
| Alpine edge + iSH | 26.13.1 | ✅ 但是 x86_64 模拟 Linux |

**Procursus 是越狱机上唯一的 node/python 来源**，已核查 Chariz（1,308 stanza）、Havoc、Packix、CydiaKK、Dynastic、Bingner、Akemi —— **全部零 `nodejs`/`node`/`python3`/`npm`/`pnpm` 包**。

唯一现成的 `>=24.9.0` iOS arm64 成品：

```
node-v24.19.0-iphoneos-arm64-jit   82,539,696 字节
SHA-256  8bebb2a2e45824f9880ac99141ce0ee9359ec4fad72ccd1ef27bcd1341d77697
```

已实测验证文件头为 `Mach-O 64-bit arm64`、`cputype=0x0100000c`、`filetype=2`（executable）。来源：GitHub Actions run `43532556241`（`workflow_dispatch`，`node_ref=v24.19.0`，编译 2h36m）。

#### 缺口 ②：原生 `.node`（7 个 darwin-arm64）

iOS 上**没有任何一个**有 arm64-iOS 预编译产物。三条出路：
1. **纯 JS shim**（已验证可行：flock、require-builtin、sharp）
2. **源码交叉编译**（Procursus 有 clang 16 / swift 5.9 / make / cmake，理论上可编）
3. **功能降级**（语音、Office、终端）

#### 缺口 ③：外部 CLI

| 命令 | Procursus 版本 | 状态 |
|---|---|---|
| `git` | **2.39.1**（29,680 KB） | ✅ 可装 |
| `bash` | 5.2.21 / 5.2.37 | ✅ 可装 |
| `zsh` | 5.9 | ✅ 可装 |
| `ripgrep` | 12.1.1-1 | ✅ 可装 |
| `openssh-server` | 9.7p1-1 | ✅ 可装 |
| `python3` | **3.9.9-1** | ⚠️ 版本低（DSH 内置 3.12.14） |
| `security` / `osascript` / `sips` / `plutil` / `sw_vers` | — | ❌ macOS 专属，无替代 |

`security`/`osascript` 这类只在桌面宿主路径用到；`osascript` 对应 `directory-picker-native` 后端，iOS 上需强制切 `browse` 后端（纯 `node:fs/promises`）。

### 2.7 Python 侧

| 项 | mac | iOS (Procursus) | 缺口 |
|---|---|---|---|
| 解释器 | 3.12.14 | **3.9.9-1** | 低 3 个小版本 |
| pip | 26.2.1（内置） | 需 `python -m ensurepip` | 需手动 bootstrap |
| numpy 2.3.5 | 有 | **PyPI 零 iOS wheel** | 需源码编译 |
| pandas 3.0.1 | 有 | **PyPI 零 iOS wheel** | 需源码编译 |
| lxml 6.1.3 | 有 | **PyPI 零 iOS wheel** | 需源码编译 |
| Pillow 12.3.0 | 有 | **45 个 iOS wheel**（含真机 `ios_13_0_arm64_iphoneos`） | ✅ 可 pip 装 |
| python-docx / python-pptx / openpyxl / XlsxWriter | 有 | 纯 Python | ✅ 可装 |

> 只有 Pillow 有真机 iOS wheel；numpy/pandas/lxml 必须交叉编译。不过 **Office/Python 相关能力属于可降级项**，不阻塞核心移植。

---

## 三、补齐建议（自研移植路线）

### 3.1 路线选择

| 方案 | 可行性 | 说明 |
|---|---|---|
| **A. 自研 rootless deb（推荐）** | ✅ | 搬 `dsh-ios` 的依赖树 + shim，自己做打包 |
| B. 直接装 `dsh-ios` 的 deb | ⚠️ | 109 MB，`+ios24.12`；但它是别人的构建，改不动 |
| C. iSH + Alpine | ❌ | node 26 满足版本，但 x86_64 模拟，所有 darwin-arm64 原生包全要换 linux-x64，且性能不可接受 |
| D. 远程 `dsh web` | ✅ | 最省事：mac 上 `dsh --profile web --host <局域网IP>`，iPad Safari 打开 |

### 3.2 依赖搬运清单（按优先级）

**P0 — 必须解决，否则起不来**

1. **Node ≥ 24.9.0 iOS arm64 可执行文件**
   - 直接用 `node-v24.19.0-iphoneos-arm64-jit`（SHA `8bebb2a2…`）
   - 或照 `node24-jit.yml` / `node24-jitless.yml` 自己编（`--without-npm --without-inspector --with-intl=small-icu --without-node-snapshot --without-node-code-cache --openssl-no-asm`）
   - 越狱机需 `ldid -S` 签 `dynamic-codesigning` 等 10 项 entitlement

2. **官方 npm 依赖树**
   ```sh
   npm install --omit=optional --no-audit --no-fund "@deepseek-ai/dsh@0.2.2-rc.5"
   ```
   `--omit=optional` 会自动跳过全部平台二进制包 → 得到 572 个包、0 个 `.node`

3. **两个纯 JS shim**（直接复制）
   - `shims/node-addon-system__lib__flock.js` → `node_modules/@deepseek-ai/node-addon-system/lib/flock.js`
   - `shims/node-addon-require-builtin__lib__index.js` → `node_modules/node-addon-require-builtin/lib/index.js`
   - 启动参数必须带 `--expose-internals`

4. **纯 JS pnpm**
   - 用 `bundles/pnpm/dist`（1,304 文件），`exec node pnpm.cjs`，不走 PATH
   - store/cache 全部落到 `$DSH_HOME`

**P1 — 影响功能，建议解决**

5. **图片层** `ios-image-shim.mjs` —— 不做的话**老对话必崩**（TRANSPORT 5/5 重试），优先级比想象中高
6. **Procursus 装 CLI**：`git`、`bash`、`ripgrep`、`openssh-server`
7. **目录选择器强制 browse 后端**（iOS 无 `osascript`/NSOpenPanel）
8. **会话压缩改 `none`**（若用 Node 22；用 Node 24 原生支持 zstd 可跳过）

**P2 — 可降级**

9. 语音（sherpa-onnx）、Office 渲染（libreoffice-kit 原生包）、终端 PTY（node-pty）
10. Python 3.12 + numpy/pandas/lxml（需源码编译，工作量大）

### 3.3 必须改的代码锚点（4 处）

| 文件 | 原串 | 改法 |
|---|---|---|
| `@deepseek-ai/dsh/lib/bin.js` | `if (import.meta.main) await runCli();` | `await runCli();`（仅 Node < 24.2 需要） |
| `dsh-session-persistence-jsonl/lib/index.js` | `const DEFAULT_COMPRESSION = "zstd";` | `"none"`（仅 Node < 22.15 需要） |
| `dsh-ptc-runtime-node/lib/index.js` | `import { stripTypeScriptTypes } from "node:module";` | 动态取值 + 直通（仅 Node < 22.13 需要） |
| `dsh-host-directory-picker-native` | native 后端选择 | 强制 `browse` |

> 用 **Node 24.19.0** 时，前 3 处**都不需要**（zstd / `stripTypeScriptTypes` / `import.meta.main` 全部原生支持）——这是选 Node 24 而非 22 的额外好处。

### 3.4 打包骨架

```
/var/jb/
├── usr/bin/dsh                    # 入口 wrapper（--expose-internals）
├── usr/bin/pnpm                   # 纯 JS pnpm wrapper
├── usr/lib/dsh/
│   ├── bin/node                   # node 24.19.0 iOS arm64
│   ├── node_modules/              # 572 包依赖树
│   └── libexec/pnpm/              # 纯 JS pnpm
├── etc/dsh/dsh.env                # NODE_OPTIONS 等
└── Library/LaunchDaemons/         # 常驻（可选）
```

### 3.5 验证清单

```sh
# 1) 零原生依赖
dpkg-deb -c dist/*.deb | grep -c '\.node$'        # 应为 0

# 2) node 版本
/var/jb/usr/lib/dsh/bin/node -v                   # v24.19.0

# 3) CLI 能起
/var/jb/usr/bin/dsh --version

# 4) web 真监听
/var/jb/usr/bin/dsh web --no-open --port 3080

# 5) 会话写入 + 恢复（重启后还在）

# 6) 图片：老对话发消息不 TRANSPORT
```

### 3.6 关于 `dsh-ios` 的定位

它是**参考实现，不是依赖**。可搬的部分：
- ✅ 两个纯 JS shim（548 + 1,558 字节，直接复制）
- ✅ `ios-image-shim.mjs`（17 KB）
- ✅ 纯 JS pnpm 发行版
- ✅ node 24.19.0 二进制 + CI workflow
- ✅ 打包骨架与验证脚本思路

不必搬的部分：
- ❌ tier.sh 五档探测（JIT 不限，可省）
- ❌ `fetch-shim.cjs`（仅 `--jitless` 档需要）
- ❌ 手机操控 `phone-bridge`（除非要 `mcp__ios__*`）
- ❌ Safari 16 垫片（除非目标机是 iOS 16 且用 Web UI）

**它的目标机是 iPhone X / A11 / iOS 16.7.15 / Dopamine 3.0 rootless**，与我们的设备不一定一致 → **兼容性必须实测，不能假设**。

---

## 附：一句话总结

**iOS 侧不缺包（590 → 572，差的 28 个全是平台/桌面专属），缺的是 ① Node ≥24.9.0 的 arm64-iOS 可执行文件（唯一现成成品是自编译的 24.19.0）② 7 个原生 `.node` 的 iOS 版本（可用 3 个纯 JS shim + 降级解决）③ `git`/`bash`/`rg` 等外部 CLI（Procursus 可装）。**
