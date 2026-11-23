#!/bin/bash
# ============================================================================
# build.sh —— 构建 dsh iOS rootless deb
#
# 产物结构（rootless，前缀 /var/jb）：
#   /var/jb/usr/lib/dsh/
#       bin/node                    iOS arm64 node 24.19.0（自带）
#       node_modules/               dsh 依赖树（纯 JS，0 个 .node）
#       package.json                 @deepseek-ai/dsh-desktop-runtime
#       desktop-runtime.json
#       libexec/pnpm/               纯 JS pnpm（可选）
#   /var/jb/usr/bin/dsh             入口 wrapper
#   /var/jb/usr/bin/dsh-doctor      诊断
#   /var/jb/etc/dsh/dsh.env         默认配置
#   /var/jb/Library/LaunchDaemons/  launchd 守护（可选）
#   /var/jb/Applications/DSH.app    原生 UIKit App（需 CI 编译）
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work"
ROOT="$HERE/root"
DIST="$HERE/dist"
DL="$WORK/dl"
NM="$WORK/nodemodules"

APP="${DSH_APP:-/Applications/DeepSeek Harness.app}"
ASAR="$APP/Contents/Resources/app.asar"

VERSION="${DSH_VERSION:-0.2.2-rc.5}"
PKGVER="${DSH_PKGVER:-${VERSION}+ios1}"
PKGID="com.twoyears.dsh"
ARCH="iphoneos-arm64"

# Node 运行时：优先用已下载的，否则从 Release 拉
NODE_URL="${DSH_NODE_URL:-https://github.com/yitenchen123/dsh-ios/releases/download/node24-exp/node-v24.19.0-iphoneos-arm64-jit}"
NODE_SHA="${DSH_NODE_SHA:-8bebb2a2e45824f9880ac99141ce0ee9359ec4fad72ccd1ef27bcd1341d77697}"
NODE_BIN="$DL/node24-ios"

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 预检
log "预检"
[ -f "$ASAR" ] || die "找不到 $ASAR"
command -v node >/dev/null || die "需要 node 跑 extract.js"
command -v python3 >/dev/null || die "需要 python3 跑 mkdeb.py"

mkdir -p "$WORK" "$DIST" "$DL"

# ---------------------------------------------------------------- 1. node 运行时
if [ ! -f "$NODE_BIN" ]; then
    log "下载 node 运行时（82 MB）"
    curl -sSL --retry 3 -m 1800 -o "$NODE_BIN.part" "$NODE_URL"
    mv "$NODE_BIN.part" "$NODE_BIN"
fi

log "校验 node 运行时"
ACTUAL=$(shasum -a 256 "$NODE_BIN" | awk '{print $1}')
[ "$ACTUAL" = "$NODE_SHA" ] || die "node SHA 不匹配：期望 $NODE_SHA，实际 $ACTUAL"

# 确认是 iOS 平台的 Mach-O
python3 - "$NODE_BIN" <<'PY' || die "node 不是 iOS arm64 二进制"
import struct, sys
b = open(sys.argv[1], 'rb').read(8192)
if struct.unpack('<I', b[:4])[0] != 0xfeedfacf:
    sys.exit(1)
cputype = struct.unpack('<i', b[4:8])[0]
if cputype != 0x0100000c:
    sys.exit(1)
ncmds = struct.unpack('<I', b[16:20])[0]
off, plat = 32, None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack('<II', b[off:off+8])
    if cmd == 0x32:
        plat = struct.unpack('<I', b[off+8:off+12])[0]
    off += cmdsize
    if off > len(b):
        break
print(f"  Mach-O arm64, platform={plat} ({'iOS' if plat==2 else 'macOS' if plat==1 else '?'})")
sys.exit(0 if plat == 2 else 1)
PY

# ---------------------------------------------------------------- 2. 提取依赖树
log "提取 dsh 依赖树（剔 macOS 二进制）"
rm -rf "$NM"
node "$HERE/scripts/extract.js" "$ASAR" "$NM"

