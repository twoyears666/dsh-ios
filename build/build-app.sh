#!/bin/bash
# ============================================================================
# build-app.sh —— 编译 dsh iOS 原生 App（需要 iOS SDK / Xcode）
#
# 产物：DSH.app（越狱可直接用的未签名 App，postinst 里 ldid 伪签）
#
# 用法：
#   bash build-app.sh [输出目录]
#
# 环境变量：
#   SDK           iOS SDK 名（默认 iphoneos）
#   MIN_IOS       最低 iOS 版本（默认 14.0）
#   ARCHS         架构（默认 arm64）
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/app-src"
OUT="${1:-$HERE/build/app}"

SDK="${SDK:-iphoneos}"
MIN_IOS="${MIN_IOS:-14.0}"
ARCHS="${ARCHS:-arm64}"

log()  { printf '\033[1;34m[app]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[app]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 预检
log "检查 iOS SDK"
SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path 2>/dev/null) \
    || die "找不到 iOS SDK。需要 Xcode，或运行：xcode-select --install 后安装 Xcode。

在 GitHub Actions 上：runs-on: macos-15 自带 Xcode，无需额外安装。"

log "  SDK: $SDK_PATH"
log "  SDK 版本: $(xcrun --sdk "$SDK" --show-sdk-version 2>/dev/null || echo '?')"

command -v clang >/dev/null || die "找不到 clang"

# ---------------------------------------------------------------- 目录
APP="$OUT/DSH.app"
rm -rf "$APP"
mkdir -p "$APP"

# ---------------------------------------------------------------- 编译
log "编译 Objective-C 源码"
CFLAGS=(
    -isysroot "$SDK_PATH"
    -target "arm64-apple-ios${MIN_IOS}"
    -miphoneos-version-min="$MIN_IOS"
    -fobjc-arc
    -O2
    -Wall
    -Wno-unused-parameter
    -I"$SRC"
)
LDFLAGS=(
    -isysroot "$SDK_PATH"
    -target "arm64-apple-ios${MIN_IOS}"
    -miphoneos-version-min="$MIN_IOS"
    -framework UIKit
    -framework Foundation
    -framework WebKit
    -framework CoreGraphics
    -framework UniformTypeIdentifiers
    # 语音输入（SFSpeechRecognizer）：录音走 AVAudioEngine，识别走 Speech
    -framework AVFoundation
    -framework Speech
)

SOURCES=(
    "$SRC/main.m"
    "$SRC/DSHAppDelegate.m"
    "$SRC/DSHRootVC.m"
    "$SRC/DSHBridge.m"
    "$SRC/DSHMenu.m"
    "$SRC/DSHShell.m"
    "$SRC/DSHBrowserBridge.m"
    "$SRC/DSHBrowserControl.m"
    "$SRC/DSHVoice.m"
    "$SRC/DSHProc.m"
    "$SRC/DSHJIT.m"
)

for f in "${SOURCES[@]}"; do
    [ -f "$f" ] || die "源文件缺失: $f"
done

log "  源文件: ${#SOURCES[@]} 个"
clang "${CFLAGS[@]}" "${LDFLAGS[@]}" -o "$APP/DSH" "${SOURCES[@]}" \
    || die "编译失败"

log "  ✅ 已生成 $APP/DSH"
file "$APP/DSH"

# ---------------------------------------------------------------- Info.plist
log "写入 Info.plist"
cp "$SRC/Info.plist" "$APP/Info.plist"

# 版本号从环境变量注入，让「关于」页显示真实构建版本，
# 而不是写死的 0.2.2。CFBundleVersion 必须是纯数字点分（App Store 规则），
# 所以 build number 单独用 DSH_BUILD 传。
if [ -n "${DSH_PKGVER:-}" ]; then
    # 形如 0.2.2-rc.5+ios1.g1a2b3c4.57 -> 短版本取 + 之前的部分
    SHORT="${DSH_PKGVER%%+*}"
    plutil -replace CFBundleShortVersionString -string "$SHORT" "$APP/Info.plist"
    log "  版本: $SHORT (包版本 $DSH_PKGVER)"
fi
if [ -n "${DSH_BUILD:-}" ]; then
    plutil -replace CFBundleVersion -string "$DSH_BUILD" "$APP/Info.plist"
fi
plutil -lint "$APP/Info.plist" >/dev/null || die "Info.plist 格式错误"

# ---------------------------------------------------------------- 图标
# 用 DSH 官方图标（从 mac 版 icon.icns 提取后按 iOS 规格缩放）
ICONS="$SRC/icons"
if [ -d "$ICONS" ]; then
    log "安装图标"
    n=0
    for f in "$ICONS"/*.png; do
        [ -f "$f" ] || continue
        cp "$f" "$APP/$(basename "$f")"
        n=$((n+1))
    done
    log "  已复制 $n 个图标"
    ls -1 "$APP"/*.png 2>/dev/null | while read -r f; do
        log "    $(basename "$f")"
    done
else
    warn "无图标源（$ICONS），App 会显示默认图标"
fi

# ---------------------------------------------------------------- 伪签
log "伪签（ldid）"
if command -v ldid >/dev/null 2>&1; then
    ldid -S"$SRC/entitlements.plist" "$APP/DSH" \
        && log "  ✅ ldid 伪签完成" \
        || log "  ⚠ ldid 失败（postinst 会在设备上补签）"
else
    log "  ⚠ 无 ldid（macOS 上可 brew install ldid；设备上由 postinst 补签）"
fi

# ---------------------------------------------------------------- 校验
log "校验产物"
[ -f "$APP/DSH" ] || die "可执行文件缺失"
[ -f "$APP/Info.plist" ] || die "Info.plist 缺失"

# 语音输入的两条用途说明缺一不可：iOS 在申请权限时会直接 crash，
# 而且崩在设备上很难看出原因，这里提前拦住。
for k in NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription; do
    v=$(/usr/libexec/PlistBuddy -c "Print :$k" "$APP/Info.plist" 2>/dev/null || true)
    [ -n "$v" ] || die "Info.plist 缺 $k（语音输入会崩溃）"
done
log "  语音权限说明: OK"

# 确认是 iOS 平台 Mach-O
python3 - "$APP/DSH" <<'PY' || die "产物不是 iOS arm64"
import struct, sys
b = open(sys.argv[1], 'rb').read(8192)
if struct.unpack('<I', b[:4])[0] != 0xfeedfacf:
    sys.exit(1)
if struct.unpack('<i', b[4:8])[0] != 0x0100000c:
    sys.exit(1)
ncmds = struct.unpack('<I', b[16:20])[0]
off, plat = 32, None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack('<II', b[off:off+8])
    if cmd == 0x32:
        plat = struct.unpack('<I', b[off+8:off+12])[0]
    off += cmdsize
    if off > len(b): break
print(f"  Mach-O arm64, platform={plat} ({'iOS' if plat==2 else 'macOS' if plat==1 else '?'})")
sys.exit(0 if plat == 2 else 1)
PY

SIZE=$(du -sh "$APP" | awk '{print $1}')
log "完成: $APP  ($SIZE)"
