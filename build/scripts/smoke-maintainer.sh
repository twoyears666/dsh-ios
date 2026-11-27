#!/bin/sh
# smoke-maintainer.sh —— 把维护者脚本在假环境里真的跑一遍
#
# 为什么需要这个：
#   verify-payload.sh 是静态检查，能看出「有没有 set -e」「有没有裸 PID kill」，
#   但证明不了「脚本从头跑到尾会不会中途退出」。
#   前两次事故恰好都是这一类：
#     · set -e + tail 不存在的文件 → 中途退出
#     · set -u + 未定义的 $LABEL  → 中途退出
#   两者只要真跑一次就立刻暴露，而静态检查只能靠规则去猜。
#
# 做法：
#   1. 造一个假的越狱根（/var/jb、/var/mobile/Media/... 全用临时目录顶替）
#   2. 把 postinst / prerm / preinst 里的绝对路径改写到假根
#   3. 给 launchctl / uicache / ldid / pkill / nc / sleep 塞桩
#      —— launchctl 和 nc 故意返回失败，模拟真机上「job 没起来、端口没监听」
#   4. 执行脚本，断言：
#        · 退出码 0（非 0 就等于 dpkg 半配置）
#        · 关键产物真的生成了（VERSION 戳、install.log）
#   5. preinst 正反两个用例：合规脚本放行、违规脚本拦下
#
# 用法：sh build/scripts/smoke-maintainer.sh
# 退出码：0 通过；1 有问题

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PAYLOAD=${1:-"$REPO/build/payload"}