NODE_COUNT=$(find "$NM" -name '*.node' | wc -l | tr -d ' ')
[ "$NODE_COUNT" = "0" ] || die "依赖树里仍有 $NODE_COUNT 个 .node"
log "  .node = 0 ✅"

# ---------------------------------------------------------------- 2b. iOS 适配补丁
log "应用 iOS 适配补丁"
node "$HERE/scripts/patch-ios.js" "$NM/node_modules" || die "补丁失败"

# ---------------------------------------------------------------- 3. 组装 payload
log "组装 rootless payload"
JB="$ROOT/var/jb"
rm -rf "$ROOT"
mkdir -p "$JB/usr/lib/dsh/bin" \
         "$JB/usr/lib/dsh/libexec" \
         "$JB/usr/bin" \
         "$JB/etc/dsh" \
         "$JB/Library/LaunchDaemons" \
         "$JB/var/mobile"

# 3.1 node 运行时
install -m 755 "$NODE_BIN" "$JB/usr/lib/dsh/bin/node"

# 3.2 依赖树
cp -R "$NM/." "$JB/usr/lib/dsh/"
# 清掉提取时带入的 mac 专用元数据文件（保留 package.json）
rm -f "$JB/usr/lib/dsh/desktop-runtime.json"

# 3.3 pnpm（纯 JS 发行版）
PNPM_SRC="$APP/Contents/Resources/runtime/primary-runtime/dependencies/pnpm"
if [ -d "$PNPM_SRC" ]; then
    log "  安装纯 JS pnpm"
    mkdir -p "$JB/usr/lib/dsh/libexec/pnpm"
    cp -R "$PNPM_SRC/." "$JB/usr/lib/dsh/libexec/pnpm/"
    # 剔除 darwin 原生 reflink（失败会 fallback 到 copy，纯 JS 可跑）
    rm -rf "$JB/usr/lib/dsh/libexec/pnpm/dist/node_modules/@reflink/reflink-darwin-arm64"
    # 清掉文档省体积
    rm -f "$JB/usr/lib/dsh/libexec/pnpm/CHANGELOG.md" \
          "$JB/usr/lib/dsh/libexec/pnpm/README.md"
    # 确保没有 .node
    find "$JB/usr/lib/dsh/libexec/pnpm" -name '*.node' -delete 2>/dev/null || true
    log "  pnpm 就绪（无原生依赖）"
else
    warn "  未找到 pnpm 发行版，dsh plugin 子命令不可用"
fi

# 3.4b 图片 shim（替代 sharp）
install -m 644 "$HERE/shims/ios-image-shim.mjs" "$JB/usr/lib/dsh/ios-image-shim.mjs"
log "  已装 ios-image-shim.mjs（纯 JS 图片层）"

# 3.4 入口 wrapper
cat > "$JB/usr/bin/dsh" <<'WRAPPER'
#!/bin/sh
# dsh —— DeepSeek Harness 入口（rootless /var/jb）
#
# 必须带 --expose-internals：纯 JS shim 靠它替代原生 addon
# （node-addon-require-builtin 需要 require() Node 私有内部模块）。
set -e
JB=/var/jb
D="$JB/usr/lib/dsh"
NODE="${DSH_NODE:-$D/bin/node}"
BIN="$D/node_modules/@deepseek-ai/dsh/lib/bin.js"
ENVF="$JB/etc/dsh/dsh.env"

[ -f "$ENVF" ] && . "$ENVF"

# 越狱态门禁：/var/jb 是符号链接，重启后 target 可能消失
if [ ! -L "$JB" ] && [ ! -d "$JB" ]; then
    echo "dsh: /var/jb 不存在，越狱未激活。" >&2
    echo "     请打开 Dopamine 点一次 Jailbreak。" >&2
    exit 78
