# iOS 越狱环境说明（自动注入）

你正在一台**越狱 iOS/iPadOS 设备**上运行 DeepSeek Harness。请按以下环境事实调整你的行为。

## 系统事实

- 平台是 iOS（`process.platform` 仍报 `darwin`，但**不是** macOS）
- rootless 越狱，前缀 `/var/jb`
- 无 Electron、无 X11、无图形界面
- **内存受限**：iPhone 通常 3–4 GB，iPad 4–8 GB

## 内存与性能约束（重要）

- 单个进程堆上限约 384 MB（`NODE_OPTIONS=--max-old-space-size=384`）
- **避免**在内存中处理大文件：不要 `cat` 几百 MB 的文件、不要一次读入整个日志
- 读大文件用 `head` / `tail` / `grep` / `sed -n '1,100p'` 分段处理
- 避免并行跑多个重型命令
- 编译类任务（`make`、`npm install`）会很慢，先确认真的必要

## 可用命令

以下命令**已安装**（Procursus）：

- `bash`、`zsh`、`sh`
- `git`
- `rg`（ripgrep）
- 标准 POSIX 工具（`ls`、`grep`、`sed`、`awk`、`find`、`tar`、`gzip`、`xz` 等）
- `python3`（3.9，**不是** 3.12；numpy/pandas/lxml **未安装**）
- `node`（24.19.0，在 `/var/jb/usr/lib/dsh/bin/node`）

以下命令**不存在**，不要使用：

- `osascript`、`open`（macOS 专属）
- `systemctl`、`apt`（Linux 专属；iOS 用 `dpkg` / Sileo）
- `xcodebuild`、`xcrun`、`codesign`（无 Xcode）
- `sips`、`plutil`（macOS 专属，虽然有时 Procursus 有）
- `docker`、`kubectl`

## 路径约定

数据目录：`/var/mobile/Media/deepseek-harness/`

```
workspaces/    工作区（新建项目放这里）
config/        配置
data/          会话 / 附件 / 存储
cache/         可清理的缓存
logs/          日志
```

- **工作区根目录**是 `/var/mobile/Media/deepseek-harness/workspaces`
- 不要往 `/var/jb` 里写用户数据（卸载会丢）
- 不要往 `/tmp` 写重要文件（iOS 会清理）

## 已知功能降级

- **终端不是真 PTY**：`isatty()` 返回 false，`vim`/`top` 等全屏 TUI 程序行为异常。跑非交互命令（`bash -c "..."`）没问题
- **语音转文字**不可用（sherpa-onnx 无 iOS 产物）
- **Office 渲染**不可用（libreoffice-kit 原生包是 macOS 的）
- **图片**走纯 JS 层：只解析头部拿尺寸，不做缩放/转码

## 沙箱

- 沙箱是**软限制**（纯 JS 实现，无内核级 landlock）
- 不要依赖沙箱做安全边界
- 文件操作前先确认路径存在

## 行为建议

1. **先探测再行动**：不确定命令是否存在，先 `command -v xxx`
2. **小步验证**：长任务拆成小步，每步确认结果
3. **避免大输出**：命令输出可能被截断，用 `| head -50` 之类限制
4. **写文件用绝对路径**：相对路径在不同工作区下行为可能不符预期
5. **卸载安全**：用户数据在 Media 下，卸载重装不丢；但 `/var/jb` 下的东西会没

## 调试

- 日志：`/var/mobile/Media/deepseek-harness/logs/`
- 自检：`dsh-doctor`
- URL：`dsh-url`
- 内核重启：`launchctl kickstart -k system/com.twoyears.dsh`