FAILS=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -d "$PAYLOAD" ] || { printf '找不到 payload: %s\n' "$PAYLOAD" >&2; exit 1; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/dsh-smoke.XXXXXX") || exit 1
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

JB="$SANDBOX/jb"
MEDIA="$SANDBOX/media"
STUB="$SANDBOX/bin"

printf '\033[1m=== 维护者脚本冒烟测试 ===\033[0m\n'
printf 'payload: %s\n' "$PAYLOAD"
printf '沙箱:    %s\n' "$SANDBOX"

# ---------------------------------------------------------------- 造假根
mkdir -p "$JB/usr/lib/dsh/bin" "$JB/usr/bin" "$JB/Library/LaunchDaemons" \
         "$JB/Applications/DSH.app" "$JB/var/lib/dpkg/info" \
         "$MEDIA/config" "$MEDIA/data" "$MEDIA/logs" "$MEDIA/cache" "$MEDIA/workspaces" \
         "$STUB" || exit 1

# payload 里的脚本和 plist 拷过去（postinst 会检查它们存在）
cp "$PAYLOAD/var/jb/usr/bin/"* "$JB/usr/bin/" 2>/dev/null
chmod 755 "$JB/usr/bin/"* 2>/dev/null
cp "$PAYLOAD/var/jb/Library/LaunchDaemons/"*.plist "$JB/Library/LaunchDaemons/" 2>/dev/null
cp "$PAYLOAD/var/jb/usr/lib/dsh/entitlements.plist" "$JB/usr/lib/dsh/" 2>/dev/null
cp "$PAYLOAD/var/jb/usr/lib/dsh/AGENTS.md.template" "$JB/usr/lib/dsh/" 2>/dev/null

printf '#!/bin/sh\nexit 0\n' > "$JB/Applications/DSH.app/DSH"
chmod 755 "$JB/Applications/DSH.app/DSH"
printf '<plist><dict/></plist>\n' > "$JB/Applications/DSH.app/Info.plist"
printf '0.0.0-smoke\n' > "$JB/usr/lib/dsh/VERSION"
printf '0.0.0\n'       > "$JB/usr/lib/dsh/KERNEL_VERSION"

# ---------------------------------------------------------------- 桩
# 关键：launchctl 和 nc 故意失败 —— 真机上就是这个状态（job 加载不上、端口不监听）。
# 脚本必须在这种条件下仍然 exit 0，否则装完就是半配置。
mkstub() {
    name=$1; body=$2
    printf '#!/bin/sh\n%s\n' "$body" > "$STUB/$name"
    chmod 755 "$STUB/$name"
}
mkstub launchctl 'echo "launchctl: $* -> Could not find service (stub)" >&2; exit 1'
mkstub nc        'exit 1'
mkstub uicache   'echo "uicache (stub)"; exit 0'
mkstub ldid      'echo "ldid (stub)"; exit 0'
mkstub pkill     'exit 1'
mkstub plutil    'exit 0'
mkstub sleep     'exit 0'

# ---------------------------------------------------------------- 路径改写
# 顺序很重要：先替换长的，再替换短的
rewrite() {
    sed -e "s|/var/mobile/Media/deepseek-harness|$MEDIA|g" \
        -e "s|/var/jb|$JB|g" \
        -e "s|/var/lib/dpkg|$JB/var/lib/dpkg|g" \
        "$1"
}

run_script() {
    src=$1; name=$2
    dst="$SANDBOX/$name"
    rewrite "$src" > "$dst" || { bad "$name: 改写失败"; return 1; }
    chmod 755 "$dst"
    PATH="$STUB:$PATH" sh "$dst" >"$SANDBOX/$name.out" 2>&1
    return $?
}

show_tail() {
    printf '      --- 输出尾部 ---\n'
    tail -12 "$1" 2>/dev/null | while IFS= read -r l; do printf '      %s\n' "$l"; done
}

# ---------------------------------------------------------------- 1. postinst
head1 '1. postinst（安装后配置）'
if [ -f "$PAYLOAD/DEBIAN/postinst" ]; then
    if run_script "$PAYLOAD/DEBIAN/postinst" postinst; then
        ok 'postinst 退出码 0'
    else
        rc=$?
        bad "postinst 退出码 $rc —— 真机上这会让 dpkg 半配置"
        show_tail "$SANDBOX/postinst.out"
    fi

    # 关键产物：证明脚本真的跑到了最后，而不是「早退但恰好返回 0」
    if [ -f "$MEDIA/config/installed.version" ]; then
        ok "VERSION 戳已写入（$(cat "$MEDIA/config/installed.version" 2>/dev/null)）"
    else
        bad 'config/installed.version 没生成 —— postinst 没走到 §5.2'
        show_tail "$SANDBOX/postinst.out"
    fi

    if [ -f "$MEDIA/logs/install.log" ]; then
        ok 'install.log 已生成（postinst 走到了 §5.3 的注册流程）'
    else
        bad 'install.log 没生成 —— postinst 在 §5.3 之前就中止了'
        show_tail "$SANDBOX/postinst.out"
    fi
else
    bad '没有 DEBIAN/postinst'
fi

# ---------------------------------------------------------------- 2. prerm
head1 '2. prerm（卸载前）'
if [ -f "$PAYLOAD/DEBIAN/prerm" ]; then
    if run_script "$PAYLOAD/DEBIAN/prerm" prerm; then
        ok 'prerm 退出码 0'
    else
        rc=$?
        bad "prerm 退出码 $rc —— 会让卸载/升级失败"
        show_tail "$SANDBOX/prerm.out"
    fi
else
    bad '没有 DEBIAN/prerm'
fi

# ---------------------------------------------------------------- 3. preinst
head1 '3. preinst（装文件前的闸门）'
if [ -f "$PAYLOAD/DEBIAN/preinst" ]; then
    rewrite "$PAYLOAD/DEBIAN/preinst" > "$SANDBOX/preinst"
    chmod 755 "$SANDBOX/preinst"
    INFO="$JB/var/lib/dpkg/info"
    PKG=com.twoyears.dsh

    # 3.1 合规脚本 → 应该放行
    printf '#!/bin/sh\nset -u\nVAR=1\necho ok\nexit 0\n' > "$INFO/$PKG.postinst"
    printf '#!/bin/sh\nexit 0\n' > "$INFO/$PKG.prerm"
    # 注意：不要传 DSH_TEST_DPKG_DIR —— preinst 内部会自己拼 /info/，
    # 传 info 目录会变成 .../info/info/...，文件找不到就静默「放行」。
    # 路径改写已经把默认的 DPKG_DIR 指到沙箱了。
    if PATH="$STUB:$PATH" sh "$SANDBOX/preinst" >"$SANDBOX/preinst-ok.out" 2>&1; then
        ok '合规 postinst → 放行'
    else
        bad '合规 postinst 被拦下了（误杀）'
        show_tail "$SANDBOX/preinst-ok.out"
    fi

    # 3.2 违规脚本 → 应该拦下
    printf '#!/bin/sh\nset -e\nkill "$X"\npkill -9 -f x\n(nohup /bin/true &)\n' > "$INFO/$PKG.postinst"
    if PATH="$STUB:$PATH" sh "$SANDBOX/preinst" >"$SANDBOX/preinst-bad.out" 2>&1; then
        bad '违规 postinst 竟然被放行了 —— 闸门失效'
        show_tail "$SANDBOX/preinst-bad.out"
    else
        ok '违规 postinst → 拦下'
        # 确认报告里点到了每一项
        for pat in 'set -e' '裸 PID' 'pkill -9' 'nohup'; do
            if grep -q "$pat" "$SANDBOX/preinst-bad.out" 2>/dev/null; then
                ok "  报告里指出了: $pat"
            else
                bad "  报告里没提到: $pat"
            fi
        done
    fi
else
    bad '没有 DEBIAN/preinst'
fi

# ---------------------------------------------------------------- 汇总
head1 '汇总'
if [ "$FAILS" -gt 0 ]; then
    printf '\033[31m✗ %d 项失败\033[0m\n' "$FAILS"
    printf '\n维护者脚本跑不通 = 装上去就是半配置状态。必须修完再打包。\n'
    exit 1
fi
printf '\033[32m✓ 全部通过\033[0m\n'
printf '（postinst / prerm 在「launchctl 失败 + 端口不监听」的条件下都退出 0）\n'
exit 0