fi
[ -x "$NODE" ] || { echo "dsh: node 运行时缺失：$NODE" >&2; exit 69; }
[ -f "$BIN" ]  || { echo "dsh: dsh 主程序缺失：$BIN" >&2; exit 69; }

export HOME="${HOME:-/var/mobile}"
export DSH_HOME="${DSH_HOME:-$JB/var/mobile/.dsh}"
export PATH="$JB/usr/bin:$JB/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export NODE_PATH="$D/node_modules"
export DSH_NODE="$NODE"

mkdir -p "$DSH_HOME" 2>/dev/null || true

# pnpm 相关目录落到 $DSH_HOME，避免写 root 属主目录
PNPM_HOME="$DSH_HOME/pnpm";                  export PNPM_HOME
XDG_DATA_HOME="$DSH_HOME/pnpm-data";         export XDG_DATA_HOME
XDG_CACHE_HOME="$DSH_HOME/pnpm-cache";       export XDG_CACHE_HOME
npm_config_cache="$DSH_HOME/npm-cache";      export npm_config_cache
npm_config_store_dir="$DSH_HOME/pnpm/store"; export npm_config_store_dir
for _d in "$PNPM_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$npm_config_cache"; do
    mkdir -p "$_d" 2>/dev/null || true
done

# 图片 shim：iOS 无 sharp，用纯 JS 层替代（避免老对话 TRANSPORT）
IMG_SHIM="$D/ios-image-shim.mjs"
if [ -f "$IMG_SHIM" ]; then
    DSH_NODE_FLAGS="$DSH_NODE_FLAGS --import $IMG_SHIM"
    export DSH_NODE_FLAGS
fi

# 无参数 = 起 web profile，不开浏览器（iOS 无 xdg-open）
if [ "$#" -eq 0 ]; then
    set -- web --no-open --port "${DSH_WEB_PORT:-3080}"
fi

# 起 web 时把输出同时写入 $DSH_HOME/web.log，供 dsh-url 抓 token。
# 不用 tee（会破坏 exec 的信号传递和退出码），直接追加重定向。
case "$1" in
    web)
        LOG="$DSH_HOME/web.log"
        mkdir -p "$DSH_HOME" 2>/dev/null || true
        exec "$NODE" $DSH_NODE_FLAGS --expose-internals "$BIN" "$@" \
            >>"$LOG" 2>&1
        ;;
    *)
        exec "$NODE" $DSH_NODE_FLAGS --expose-internals "$BIN" "$@"
        ;;
esac
WRAPPER
chmod 755 "$JB/usr/bin/dsh"

# 3.5 pnpm wrapper
cat > "$JB/usr/bin/pnpm" <<'PNPMWRAP'
#!/bin/sh
# pnpm —— 包内纯 JS 发行版
set -e
D=/var/jb/usr/lib/dsh
H="${DSH_HOME:-/var/jb/var/mobile/.dsh}"
NODE="${DSH_NODE:-$D/bin/node}"
PNPM_CJS="$D/libexec/pnpm/bin/pnpm.cjs"

[ -f "$PNPM_CJS" ] || { echo "pnpm: 未安装（$PNPM_CJS 缺失）" >&2; exit 69; }

PNPM_HOME="$H/pnpm";                  export PNPM_HOME
XDG_DATA_HOME="$H/pnpm-data";         export XDG_DATA_HOME
XDG_CACHE_HOME="$H/pnpm-cache";       export XDG_CACHE_HOME
npm_config_cache="$H/npm-cache";      export npm_config_cache
npm_config_store_dir="$H/pnpm/store"; export npm_config_store_dir
for d in "$PNPM_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$npm_config_cache"; do
    mkdir -p "$d" 2>/dev/null || true
done

exec "$NODE" $DSH_NODE_FLAGS --expose-internals "$PNPM_CJS" "$@"
PNPMWRAP
chmod 755 "$JB/usr/bin/pnpm"

