# dsh-ios — DeepSeek Harness 越狱 iOS 移植

自研移植：把 macOS 版 DSH 的依赖树搬到越狱 iOS/iPadOS（rootless `/var/jb`）。

## 当前状态

| 项 | 状态 |
|---|---|
| 依赖树提取 | ✅ 590 包 → 12,649 文件 / 131.9 MiB |
| 原生 `.node` | ✅ 0 个（3 个纯 JS shim 替代） |
| node 运行时 | ✅ 24.19.0 iOS arm64（自带） |
| pnpm | ✅ 11.28.5 纯 JS（无原生依赖） |
| deb 产物 | ✅ 59.94 MiB |
| `dsh --version` | ✅ 0.2.2-rc.5 |
| `dsh web` | ✅ 监听 + HTTP 200 + UI 加载 |
| 原生 App | ⏳ 待 CI 编译 |

## 结构

```
build/
├── build.sh              主构建脚本
├── scripts/
│   ├── extract.js        从 app.asar 提取 iOS 可移植树
│   └── patch-ios.js      iOS 适配补丁（断言式）
├── shims/
│   └── ripgrep-index.js  ripgrep 路径解析补丁
├── tools/
│   └── mkdeb.py          纯 Python deb 生成器（无需 dpkg-deb）
└── dist/                 产物
```

## 本地构建

```sh
cd build
bash build.sh
# 产物: dist/com.twoyears.dsh_<ver>_iphoneos-arm64.deb
```

## 三个纯 JS shim（替代原生 addon）

| 原包 | 原生依赖 | 替代方案 |
|---|---|---|
| `@deepseek-ai/node-addon-system` | `system.node`（flock） | `flock.js` 恒成功（单实例无竞争） |
| `node-addon-require-builtin` | `*-napi-v9.node` | `--expose-internals` + `createRequire` |
| `@vscode/ripgrep` | `ripgrep-<platform>/bin/rg` | 解析 `/var/jb/usr/bin/rg` 等 |

## 关键约束

- **Node ≥ 24.9.0** 是硬门槛（`lib/bin.js` 用 `import.meta.main`）
- 启动必须带 `--expose-internals`（不能放 `NODE_OPTIONS`）
- `process.platform` 在 iOS 上仍是 `darwin`，需检测 `/var/jb` 区分

## 已知降级

| 功能 | 原因 |
|---|---|
| 语音转文字 | `sherpa-onnx` 无 iOS 产物 |
| Office 渲染 | `libreoffice-kit` 原生包是 macOS 的 |
| 终端 PTY | `node-pty` 无 iOS 预编译 |
| 图片处理 | `sharp` 缺原生（需纯 JS 图片层） |