# 3.6 默认环境
cat > "$JB/etc/dsh/dsh.env" <<'ENVFILE'
# dsh 运行时配置（由 /var/jb/usr/bin/dsh 读取）
# 用 := 而非 = ：环境里已 export 的值优先，这里只作默认值。

# 无参数敲 dsh 时启动哪个 profile：web / headless / acp / sdk
: "${DSH_DEFAULT_PROFILE:=web}"

# web profile 端口
: "${DSH_WEB_PORT:=3080}"

# V8 堆上限。iPhone 3GB 机型建议 384，4GB+ 可放宽到 640。
# 不设可能被 jetsam 直接 SIGKILL。
: "${NODE_OPTIONS:=--max-old-space-size=384}"

# 额外的 node 启动参数（如 --single-threaded 收敛编译线程）
: "${DSH_NODE_FLAGS:=}"

# 会话与配置目录
# DSH_HOME=/var/jb/var/mobile/.dsh

# 强制指定 node（默认用包内的）
# DSH_NODE=/var/jb/usr/bin/node
ENVFILE
chmod 644 "$JB/etc/dsh/dsh.env"

# 3.7 launchd 守护（让 web 服务常驻，点图标即用）
cat > "$JB/Library/LaunchDaemons/com.twoyears.dsh.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.twoyears.dsh</string>
    <key>ProgramArguments</key>
    <array>
        <string>/var/jb/usr/bin/dsh</string>
        <string>web</string>
        <string>--no-open</string>
        <string>--port</string>
        <string>3080</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>UserName</key>
    <string>mobile</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/var/mobile</string>
        <key>DSH_HOME</key>
        <string>/var/jb/var/mobile/.dsh</string>
        <key>PATH</key>
        <string>/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/var/jb/var/mobile/.dsh/dsh-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/var/jb/var/mobile/.dsh/dsh-daemon.err.log</string>
</dict>
</plist>
PLIST
chmod 644 "$JB/Library/LaunchDaemons/com.twoyears.dsh.plist"

# 3.8 原生 App（若有编译产物）
APP_BUNDLE="$HERE/build/app/DSH.app"
# entitlements 打进包里，供设备端 ldid 补签
install -m 644 "$HERE/app-src/entitlements.plist" "$JB/usr/lib/dsh/entitlements.plist"
# App 也要带一份（postinst 用它签 App）
if [ -d "$JB/Applications/DSH.app" ]; then
    install -m 644 "$HERE/app-src/entitlements.plist" "$JB/Applications/DSH.app/entitlements.plist"
fi
if [ -d "$APP_BUNDLE" ]; then
    log "  集成原生 App"
    mkdir -p "$JB/Applications"
    cp -R "$APP_BUNDLE" "$JB/Applications/"
    chmod -R 755 "$JB/Applications/DSH.app"
    # 设备端补签（构建机可能没有 ldid）
    if command -v ldid >/dev/null 2>&1; then
        ldid -S"$HERE/app-src/entitlements.plist" "$JB/Applications/DSH.app/DSH" 2>/dev/null \
            && log "    ldid 伪签完成" \
            || warn "    ldid 失败，postinst 会补签"
    fi
else
    warn "  无原生 App 产物（build/app/DSH.app 不存在），只装 CLI + web"
    warn "  编译 App：bash build-app.sh（需要 iOS SDK / Xcode）"
fi

# 3.9 dsh-url：直接打印带 token 的完整 URL
cat > "$JB/usr/bin/dsh-url" <<'DSHURL'
#!/bin/sh
# dsh-url —— 打印当前 dsh web 的完整访问 URL（含 token）
#
# 用法：
#   dsh-url              # 打印 URL
#   dsh-url open         # 打印并尝试用系统打开
#   dsh-url qr           # 打印 URL（供二维码工具使用）
D=/var/jb/usr/lib/dsh
H="${DSH_HOME:-/var/jb/var/mobile/.dsh}"
PORT="${DSH_WEB_PORT:-3080}"

# 候选日志（launchd 的 stdout/stderr + 手动启动的日志）
LOGS="$H/dsh-daemon.log $H/dsh-daemon.err.log $H/web.log"

find_url() {
    for f in $LOGS; do
        [ -f "$f" ] || continue
        # 只取最后一次出现的带 token 的 URL
        line=$(grep -o "http://[0-9.]*:[0-9]*/?token=[A-Za-z0-9_-]*" "$f" 2>/dev/null | tail -1)
        if [ -n "$line" ]; then
            printf '%s\n' "$line"
            return 0
        fi
    done
    return 1
}

URL=$(find_url)

if [ -z "$URL" ]; then
    # 没有日志：探测端口是否活着，提示需要重启内核拿 token
    if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
        echo "dsh 在 $PORT 上运行，但日志里找不到 token。" >&2
        echo "重启内核以重新打印 token：" >&2
        echo "  launchctl kickstart -k system/com.twoyears.dsh" >&2
        echo "  或前台运行： dsh web --no-open --port $PORT" >&2
        exit 1
    fi
    echo "dsh 未运行。先启动：" >&2
    echo "  launchctl kickstart system/com.twoyears.dsh" >&2
    echo "  或： dsh" >&2
    exit 1
fi

case "${1:-}" in
    open)
        printf '%s\n' "$URL"
        # iOS 上用 open 或 uiopen
        command -v uiopen >/dev/null 2>&1 && uiopen "$URL" 2>/dev/null && exit 0
        command -v open   >/dev/null 2>&1 && open "$URL" 2>/dev/null && exit 0
        echo "(无法自动打开，请手动复制上面的 URL 到 Safari)" >&2
        ;;
    qr)
        printf '%s\n' "$URL"
        command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$URL"
        ;;
    *)
        printf '%s\n' "$URL"
        ;;
esac
DSHURL
chmod 755 "$JB/usr/bin/dsh-url"

# 3.10 dsh-doctor
cat > "$JB/usr/bin/dsh-doctor" <<'DOCTOR'
#!/bin/sh
# dsh-doctor —— 安装后自检
D=/var/jb/usr/lib/dsh
NODE="${DSH_NODE:-$D/bin/node}"
BIN="$D/node_modules/@deepseek-ai/dsh/lib/bin.js"
OK=0; FAIL=0

chk() { # chk <描述> <命令...>
    desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  \033[32mOK\033[0m   %s\n' "$desc"; OK=$((OK+1))
    else
        printf '  \033[31mFAIL\033[0m %s\n' "$desc"; FAIL=$((FAIL+1))
    fi
}

echo "=== dsh-doctor ==="

# 1) 越狱态
if [ -d /var/jb ]; then printf '  \033[32mOK\033[0m   /var/jb 存在\n'; OK=$((OK+1));
else printf '  \033[31mFAIL\033[0m /var/jb 不存在\n'; FAIL=$((FAIL+1)); fi

# 2) node 可执行
chk "node 可执行 ($NODE)" test -x "$NODE"

# 3) node 版本
if [ -x "$NODE" ]; then
    V=$("$NODE" -v 2>/dev/null || echo "?")
    printf '       node 版本: %s\n' "$V"
    case "$V" in
        v24.*|v25.*|v26.*) printf '  \033[32mOK\033[0m   node >= 24\n'; OK=$((OK+1));;
        *) printf '  \033[31mFAIL\033[0m node 版本过低（需 >= 24.9.0）\n'; FAIL=$((FAIL+1));;
    esac
fi

# 4) 主程序
chk "dsh 主程序存在" test -f "$BIN"

# 5) 零原生 addon
N=$(find "$D" -name '*.node' 2>/dev/null | wc -l | tr -d ' ')
if [ "$N" = "0" ]; then printf '  \033[32mOK\033[0m   0 个 .node\n'; OK=$((OK+1));
else printf '  \033[31mFAIL\033[0m 发现 %s 个 .node\n' "$N"; FAIL=$((FAIL+1)); fi

# 6) 两个 shim 已生效
if grep -q 'dsh-iOS shim' "$D/node_modules/@deepseek-ai/node-addon-system/lib/flock.js" 2>/dev/null; then
    printf '  \033[32mOK\033[0m   flock shim\n'; OK=$((OK+1))
else printf '  \033[31mFAIL\033[0m flock shim 未生效\n'; FAIL=$((FAIL+1)); fi

if grep -q 'dsh-iOS shim' "$D/node_modules/node-addon-require-builtin/lib/index.js" 2>/dev/null; then
    printf '  \033[32mOK\033[0m   require-builtin shim\n'; OK=$((OK+1))
else printf '  \033[31mFAIL\033[0m require-builtin shim 未生效\n'; FAIL=$((FAIL+1)); fi

# 7) 内部模块可用（shim 的核心能力）
if [ -x "$NODE" ]; then
    if "$NODE" --expose-internals -e '
        const {createRequire}=require("node:module");
        const r=createRequire(process.cwd()+"/x.js");
        try { r("internal/modules/esm/loader"); process.exit(0); }
        catch(e){ process.exit(1); }
    ' >/dev/null 2>&1; then
        printf '  \033[32mOK\033[0m   internal modules 可加载\n'; OK=$((OK+1))
    else printf '  \033[31mFAIL\033[0m internal modules 不可加载\n'; FAIL=$((FAIL+1)); fi
fi

# 8) 外部 CLI
for c in git bash rg; do
    if command -v "$c" >/dev/null 2>&1; then
        printf '  \033[32mOK\033[0m   %s 已装\n' "$c"; OK=$((OK+1))
    else
        printf '  \033[33mWARN\033[0m %s 缺失（功能降级）\n' "$c"
    fi
done

echo
printf '汇总: \033[32m%d OK\033[0m / \033[31m%d FAIL\033[0m\n' "$OK" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
DOCTOR
chmod 755 "$JB/usr/bin/dsh-doctor"

# ---------------------------------------------------------------- 4. DEBIAN 控制
log "生成 DEBIAN 控制文件"
mkdir -p "$ROOT/DEBIAN"

INSTALLED_SIZE=$(du -sk "$ROOT" | awk '{print $1}')

cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: $PKGID
Name: DeepSeek Harness
Version: $PKGVER
Architecture: $ARCH
Section: Development
Priority: optional
Maintainer: local build <dsh@localhost>
Installed-Size: $INSTALLED_SIZE
Depends: firmware (>= 14.0), ca-certificates, uikittools, libiosexec1
Recommends: git, ripgrep, bash
Suggests: openssh-server
Description: DeepSeek Harness CLI for rootless jailbroken iOS
 Self-contained DSH runtime: bundles Node.js 24.19.0 (arm64, iOS) plus the
 full @deepseek-ai/dsh dependency tree with native addons replaced by pure-JS
 shims, so no .node binary is required.
 .
 Install and run \`dsh\` in a terminal, or open the desktop icon.
 The web workbench listens on 127.0.0.1:3080 by default.
 .
 Rootless layout under /var/jb. Requires an arm64 device on iOS 14+.
CONTROL

cat > "$ROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
JB=/var/jb
D="$JB/usr/lib/dsh"

# 修属主：mobile(501) 需要能读写自己的 DSH_HOME
if [ -d "$JB/var/mobile" ]; then
    chown -R 501:501 "$JB/var/mobile" 2>/dev/null || true
fi

# 确保 node 可执行
[ -f "$D/bin/node" ] && chmod 755 "$D/bin/node"

# 清掉 macOS 遗留的 quarantine 属性（如果有）
command -v xattr >/dev/null 2>&1 && xattr -dr com.apple.quarantine "$D" 2>/dev/null || true

# 注册 launchd 守护（让 web 服务常驻）
PLIST="$JB/Library/LaunchDaemons/com.twoyears.dsh.plist"
if [ -f "$PLIST" ]; then
    mkdir -p "$JB/var/mobile/.dsh" 2>/dev/null || true
    chown -R 501:501 "$JB/var/mobile/.dsh" 2>/dev/null || true
    # 先卸载旧的，再加载
    launchctl bootout system "$PLIST" 2>/dev/null || true
    launchctl bootstrap system "$PLIST" 2>/dev/null \
        || launchctl load -w "$PLIST" 2>/dev/null \
        || echo "  (launchd 注册失败，可手动 dsh web 启动)"
fi

# 注册原生 App 图标（uicache）
APP_BUNDLE="$JB/Applications/DSH.app"
if [ -d "$APP_BUNDLE" ]; then
    # 补签（构建期没签的话）
    if [ -f "$APP_BUNDLE/DSH" ]; then
        chmod 755 "$APP_BUNDLE/DSH"
        if command -v ldid >/dev/null 2>&1; then
            ldid -S"$JB/usr/lib/dsh/entitlements.plist" "$APP_BUNDLE/DSH" 2>/dev/null || true
        fi
    fi
    chown -R 501:501 "$APP_BUNDLE" 2>/dev/null || true
    # 让 SpringBoard 刷新图标缓存
    command -v uicache >/dev/null 2>&1 && uicache -p "$APP_BUNDLE" 2>/dev/null || true
fi

echo ""
echo "DeepSeek Harness 已安装。"
echo "  桌面图标:  DSH（若未出现，运行 uicache -a）"
echo "  运行:      dsh"
echo "  自检:      dsh-doctor"
echo "  网页:      http://127.0.0.1:3080"
echo ""
exit 0
POSTINST
chmod 755 "$ROOT/DEBIAN/postinst"

cat > "$ROOT/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
# 保留用户数据（$DSH_HOME），只提示
echo "正在卸载 DeepSeek Harness（用户数据保留在 /var/jb/var/mobile/.dsh）"
exit 0
PRERM
chmod 755 "$ROOT/DEBIAN/prerm"

# ---------------------------------------------------------------- 4b. 覆盖为仓库内的权威脚本
# build.sh 内嵌的脚本与 build/payload/ 下的独立文件必须一致；
# 这里用 payload 覆盖，确保本地构建与 CI 产出同一个包。
log "应用 payload 权威脚本"
# 只拷文件树和 DEBIAN 脚本，不覆盖本脚本生成的 control
cp -R "$HERE/payload/var/." "$ROOT/var/"
mkdir -p "$ROOT/DEBIAN"
cp "$HERE/payload/DEBIAN/postinst" "$ROOT/DEBIAN/postinst"
cp "$HERE/payload/DEBIAN/prerm"    "$ROOT/DEBIAN/prerm"
chmod 755 "$ROOT/var/jb/usr/bin/dsh" "$ROOT/var/jb/usr/bin/dsh-doctor" \
          "$ROOT/var/jb/usr/bin/dsh-url" "$ROOT/var/jb/usr/bin/pnpm" 2>/dev/null || true
chmod 644 "$ROOT/var/jb/etc/dsh/dsh.env" \
          "$ROOT/var/jb/Library/LaunchDaemons/com.twoyears.dsh.plist" 2>/dev/null || true
chmod 755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/prerm" 2>/dev/null || true

# ---------------------------------------------------------------- 5. 打包
log "打包 deb"
OUT="$DIST/${PKGID}_${PKGVER}_${ARCH}.deb"
python3 "$HERE/tools/mkdeb.py" "$ROOT" "$OUT"

# ---------------------------------------------------------------- 6. 验证
log "验证产物"
[ -f "$OUT" ] || die "打包失败"
FINAL_SIZE=$(du -h "$OUT" | awk '{print $1}')
log "  产物: $OUT  ($FINAL_SIZE)"
log "  Installed-Size: ${INSTALLED_SIZE} KB"

echo
log "完成"
